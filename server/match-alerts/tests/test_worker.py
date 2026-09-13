"""The worker's awkward cases, driven at whatever speed the test wants."""

from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from match_alerts.api_football import estimate_daily_requests
from match_alerts.config import (
    ApiFootballConfig,
    Config,
    FcmConfig,
    WorkerConfig,
)
from match_alerts.events import Fixture
from match_alerts.fcm import SendResult, alert_condition
from match_alerts.store import SentLog
from match_alerts.worker import Worker

KICKOFF_AT = datetime(2026, 9, 20, 19, 0, tzinfo=timezone.utc)


def make_fixture(**over) -> Fixture:
    base = dict(
        id=1,
        kickoff=KICKOFF_AT,
        status="NS",
        league_id=2,
        league_name="UCL",
        home_id=541,
        home_name="Real Madrid",
        away_id=529,
        away_name="Barcelona",
    )
    base.update(over)
    return Fixture(**base)


class FakeApi:
    """Serves whatever the test says is being played."""

    def __init__(self):
        self.schedule: list[Fixture] = []
        self.live_now: list[Fixture] = []
        self.by_id: dict[int, Fixture] = {}
        self.requests_made = 0
        self.fail_everything = False
        self.by_ids_calls: list[list[int]] = []

    def fixtures_on(self, day, leagues=None):
        if self.fail_everything:
            from match_alerts.api_football import ApiFootballError

            raise ApiFootballError("simulated outage")
        self.requests_made += 1
        return list(self.schedule)

    def live(self, leagues=None):
        if self.fail_everything:
            from match_alerts.api_football import ApiFootballError

            raise ApiFootballError("simulated outage")
        self.requests_made += 1
        return list(self.live_now)

    def by_ids(self, ids):
        self.by_ids_calls.append(list(ids))
        self.requests_made += 1
        return [self.by_id[i] for i in ids if i in self.by_id]


class FakeFcm:
    def __init__(self):
        self.sent: list[tuple[str, str, str]] = []
        self.ok = True

    def send_alert(self, *, condition, title, body, data=None, validate_only=False):
        if not self.ok:
            return SendResult(False, "simulated failure")
        self.sent.append((condition, title, body))
        return SendResult(True, "ok")

    def validate_negation(self):
        return SendResult(True, "ok")


def make_worker(tmp_path: Path, dry_run=False) -> tuple[Worker, FakeApi, FakeFcm]:
    config = Config(
        api=ApiFootballConfig(key="k", base="http://x", leagues=(2,)),
        fcm=FcmConfig(project_id="p", credentials_file=None),
        worker=WorkerConfig(
            poll_seconds=60,
            schedule_refresh_seconds=1800,
            state_db=tmp_path / "state.db",
            pre_match_window_seconds=120,
            max_result_age_minutes=240,
            dry_run=dry_run,
        ),
    )
    api, fcm = FakeApi(), FakeFcm()
    worker = Worker(config, api=api, fcm=fcm, store=SentLog(config.worker.state_db))
    worker.negation_validated = True
    return worker, api, fcm


class TestColdStart:
    def test_tomorrows_alerts_survive_the_baseline(self, tmp_path):
        worker, api, fcm = make_worker(tmp_path)
        tomorrow = make_fixture(id=7, kickoff=KICKOFF_AT + timedelta(days=1))
        api.schedule = [tomorrow]

        worker.tick(now=KICKOFF_AT - timedelta(hours=2))

        # An earlier version wrote off every moment of every fixture it could
        # see, which cost the user their first two days of alerts.
        assert not worker.store.already_handled(7, "t45")
        assert not worker.store.already_handled(7, "ft")

    def test_a_match_already_played_is_written_off(self, tmp_path):
        worker, api, fcm = make_worker(tmp_path)
        api.schedule = [make_fixture(id=8, status="FT", home_goals=1, away_goals=0)]

        worker.tick(now=KICKOFF_AT + timedelta(hours=2))

        assert worker.store.already_handled(8, "ft")
        assert fcm.sent == []

    def test_a_total_api_failure_does_not_count_as_a_start(self, tmp_path):
        worker, api, _ = make_worker(tmp_path)
        api.fail_everything = True

        worker.tick(now=KICKOFF_AT)

        # Baselining on no information would write off nothing and then claim
        # the worker had started cleanly, so the real first pass never happens.
        assert worker.store.is_empty()


