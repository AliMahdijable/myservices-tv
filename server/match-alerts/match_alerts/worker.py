"""The loop: look at what is being played, say what is due, remember saying it."""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass, field, replace
from datetime import date, datetime, timedelta, timezone

from .api_football import ApiFootball, ApiFootballError
from .config import Config
from .events import (
    ALL_TYPES,
    BEFORE_15,
    BEFORE_45,
    FULL_TIME,
    KICKOFF,
    LIVE_CODES,
    FINISHED_CODES,
    DueEvent,
    Fixture,
    due_events,
)
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
        report = TickReport()
        self._fresh_ids = set()
        self._refresh_schedule(now, report)
        fixtures = self._current_view(report, now)
        fresh = {f.id: f for f in fixtures if f.id in self._fresh_ids}
        if self.store.is_empty():
            if not fresh and report.api_errors:
                return report
            for fixture in fresh.values():
                self._baseline(fixture, now, report)
            self.store.mark_baselined()
            self.store.remember_tick(now)
            return report

        pending = {(p[0], p[1]): p for p in self.store.pending_events()}
        for key, item in list(pending.items()):
            lifetime = (timedelta(minutes=self.config.worker.max_result_age_minutes)
                        if item[1] == FULL_TIME else timedelta(
                            seconds=self.config.worker.pre_match_retry_seconds))
            if now - item[2] > lifetime:
                self.store.clear_pending(*key)
                self.store.record(*key, OUTCOME_SKIPPED, "pending expired")
                report.skipped_stale += 1
                del pending[key]

        for raw in fresh.values():
            report.fixtures_seen += 1
            previous = self.store.status_of(raw.id)
            observed = self.store.observed_at(raw.id)
            moved = self.store.kickoff_changed(raw.id, raw.kickoff)
            if moved:
                self.store.forget_pre_match(raw.id)
                self.store.clear_all_pending(raw.id)
                pending = {k: v for k, v in pending.items() if k[0] != raw.id}
                report.rescheduled += 1
            if previous == "PST" and (
                raw.status in LIVE_CODES or
                (raw.status in ("NS", "TBD") and raw.kickoff > now)
            ):
                self.store.reset_postponed(raw.id)
                previous, observed = None, None
            if self.store.authoritative_status(raw.id, raw.status) != raw.status:
                # Do not attach an old NS score to a newer FT status. Wait for
                # a fresh, non-regressing response instead of inventing data.
                continue
            fixture = raw
            finish_transition = fixture.is_finished and previous not in FINISHED_CODES
            if finish_transition:
                recently_live = (previous in LIVE_CODES and observed is not None
                                 and timedelta(0) <= now - observed <= timedelta(minutes=5))
                if not recently_live:
                    self.store.record(fixture.id, FULL_TIME, OUTCOME_SKIPPED,
                                      "finish first seen after an observation gap")
                    self.store.clear_pending(fixture.id, FULL_TIME)
                    report.skipped_stale += 1
            self.store.remember_status(fixture.id, fixture.kickoff, fixture.status, now)
            self.store.observe(fixture.id, now)
            if fixture.is_abnormal:
                self.store.clear_all_pending(fixture.id)
                self.store.set_awaiting_result(fixture.id, False)
                for kind in ALL_TYPES:
                    if not self.store.already_handled(fixture.id, kind):
                        self.store.record(fixture.id, kind, OUTCOME_SKIPPED,
                                          f"status {fixture.status}")
                continue

            result_age = now - (self.store.changed_at(fixture.id) or now)
            result_expired = result_age > timedelta(
                minutes=self.config.worker.max_result_age_minutes)
            if fixture.is_finished and result_expired:
                if not self.store.already_handled(fixture.id, FULL_TIME):
                    self.store.record(fixture.id, FULL_TIME, OUTCOME_SKIPPED, "result stale")
                    report.skipped_stale += 1
                self.store.clear_pending(fixture.id, FULL_TIME)
            self.store.set_awaiting_result(
                fixture.id, fixture.is_finished and not result_expired
                and not _result_is_complete(fixture)
                and not self.store.already_handled(fixture.id, FULL_TIME))
            candidates = {e.type: e for e in due_events(
                fixture, now, timedelta(seconds=self.config.worker.pre_match_window_seconds),
                previous_status=previous)}
            for key, item in pending.items():
                if key[0] != fixture.id or key[1] in candidates:
                    continue
                kind = key[1]
                if kind in (BEFORE_45, BEFORE_15):
                    retries = due_events(
                        fixture, now,
                        timedelta(seconds=self.config.worker.pre_match_window_seconds),
                        previous_status=fixture.status, enabled_types=(kind,))
                    if retries:
                        candidates[kind] = retries[0]
                elif kind == KICKOFF and fixture.status in ("1H", "LIVE"):
                    candidates[kind] = DueEvent(
                        fixture, kind, "بدأت المباراة",
                        f"{fixture.home_name} × {fixture.away_name}")
                # Full-time retries are regenerated from the fresh real score
                # above, so corrections and shootout scores are not discarded.
                if kind not in candidates:
                    self.store.clear_pending(*key)

            for kind, event in candidates.items():
                if self.store.already_handled(fixture.id, kind):
                    continue
                if (fixture.id, kind) in pending:
                    report.retried += 1
                report.due += 1
                self._handle(event, now, report)
        self.store.remember_tick(now)
        return report

    def _baseline(self, fixture: Fixture, now: datetime, report: TickReport) -> None:
        self.store.remember_status(fixture.id, fixture.kickoff, fixture.status, now)
        self.store.observe(fixture.id, now)
        for kind in ALL_TYPES:
            if _moment_has_passed(fixture, kind, now):
                self.store.record(fixture.id, kind, OUTCOME_SKIPPED, "baseline")
        report.baselined += 1

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
            if not result.retryable:
                # A read timeout can happen after FCM accepted the message.
                # Re-sending it could notify everyone twice. Preserve this
                # uncertainty in the ledger instead of guessing it failed.
                self.store.record(event.fixture.id, event.type, OUTCOME_SKIPPED,
                                  result.detail)
                self.store.clear_pending(event.fixture.id, event.type)
                report.failed += 1
                log.error("send not retried %s: %s", event.key, result.detail)
                return
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
                    self._fresh_ids.add(fixture.id)
            except ApiFootballError as error:
                report.api_errors.append(str(error))
                log.warning("%s", error)
                failed = True

        if failed and not fresh:
            # Keep whatever we had rather than forgetting the evening's
            # fixtures because one request timed out.
            return
        self._schedule = {**self._schedule, **fresh} if failed else fresh
        self._schedule_fetched_at = now

    def _current_view(self, report: TickReport, now: datetime) -> list[Fixture]:
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
                self._fresh_ids.add(fixture.id)
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
        # And the ones already known to have finished without a score. They are
        # gone from the live feed and their status will never change again, so
        # nothing else would ever ask about them.
        for fixture_id in self.store.awaiting_result_ids():
            changed = self.store.changed_at(fixture_id)
            if changed and now - changed > timedelta(
                minutes=self.config.worker.max_result_age_minutes
            ):
                self.store.set_awaiting_result(fixture_id, False)
                self.store.record(fixture_id, FULL_TIME, OUTCOME_SKIPPED, "result stale")
                self.store.clear_pending(fixture_id, FULL_TIME)
                continue
            if fixture_id not in live_now and fixture_id not in finishing:
                finishing.append(fixture_id)
        # Confirm cached reminders and queued sends against the source before
        # emitting them. A 30-minute schedule cache cannot prove a match has
        # not just been postponed. Pending-only lookups are batched as well.
        pending_ids = {p[0] for p in self.store.pending_events()}
        for fixture in self._schedule.values():
            possible = due_events(
                fixture, now,
                timedelta(seconds=self.config.worker.pre_match_window_seconds),
                enabled_types=(BEFORE_45, BEFORE_15))
            if possible:
                pending_ids.add(fixture.id)
        finishing.extend(sorted(pending_ids - set(finishing) - self._fresh_ids))
        if finishing:
            try:
                # by_ids chunks internally; truncating here would silently drop
                # the results of a busy evening's later matches.
                for fixture in self.api.by_ids(finishing):
                    merged[fixture.id] = fixture
                    self._fresh_ids.add(fixture.id)
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
    if alert_type == KICKOFF:
        return fixture.status in LIVE_CODES or fixture.is_finished or fixture.is_abnormal
    lead = LEAD_TIMES.get(alert_type, timedelta(0))
    return now >= fixture.kickoff - lead


def _with_status(fixture: Fixture, status: str) -> Fixture:
    """A copy of [fixture] carrying the status we believe to be true."""
    if status == fixture.status:
        return fixture
    return replace(fixture, status=status)


def _result_is_complete(fixture: Fixture) -> bool:
    """Whether the numbers needed to announce this result have arrived.

    A shootout is not complete until its shootout score is in: reporting the
    extra-time score alone would say a match that had a winner ended level.
    """
    if fixture.home_goals is None or fixture.away_goals is None:
        return False
    if fixture.status == "PEN":
        return (
            fixture.home_penalties is not None
            and fixture.away_penalties is not None
        )
    return True
