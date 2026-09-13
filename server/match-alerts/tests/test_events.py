"""Time is a parameter here, so every awkward case can be played out at will."""

from datetime import datetime, timedelta, timezone

from match_alerts.events import (
    BEFORE_15,
    BEFORE_45,
    FULL_TIME,
    KICKOFF,
    Fixture,
    due_events,
)

KICKOFF_AT = datetime(2026, 9, 20, 19, 0, tzinfo=timezone.utc)
WINDOW = timedelta(seconds=120)


def fixture(**over) -> Fixture:
    base = dict(
        id=1,
        kickoff=KICKOFF_AT,
        status="NS",
        league_id=2,
        league_name="UEFA Champions League",
        home_id=541,
        home_name="Real Madrid",
        away_id=529,
        away_name="Barcelona",
    )
    base.update(over)
    return Fixture(**base)


def types(events):
    return [e.type for e in events]


class TestPreMatch:
    def test_nothing_is_due_long_before(self):
        at = KICKOFF_AT - timedelta(hours=3)
        assert due_events(fixture(), at, WINDOW, previous_status="NS") == []

    def test_the_45_alert_fires_inside_its_window(self):
        at = KICKOFF_AT - timedelta(minutes=45)
        assert BEFORE_45 in types(
            due_events(fixture(), at, WINDOW, previous_status="NS")
        )

    def test_it_does_not_fire_before_its_window(self):
        at = KICKOFF_AT - timedelta(minutes=46)
        assert types(due_events(fixture(), at, WINDOW, previous_status="NS")) == []

    def test_the_window_is_the_poll_not_ten_minutes(self):
        # An alert titled "in 45 minutes" arriving 35 minutes before kickoff is
        # wrong in a way the reader cannot detect. The window is seconds wide.
        at = KICKOFF_AT - timedelta(minutes=35)
        assert types(due_events(fixture(), at, WINDOW, previous_status="NS")) == []

    def test_the_title_states_the_real_remaining_minutes(self):
        at = KICKOFF_AT - timedelta(minutes=44)
        events = due_events(fixture(), at, WINDOW, previous_status="NS")
        assert events, "expected the 45 alert to still be inside its window"
        assert "٤٤" in events[0].title

    def test_a_match_already_under_way_gets_no_warning(self):
        at = KICKOFF_AT - timedelta(minutes=15)
        events = due_events(
            fixture(status="1H"), at, WINDOW, previous_status="1H"
        )
        assert BEFORE_15 not in types(events)


class TestKickoff:
    def test_the_clock_alone_does_not_announce_a_start(self):
        # Still NS at its scheduled time: the start is delayed, not happening.
        events = due_events(
            fixture(status="NS"), KICKOFF_AT, WINDOW, previous_status="NS"
        )
        assert KICKOFF not in types(events)

    def test_a_real_transition_into_play_does(self):
        events = due_events(
            fixture(status="1H"),
            KICKOFF_AT + timedelta(minutes=1),
            WINDOW,
            previous_status="NS",
        )
        assert KICKOFF in types(events)

    def test_a_first_sighting_announces_nothing(self):
        # No previous status means no observed transition.
        events = due_events(
            fixture(status="1H"),
            KICKOFF_AT + timedelta(minutes=1),
            WINDOW,
            previous_status=None,
        )
        assert KICKOFF not in types(events)

    def test_ns_to_second_half_after_an_outage_is_not_a_kickoff(self):
        # A worker down for an hour returns to NS followed by 2H. By the letter
        # of it that is a transition; announcing it would tell everyone a match
        # is starting while the second half is being played.
        events = due_events(
            fixture(status="2H"),
            KICKOFF_AT + timedelta(hours=1),
            WINDOW,
            previous_status="NS",
        )
        assert KICKOFF not in types(events)

    def test_suspended_is_not_playing(self):
        events = due_events(
            fixture(status="SUSP"),
            KICKOFF_AT + timedelta(minutes=1),
            WINDOW,
            previous_status="NS",
        )
        assert KICKOFF not in types(events)


class TestResult:
    def test_a_finished_match_reports_its_score(self):
        events = due_events(
            fixture(status="FT", home_goals=2, away_goals=1),
            KICKOFF_AT + timedelta(hours=2),
            WINDOW,
            previous_status="2H",
        )
        assert types(events) == [FULL_TIME]
        assert "2 - 1" in events[0].body

    def test_missing_goals_are_not_a_nil_nil(self):
        # API-Football can mark a fixture finished a moment before its goals
        # are populated. Filling the gap with zeroes announces a 0-0 that never
        # happened, to everyone, unretractably.
        events = due_events(
            fixture(status="FT", home_goals=None, away_goals=None),
            KICKOFF_AT + timedelta(hours=2),
            WINDOW,
            previous_status="2H",
        )
        assert events == []

    def test_a_shootout_reports_the_shootout(self):
        events = due_events(
            fixture(
                status="PEN",
                home_goals=1,
                away_goals=1,
                home_penalties=4,
                away_penalties=3,
            ),
            KICKOFF_AT + timedelta(hours=3),
            WINDOW,
            previous_status="P",
        )
        assert "4-3" in events[0].body
        assert "الترجيح" in events[0].body

    def test_a_shootout_without_its_score_does_not_guess_a_winner(self):
        events = due_events(
            fixture(status="PEN", home_goals=1, away_goals=1),
            KICKOFF_AT + timedelta(hours=3),
            WINDOW,
            previous_status="P",
        )
        assert "الترجيح" in events[0].title
        assert "4-3" not in events[0].body

    def test_extra_time_is_labelled(self):
        events = due_events(
            fixture(status="AET", home_goals=2, away_goals=1),
            KICKOFF_AT + timedelta(hours=3),
            WINDOW,
            previous_status="ET",
        )
        assert "الإضافي" in events[0].title

    def test_an_old_result_is_not_news(self):
        events = due_events(
            fixture(status="FT", home_goals=2, away_goals=1),
            KICKOFF_AT + timedelta(hours=12),
            WINDOW,
            previous_status="2H",
            max_result_age=timedelta(hours=4),
        )
        assert events == []


class TestCalledOff:
    def test_a_postponed_match_announces_nothing(self):
        at = KICKOFF_AT - timedelta(minutes=15)
        assert due_events(
            fixture(status="PST"), at, WINDOW, previous_status="NS"
        ) == []

    def test_a_cancelled_match_announces_nothing(self):
        assert due_events(
            fixture(status="CANC"), KICKOFF_AT, WINDOW, previous_status="NS"
        ) == []
