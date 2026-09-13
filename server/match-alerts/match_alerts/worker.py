"""The loop: look at what is being played, say what is due, remember saying it."""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone

from .api_football import ApiFootball, ApiFootballError
from .config import Config
from .events import ALL_TYPES, DueEvent, Fixture, due_events
from .fcm import FcmClient, FcmError, SendResult, alert_condition
from .store import (
    OUTCOME_DRY_RUN,
    OUTCOME_FAILED,
    OUTCOME_SENT,
    OUTCOME_SKIPPED,
    SentLog,
)

log = logging.getLogger("match-alerts")


@dataclass
class TickReport:
    """What one pass did, so a dry run can be read rather than guessed at."""

    fixtures_seen: int = 0
    due: int = 0
    sent: int = 0
    dry_run: int = 0
    skipped_stale: int = 0
    rescheduled: int = 0
    failed: int = 0
    baselined: int = 0
    retried: int = 0
    api_errors: list[str] = field(default_factory=list)


class Worker:
    def __init__(
        self,
        config: Config,
        api: ApiFootball | None = None,
        fcm: FcmClient | None = None,
        store: SentLog | None = None,
    ) -> None:
        self.config = config
        self.api = api or ApiFootball(config.api.key, config.api.base)
        self.fcm = fcm or FcmClient(
            config.fcm.project_id, config.fcm.credentials_file
        )
        self.store = store or SentLog(config.worker.state_db)

        #: Set by [validate]. Nothing is sent while this is False, because the
        #: exclusion that keeps muted users quiet has not been proven to work.
        self.negation_validated = False

        self._schedule: dict[int, Fixture] = {}
        self._schedule_fetched_at: datetime | None = None

    # ── startup check ──────────────────────────────────────────────────────

    def validate(self) -> SendResult:
        """Proves FCM accepts the muted-exclusion condition, without sending."""
        result = self.fcm.validate_negation()
        self.negation_validated = result.ok
        return result

    # ── one pass ───────────────────────────────────────────────────────────

    def tick(self, now: datetime | None = None) -> TickReport:
        now = now or datetime.now(timezone.utc)
        window = timedelta(seconds=self.config.worker.pre_match_window_seconds)
        max_result_age = timedelta(
            minutes=self.config.worker.max_result_age_minutes
        )
        report = TickReport()

        self._refresh_schedule(now, report)
        fixtures = self._current_view(report)

        # The first time this worker ever runs it must not announce an evening
        # of results everyone already knows, nor a kickoff from an hour ago.
        # Only the moments that have already gone past are written off —
        # tomorrow's fixtures keep every one of their alerts, which an earlier
        # version silently threw away along with the rest.
        if self.store.is_empty():
            if not fixtures and report.api_errors:
                # Every read failed. Baselining on no information would write
                # off nothing and then claim the worker had started cleanly.
                log.error("first run: no fixtures could be read, not baselining")
                return report
            for fixture in fixtures:
                self._baseline(fixture, now, report)
            self.store.mark_baselined()
            log.info(
                "first run: %d fixtures seen, past moments written off",
                report.baselined,
            )
            return report

        report.retried = self._retry_pending(now, report)

        for fixture in fixtures:
            report.fixtures_seen += 1
            previous_status = self.store.status_of(fixture.id)

            # A fixture that has moved gets its pre-match record cleared, so the
            # warnings can be given again for the time it will now be played.
            if self.store.kickoff_changed(fixture.id, fixture.kickoff):
                self.store.forget_pre_match(fixture.id)
                report.rescheduled += 1
                log.info("fixture %s was rescheduled", fixture.id)

            self.store.remember_status(fixture.id, fixture.kickoff, fixture.status)

            if fixture.is_abnormal:
                # Called off. Close out every moment so nothing fires later if
                # the status flaps back.
                for alert_type in ALL_TYPES:
                    if not self.store.already_handled(fixture.id, alert_type):
                        self.store.record(
                            fixture.id,
                            alert_type,
                            OUTCOME_SKIPPED,
                            f"status {fixture.status}",
                        )
                continue

            for event in due_events(
                fixture,
                now,
                window,
                previous_status=previous_status,
                max_result_age=max_result_age,
            ):
                if self.store.already_handled(event.fixture.id, event.type):
                    continue
                report.due += 1
                self._handle(event, now, report)

        return report

    def _baseline(
        self, fixture: Fixture, now: datetime, report: TickReport
    ) -> None:
        """Writes off the moments that have already gone past.

        Deliberately selective. A match tomorrow evening has had none of its
        moments yet, and writing them off because the worker happened to start
        today would cost the user every alert for the first two days — the
        exact window in which they are deciding whether the feature works.
        """
        self.store.remember_status(fixture.id, fixture.kickoff, fixture.status)
        for alert_type in ALL_TYPES:
            if _moment_has_passed(fixture, alert_type, now):
                self.store.record(
                    fixture.id, alert_type, OUTCOME_SKIPPED, "baseline"
                )
        report.baselined += 1

    def _retry_pending(self, now: datetime, report: TickReport) -> int:
        """Re-attempts events whose send failed, while they are still worth it.

        A transition is observed once. Retrying from the observation rather
        than from the transition is what makes a failed kickoff recoverable:
        by the next pass the status has moved on and there is no transition
        left to notice.
        """
        freshness = timedelta(minutes=self.config.worker.max_result_age_minutes)
        retried = 0
        for fixture_id, event_type, observed_at, title, body, attempts in (
            self.store.pending_events()
        ):
            if now - observed_at > freshness:
                self.store.clear_pending(fixture_id, event_type)
                self.store.record(
                    fixture_id, event_type, OUTCOME_SKIPPED, "pending expired"
                )
                report.skipped_stale += 1
                continue

            fixture = self._schedule.get(fixture_id)
            if fixture is None:
                continue
            event = DueEvent(
                fixture=fixture, type=event_type, title=title, body=body
            )
            self.store.bump_attempt(fixture_id, event_type)
            retried += 1
            self._handle(event, now, report)
        return retried

    def _handle(
        self, event: DueEvent, now: datetime, report: TickReport
    ) -> None:
        try:
            condition = alert_condition(
                event.fixture.id,
                event.fixture.home_id,
                event.fixture.away_id,
                event.type,
            )
        except FcmError as error:
            self.store.record(
                event.fixture.id, event.type, OUTCOME_FAILED, str(error)
            )
            report.failed += 1
            return

        if self.config.worker.dry_run:
            report.dry_run += 1
            log.info(
                "DRY RUN would send %s | %s | %s | condition=%s",
                event.key,
                event.title,
                event.body,
                condition,
            )
            self.store.record(
                event.fixture.id, event.type, OUTCOME_DRY_RUN, condition
            )
            self.store.clear_pending(event.fixture.id, event.type)
            return

        if not self.negation_validated:
            # Refusing rather than quietly sending without the exclusion: a
            # muted user notified anyway is the failure this guards against.
            self.store.add_pending(
                event.fixture.id, event.type, now, event.title, event.body
            )
            self.store.record(
                event.fixture.id,
                event.type,
                OUTCOME_FAILED,
                "condition negation not validated",
            )
            report.failed += 1
            log.error(
                "refusing to send %s: run --validate-condition first", event.key
            )
            return

        result = self.fcm.send_alert(
            condition=condition,
            title=event.title,
            body=event.body,
            data={
                "fixtureId": str(event.fixture.id),
                "leagueId": str(event.fixture.league_id),
                "type": event.type,
            },
        )
        if result.ok:
            self.store.record(event.fixture.id, event.type, OUTCOME_SENT)
            self.store.clear_pending(event.fixture.id, event.type)
            report.sent += 1
            log.info("sent %s", event.key)
        else:
            # Queued rather than merely marked: the transition that produced
            # this event will not happen again.
            self.store.add_pending(
                event.fixture.id, event.type, now, event.title, event.body
            )
            self.store.record(
                event.fixture.id, event.type, OUTCOME_FAILED, result.detail
            )
            report.failed += 1
            log.error("send failed %s: %s", event.key, result.detail)

    # ── what is being played ───────────────────────────────────────────────

    def _refresh_schedule(self, now: datetime, report: TickReport) -> None:
        """Re-reads today's and tomorrow's fixtures, rarely.

        Kickoff times barely move, so this is the cheap half of the budget:
        one request per day covered, twice an hour.
        """
        due = (
            self._schedule_fetched_at is None
            or now - self._schedule_fetched_at
            >= timedelta(seconds=self.config.worker.schedule_refresh_seconds)
        )
        if not due:
            return

        days: list[date] = [now.date(), (now + timedelta(days=1)).date()]
        fresh: dict[int, Fixture] = {}
        failed = False
        for day in days:
            try:
                for fixture in self.api.fixtures_on(day, self.config.api.leagues):
                    fresh[fixture.id] = fixture
            except ApiFootballError as error:
                report.api_errors.append(str(error))
                log.warning("%s", error)
                failed = True

        if failed and not fresh:
            # Keep whatever we had rather than forgetting the evening's
            # fixtures because one request timed out.
            return
        self._schedule = fresh
        self._schedule_fetched_at = now

    def _current_view(self, report: TickReport) -> list[Fixture]:
        """The schedule, with live statuses and scores laid over it.

        The live feed is the only thing that changes minute to minute, and it
        is what turns a scheduled fixture into one that has kicked off or
        finished.
        """
        merged = dict(self._schedule)
        live_seen: list[Fixture] = []
        try:
            live_seen = self.api.live(self.config.api.leagues)
            for fixture in live_seen:
                merged[fixture.id] = fixture
        except ApiFootballError as error:
            report.api_errors.append(str(error))
            log.warning("%s", error)

        # A match that was in play last pass and is absent from this pass's
        # live feed has almost certainly just ended. Only those are asked
        # about: testing "not finished" instead would re-request every match
        # currently being played, on every single poll.
        live_now = {f.id for f in live_seen}
        finishing = [
            fixture_id
            for fixture_id in self.store.live_fixture_ids()
            if fixture_id not in live_now
        ]
        if finishing:
            try:
                # by_ids chunks internally; truncating here would silently drop
                # the results of a busy evening's later matches.
                for fixture in self.api.by_ids(finishing):
                    merged[fixture.id] = fixture
            except ApiFootballError as error:
                report.api_errors.append(str(error))
                log.warning("%s", error)

        return list(merged.values())

    # ── the loop ───────────────────────────────────────────────────────────

    def run_forever(self) -> None:
        log.info(
            "watching %d competitions, live every %ds, schedule every %ds "
            "(dry_run=%s)",
            len(self.config.api.leagues),
            self.config.worker.poll_seconds,
            self.config.worker.schedule_refresh_seconds,
            self.config.worker.dry_run,
        )
        last_prune = datetime.now(timezone.utc)
        while True:
            started = time.monotonic()
            try:
                report = self.tick()
                if report.due or report.api_errors or report.baselined:
                    log.info(
                        "seen=%d due=%d sent=%d dry=%d stale=%d failed=%d "
                        "rescheduled=%d baseline=%d api_errors=%d requests=%d",
                        report.fixtures_seen,
                        report.due,
                        report.sent,
                        report.dry_run,
                        report.skipped_stale,
                        report.failed,
                        report.rescheduled,
                        report.baselined,
                        len(report.api_errors),
                        self.api.requests_made,
                    )
            except Exception:  # noqa: BLE001 - the loop must outlive a bad pass
                log.exception("tick failed")

            now = datetime.now(timezone.utc)
            if now - last_prune > timedelta(hours=6):
                removed = self.store.prune(now - timedelta(days=7))
                last_prune = now
                if removed:
                    log.info("pruned %d old rows", removed)

            elapsed = time.monotonic() - started
            time.sleep(max(1.0, self.config.worker.poll_seconds - elapsed))


def _moment_has_passed(fixture: Fixture, alert_type: str, now: datetime) -> bool:
    """Whether [alert_type] for [fixture] is already behind us.

    Used only by the cold-start baseline, to tell the moments that have gone
    from the ones that are still to come.
    """
    from .events import FULL_TIME, LEAD_TIMES

    if alert_type == FULL_TIME:
        return fixture.is_finished
    lead = LEAD_TIMES.get(alert_type, timedelta(0))
    return now >= fixture.kickoff - lead
