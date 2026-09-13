from datetime import timedelta
from test_worker import make_worker, make_fixture, KICKOFF_AT
from match_alerts.events import due_events, KICKOFF
from match_alerts.fcm import SendResult


def test_restart_after_outage_does_not_announce_an_old_result(tmp_path):
    worker, api, fcm = make_worker(tmp_path)
    api.schedule = [make_fixture()]
    worker.tick(now=KICKOFF_AT - timedelta(hours=1))
    api.live_now = [make_fixture(status="2H")]
    worker.tick(now=KICKOFF_AT + timedelta(minutes=60))
    worker.store.close()
    worker, api, fcm = make_worker(tmp_path)
    api.schedule = [make_fixture(status="FT", home_goals=3, away_goals=2)]
    worker.tick(now=KICKOFF_AT + timedelta(hours=3))
    assert fcm.sent == []
    assert worker.store.already_handled(1, "ft")


def test_cancellation_during_schedule_cache_is_confirmed_before_reminder(tmp_path):
    worker, api, fcm = make_worker(tmp_path)
    api.schedule = [make_fixture()]
    worker.tick(now=KICKOFF_AT - timedelta(minutes=50))
    api.by_id = {1: make_fixture(status="CANC")}
    worker.tick(now=KICKOFF_AT - timedelta(minutes=45))
    assert api.by_ids_calls == [[1]]
    assert fcm.sent == []


def test_pending_reminder_checks_new_cancellation_before_retry(tmp_path):
    worker, api, fcm = make_worker(tmp_path)
    api.schedule = [make_fixture()]
    worker.tick(now=KICKOFF_AT - timedelta(minutes=50))
    fcm.ok = False
    worker.tick(now=KICKOFF_AT - timedelta(minutes=45))
    fcm.ok = True
    api.by_id = {1: make_fixture(status="CANC")}
    worker.tick(now=KICKOFF_AT - timedelta(minutes=44))
    assert fcm.sent == []
    assert worker.store.pending_events() == []


def test_result_after_long_delay_uses_recent_live_observation(tmp_path):
    worker, api, fcm = make_worker(tmp_path)
    api.schedule = [make_fixture()]
    worker.tick(now=KICKOFF_AT - timedelta(hours=1))
    api.live_now = [make_fixture(status="2H")]
    worker.tick(now=KICKOFF_AT + timedelta(hours=5))
    api.live_now = []
    api.by_id = {1: make_fixture(status="FT", home_goals=2, away_goals=0)}
    worker.tick(now=KICKOFF_AT + timedelta(hours=5, minutes=1))
    assert len(fcm.sent) == 1
    assert "2 - 0" in fcm.sent[0][2]


def test_failed_result_retry_uses_corrected_score(tmp_path):
    worker, api, fcm = make_worker(tmp_path)
    api.schedule = [make_fixture()]
    worker.tick(now=KICKOFF_AT - timedelta(hours=1))
    api.live_now = [make_fixture(status="2H")]
    worker.tick(now=KICKOFF_AT + timedelta(minutes=109))
    api.live_now = []
    api.by_id = {1: make_fixture(status="FT", home_goals=1, away_goals=0)}
    fcm.ok = False
    worker.tick(now=KICKOFF_AT + timedelta(minutes=110))
    fcm.ok = True
    api.by_id = {1: make_fixture(status="FT", home_goals=2, away_goals=0)}
    worker.tick(now=KICKOFF_AT + timedelta(minutes=111))
    assert len(fcm.sent) == 1
    assert "2 - 0" in fcm.sent[0][2]


def test_delay_does_not_suppress_actual_first_minute_kickoff():
    fixture = make_fixture(status="1H", elapsed=1)
    events = due_events(fixture, KICKOFF_AT + timedelta(minutes=35),
                        timedelta(seconds=120), previous_status="NS")
    assert KICKOFF in [e.type for e in events]
    fixture = make_fixture(status="1H", elapsed=15)
    assert KICKOFF not in [e.type for e in due_events(
        fixture, KICKOFF_AT + timedelta(minutes=15),
        timedelta(seconds=120), previous_status="NS")]


def test_ambiguous_delivery_is_not_broadcast_again(tmp_path):
    worker, api, fcm = make_worker(tmp_path)
    api.schedule = [make_fixture()]
    worker.tick(now=KICKOFF_AT - timedelta(minutes=50))
    calls = []
    def ambiguous(**kwargs):
        calls.append(kwargs)
        return SendResult(False, "delivery unconfirmed: ReadTimeout", False)
    fcm.send_alert = ambiguous
    worker.tick(now=KICKOFF_AT - timedelta(minutes=45))
    worker.tick(now=KICKOFF_AT - timedelta(minutes=44))
    assert len(calls) == 1