class TestNoDuplicates:
    def test_the_same_moment_is_sent_once(self, tmp_path):
        worker, api, fcm = make_worker(tmp_path)
        api.schedule = [make_fixture()]
        worker.tick(now=KICKOFF_AT - timedelta(days=1))  # baseline

        at = KICKOFF_AT - timedelta(minutes=45)
        worker.tick(now=at)
        worker.tick(now=at + timedelta(seconds=30))

        assert [t for _, t, _ in fcm.sent].count("بعد ٤٥ دقيقة") == 1

    def test_a_restart_does_not_re_announce(self, tmp_path):
        worker, api, fcm = make_worker(tmp_path)
        api.schedule = [make_fixture()]
        worker.tick(now=KICKOFF_AT - timedelta(days=1))
        worker.tick(now=KICKOFF_AT - timedelta(minutes=45))
        assert len(fcm.sent) == 1

        # A brand new process against the same database.
        worker2, api2, fcm2 = make_worker(tmp_path)
        api2.schedule = api.schedule
        worker2.tick(now=KICKOFF_AT - timedelta(minutes=44, seconds=30))

        assert fcm2.sent == [], "the sent-log must outlive the process"


class TestStatusDoesNotRegress:
    def test_a_finished_match_is_not_restarted_by_a_schedule_refresh(
        self, tmp_path
    ):
        worker, api, fcm = make_worker(tmp_path)
        scheduled = make_fixture()
        api.schedule = [scheduled]
        worker.tick(now=KICKOFF_AT - timedelta(days=1))

        # It kicks off...
        api.live_now = [make_fixture(status="1H")]
        worker._schedule_fetched_at = None
        worker.tick(now=KICKOFF_AT + timedelta(minutes=1))
        assert any(t == "بدأت المباراة" for _, t, _ in fcm.sent)

        # ...then the live feed drops it and the schedule still lists it as NS.
        api.live_now = []
        api.by_id = {1: make_fixture(status="FT", home_goals=2, away_goals=0)}
        worker._schedule_fetched_at = None
        fcm.sent.clear()
        worker.tick(now=KICKOFF_AT + timedelta(hours=2))

        titles = [t for _, t, _ in fcm.sent]
        assert "بدأت المباراة" not in titles, "a finished match must not restart"
        assert "انتهت المباراة" in titles


class TestFinishingSet:
    def test_only_matches_that_left_the_live_feed_are_re_requested(self, tmp_path):
        worker, api, fcm = make_worker(tmp_path)
        api.schedule = [make_fixture(id=1), make_fixture(id=2)]
        worker.tick(now=KICKOFF_AT - timedelta(days=1))

        api.live_now = [make_fixture(id=1, status="1H"), make_fixture(id=2, status="1H")]
        worker._schedule_fetched_at = None
        worker.tick(now=KICKOFF_AT + timedelta(minutes=1))
        api.by_ids_calls.clear()

        # Both still playing: nothing should be asked about individually.
        worker.tick(now=KICKOFF_AT + timedelta(minutes=30))
        assert api.by_ids_calls == [], "asking about every in-play match on every poll"

        # One drops out.
        api.live_now = [make_fixture(id=2, status="2H")]
        api.by_id = {1: make_fixture(id=1, status="FT", home_goals=1, away_goals=1)}
        worker.tick(now=KICKOFF_AT + timedelta(hours=2))
        assert api.by_ids_calls == [[1]]

    def test_a_busy_evening_is_not_truncated(self, tmp_path):
        worker, api, fcm = make_worker(tmp_path)
        many = [make_fixture(id=i) for i in range(1, 31)]
        api.schedule = many
        worker.tick(now=KICKOFF_AT - timedelta(days=1))

        api.live_now = [make_fixture(id=i, status="1H") for i in range(1, 31)]
        worker._schedule_fetched_at = None
        worker.tick(now=KICKOFF_AT + timedelta(minutes=1))

        api.live_now = []
        api.by_ids_calls.clear()
        worker.tick(now=KICKOFF_AT + timedelta(hours=2))

        asked = [i for call in api.by_ids_calls for i in call]
        assert len(asked) == 30, "the later matches of a busy evening were dropped"


