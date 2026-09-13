"""Which match moments are due, and what each one says.

Pure functions over a fixture and a clock. Nothing here touches the network or
the database, so the awkward cases — a match that moves, one that is abandoned
at half time, a worker that was asleep when the whistle went — can be played
out in tests at any speed.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

# The app's four alert types. These strings are part of topic names, so they
# are the same tokens the Flutter side writes and must not be renamed in place.
BEFORE_45 = "t45"
BEFORE_15 = "t15"
KICKOFF = "ko"
FULL_TIME = "ft"

ALL_TYPES = (BEFORE_45, BEFORE_15, KICKOFF, FULL_TIME)

#: How long before kickoff each pre-match alert is due.
LEAD_TIMES = {
    BEFORE_45: timedelta(minutes=45),
    BEFORE_15: timedelta(minutes=15),
    KICKOFF: timedelta(0),
}

#: API-Football status codes, by what they mean for us.
LIVE_CODES = {"1H", "2H", "HT", "ET", "BT", "P", "SUSP", "INT", "LIVE"}
FINISHED_CODES = {"FT", "AET", "PEN"}
#: Postponed, cancelled, abandoned, awarded, walkover. A fixture in one of
#: these is not going to be played as scheduled, and anyone waiting for it
#: should stop waiting rather than be left with a warning that never resolves.
ABNORMAL_CODES = {"PST", "CANC", "ABD", "AWD", "WO"}

#: The audience is in Iraq; the server is on UTC. Set once, used everywhere a
#: time is written into a notification.
DISPLAY_TIMEZONE = "Asia/Baghdad"


@dataclass(frozen=True)
class Fixture:
    """Only the parts of an API-Football fixture this worker reasons about."""

    id: int
    kickoff: datetime
    status: str
    league_id: int
    league_name: str
    home_id: int
    home_name: str
    away_id: int
    away_name: str
    home_goals: int | None = None
    away_goals: int | None = None
    #: Shootout score, present only when [status] is PEN.
    home_penalties: int | None = None
    away_penalties: int | None = None

    @property
    def is_finished(self) -> bool:
        return self.status in FINISHED_CODES

    @property
    def is_abnormal(self) -> bool:
        return self.status in ABNORMAL_CODES

    @staticmethod
    def from_api(payload: dict) -> "Fixture | None":
        """Builds a fixture from one element of an API-Football response.

        Returns None rather than raising on a malformed record: one unusable
        fixture must not stop the other ninety from being announced.
        """
        try:
            fixture = payload["fixture"]
            league = payload["league"]
            teams = payload["teams"]
            goals = payload.get("goals") or {}
            score = payload.get("score") or {}
            penalty = score.get("penalty") or {}

            kickoff = datetime.fromisoformat(
                str(fixture["date"]).replace("Z", "+00:00")
            ).astimezone(timezone.utc)

            return Fixture(
                id=int(fixture["id"]),
                kickoff=kickoff,
                status=str((fixture.get("status") or {}).get("short") or "NS"),
                league_id=int(league["id"]),
                league_name=str(league.get("name") or ""),
                home_id=int(teams["home"]["id"]),
                home_name=str(teams["home"].get("name") or ""),
                away_id=int(teams["away"]["id"]),
                away_name=str(teams["away"].get("name") or ""),
                home_goals=_maybe_int(goals.get("home")),
                away_goals=_maybe_int(goals.get("away")),
                home_penalties=_maybe_int(penalty.get("home")),
                away_penalties=_maybe_int(penalty.get("away")),
            )
        except (KeyError, TypeError, ValueError):
            return None


def _maybe_int(value) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


@dataclass(frozen=True)
class DueEvent:
    """One thing to announce about one match."""

    fixture: Fixture
    type: str
    title: str
    body: str

    @property
    def key(self) -> str:
        """Identity in the sent-log. One row per match per moment, forever."""
        return f"{self.fixture.id}:{self.type}"


def due_events(
    fixture: Fixture,
    now: datetime,
    window: timedelta,
    previous_status: str | None = None,
    enabled_types: tuple[str, ...] = ALL_TYPES,
    max_result_age: timedelta | None = None,
    max_kickoff_age: timedelta = timedelta(minutes=20),
) -> list[DueEvent]:
    """The events that should be sent for [fixture] at [now].

    [window] is how late a pre-match alert may be and still be worth sending.
    It is sized to the polling interval, not to a comfortable-sounding ten
    minutes: an alert titled "in 45 minutes" that arrives 35 minutes before
    kickoff is wrong in a way the reader cannot detect.

    [previous_status] is what the fixture's status was on the last pass.
    Kickoff is announced on the transition into play, never on the clock alone
    — a match whose start is delayed is still NS at its scheduled time, and
    telling people it has begun because the hour arrived is simply false.

    [max_result_age] stops a worker that has been down all evening from
    announcing results that everyone already knows.
    """
    if fixture.is_abnormal:
        # Nothing to announce about a match that is not being played. The
        # pre-match alerts are deliberately withheld: a warning for a kickoff
        # that will not happen is worse than silence.
        return []

    out: list[DueEvent] = []

    for alert_type in (BEFORE_45, BEFORE_15):
        if alert_type not in enabled_types:
            continue
        due_at = fixture.kickoff - LEAD_TIMES[alert_type]
        if not (due_at <= now <= due_at + window):
            continue
        # Already under way, or already over: there is nothing to warn about.
        if fixture.status not in ("NS", "TBD"):
            continue
        out.append(_pre_match_event(fixture, alert_type, now))

    if KICKOFF in enabled_types and _has_started(
        fixture, previous_status, now, max_kickoff_age
    ):
        out.append(_pre_match_event(fixture, KICKOFF, now))

    if FULL_TIME in enabled_types and fixture.is_finished:
        if max_result_age is None or now - fixture.kickoff <= max_result_age:
            event = _full_time_event(fixture)
            if event is not None:
                out.append(event)

    return out


#: Statuses that mean the ball is in play. A suspended or interrupted match has
#: not just kicked off, and neither has one that is merely scheduled.
PLAYING_CODES = {"1H", "2H", "ET", "P", "LIVE"}


def _has_started(
    fixture: Fixture,
    previous_status: str | None,
    now: datetime,
    max_kickoff_age: timedelta,
) -> bool:
    """Whether this pass is the one where the match began.

    Requires an observed transition *and* that it is recent. Without a previous
    status — the first time this worker ever sees the fixture — nothing is
    announced. And a worker that was down for an hour comes back to find NS
    followed by 2H, which is a transition by the letter of it: without the age
    check it would tell everyone a match was kicking off while the second half
    was under way.
    """
    if previous_status is None:
        return False
    if previous_status not in ("NS", "TBD"):
        return False
    if fixture.status not in PLAYING_CODES:
        return False
    return now - fixture.kickoff <= max_kickoff_age


def _pre_match_event(
    fixture: Fixture, alert_type: str, now: datetime
) -> DueEvent:
    match_name = f"{fixture.home_name} × {fixture.away_name}"

    if alert_type == KICKOFF:
        return DueEvent(
            fixture=fixture,
            type=alert_type,
            title="بدأت المباراة",
            body=match_name,
        )

    # The real number of minutes left, not the name of the alert. If a pass is
    # a couple of minutes late, the notification says so instead of insisting
    # on a round number that has already passed.
    remaining = max(1, round((fixture.kickoff - now).total_seconds() / 60))
    title = f"بعد {_arabic_number(remaining)} دقيقة"
    body = f"{match_name} — {_local_time(fixture.kickoff)}"
    return DueEvent(fixture=fixture, type=alert_type, title=title, body=body)


def _full_time_event(fixture: Fixture) -> DueEvent | None:
    """The result, or nothing at all.

    A missing goal count is not a nil. API-Football can report a fixture as
    finished a moment before its goals are populated, and filling the gap with
    zeroes would announce a 0-0 that never happened — to everyone, at once,
    unretractably. When the numbers are not there yet the event is simply not
    due, and the next pass will find them.
    """
    home, away = fixture.home_goals, fixture.away_goals
    if home is None or away is None:
        return None

    body = f"{fixture.home_name} {home} - {away} {fixture.away_name}"

    if fixture.status == "PEN":
        # The goal count is the score after extra time, which for a shootout is
        # level. Reporting it alone would say a match that had a winner ended
        # as a draw.
        home_pens, away_pens = fixture.home_penalties, fixture.away_penalties
        if home_pens is None or away_pens is None:
            # Not yet. Saying "the result is coming shortly" would be the only
            # notification ever sent about this match — the event would be
            # recorded as handled and the real score would never follow.
            return None
        body += f" ({home_pens}-{away_pens} بركلات الترجيح)"
        title = "انتهت بركلات الترجيح"
    elif fixture.status == "AET":
        title = "انتهت بعد الوقت الإضافي"
    else:
        title = "انتهت المباراة"

    return DueEvent(fixture=fixture, type=FULL_TIME, title=title, body=body)


_ARABIC_DIGITS = str.maketrans("0123456789", "٠١٢٣٤٥٦٧٨٩")


def _local_time(moment: datetime) -> str:
    """12-hour Arabic time in the audience's timezone, not the server's.

    The VPS runs on UTC. Rendering its clock under an Arabic label would tell
    a reader in Baghdad that a 22:00 match starts at ٧:٠٠ مساءً.
    """
    try:
        local = moment.astimezone(ZoneInfo(DISPLAY_TIMEZONE))
    except Exception:  # noqa: BLE001 - a missing tzdata must not stop an alert
        local = moment.astimezone(timezone.utc)
        suffix = "صباحاً" if local.hour < 12 else "مساءً"
        hour = local.hour % 12 or 12
        return f"{hour}:{local.minute:02d} {suffix} بتوقيت UTC".translate(
            _ARABIC_DIGITS
        )

    suffix = "صباحاً" if local.hour < 12 else "مساءً"
    hour = local.hour % 12 or 12
    return f"{hour}:{local.minute:02d} {suffix}".translate(_ARABIC_DIGITS)


def _arabic_number(value: int) -> str:
    return str(value).translate(_ARABIC_DIGITS)