class TestFailedSendIsRecoverable:
    def test_a_failed_kickoff_is_retried_from_the_queue(self, tmp_path):
        worker, api, fcm = make_worker(tmp_path)
        api.schedule = [make_fixture()]
        worker.tick(now=KICKOFF_AT - timedelta(days=1))

        fcm.ok = False
        api.live_now = [make_fixture(status="1H")]
        worker._schedule_fetched_at = None
        worker.tick(now=KICKOFF_AT + timedelta(minutes=1))
        assert fcm.sent == []

        # By now the transition is gone — NS followed by 1H followed by 1H.
        # Only a queued event can still be sent.
        fcm.ok = True
        worker.tick(now=KICKOFF_AT + timedelta(minutes=2))

        assert [t for _, t, _ in fcm.sent] == ["بدأت المباراة"]

    def test_a_queued_event_eventually_expires(self, tmp_path):
        worker, api, fcm = make_worker(tmp_path)
        api.schedule = [make_fixture()]
        worker.tick(now=KICKOFF_AT - timedelta(days=1))

        fcm.ok = False
        api.live_now = [make_fixture(status="1H")]
        worker._schedule_fetched_at = None
        worker.tick(now=KICKOFF_AT + timedelta(minutes=1))

        fcm.ok = True
        worker.tick(now=KICKOFF_AT + timedelta(hours=9))

        assert fcm.sent == [], "nobody wants to be told a match started 9h ago"


class TestRescheduling:
    def test_a_moved_match_can_warn_again(self, tmp_path):
        worker, api, fcm = make_worker(tmp_path)
        api.schedule = [make_fixture()]
        worker.tick(now=KICKOFF_AT - timedelta(days=1))
        worker.tick(now=KICKOFF_AT - timedelta(minutes=45))
        assert len(fcm.sent) == 1

        moved = KICKOFF_AT + timedelta(days=1)
        api.schedule = [make_fixture(kickoff=moved)]
        worker._schedule_fetched_at = None
        worker.tick(now=moved - timedelta(hours=2))
        worker.tick(now=moved - timedelta(minutes=45))

        assert len(fcm.sent) == 2, "the warning is about a different match now"

    def test_a_postponement_closes_every_moment(self, tmp_path):
        worker, api, fcm = make_worker(tmp_path)
        api.schedule = [make_fixture()]
        worker.tick(now=KICKOFF_AT - timedelta(days=1))

        api.schedule = [make_fixture(status="PST")]
        worker._schedule_fetched_at = None
        worker.tick(now=KICKOFF_AT - timedelta(hours=1))

        worker._schedule_fetched_at = None
        worker.tick(now=KICKOFF_AT - timedelta(minutes=45))
        assert fcm.sent == []


class TestDryRun:
    def test_nothing_leaves_the_machine(self, tmp_path):
        worker, api, fcm = make_worker(tmp_path, dry_run=True)
        api.schedule = [make_fixture()]
        worker.tick(now=KICKOFF_AT - timedelta(days=1))
        report = worker.tick(now=KICKOFF_AT - timedelta(minutes=45))

        assert fcm.sent == []
        assert report.dry_run == 1

    def test_it_still_records_so_a_real_run_does_not_repeat_it(self, tmp_path):
        worker, api, _ = make_worker(tmp_path, dry_run=True)
        api.schedule = [make_fixture()]
        worker.tick(now=KICKOFF_AT - timedelta(days=1))
        worker.tick(now=KICKOFF_AT - timedelta(minutes=45))

        assert worker.store.already_handled(1, "t45")


class TestRefusalWithoutValidation:
    def test_it_will_not_send_before_the_condition_is_proven(self, tmp_path):
        worker, api, fcm = make_worker(tmp_path)
        worker.negation_validated = False
        api.schedule = [make_fixture()]
        worker.tick(now=KICKOFF_AT - timedelta(days=1))
        report = worker.tick(now=KICKOFF_AT - timedelta(minutes=45))

        assert fcm.sent == []
        assert report.failed == 1


class TestCondition:
    def test_it_gathers_the_bell_and_both_clubs_and_excludes_the_muted(self):
        condition = alert_condition(1, 541, 529, "ft")
        assert "'m1_ft' in topics" in condition
        assert "'c541_ft' in topics" in condition
        assert "'c529_ft' in topics" in condition
        assert "!('mute1' in topics)" in condition

    def test_it_stays_inside_the_documented_limit(self):
        condition = alert_condition(1, 2, 3, "ft")
        assert condition.count("in topics") <= 5


class TestRequestBudget:
    def test_the_chosen_cadence_fits_the_daily_quota(self):
        used = estimate_daily_requests(poll_seconds=60, schedule_refresh_seconds=1800)
        assert used < 7500, f"{used} requests/day exceeds the plan"
        # Leaves most of the quota for the app itself.
        assert used < 2500

    def test_the_naive_shape_would_not_have(self):
        # One request per league per day, every poll: 8 x 2 x 720.
        naive = 8 * 2 * (24 * 60 * 60 // 120)
        assert naive > 7500
