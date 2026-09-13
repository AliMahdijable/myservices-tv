"""Reading fixtures from API-Football, on a request budget.

The naive shape — one request per competition per day, every poll — costs
8 x 2 x 720 = 11,520 requests a day against a 7,500 limit, and that is before
the app itself asks for anything. So the worker does two different reads:

  * the **schedule**, one request per day for every competition at once,
    refreshed every half hour. Fixture times barely move, and a pre-match alert
    is computed from a cached kickoff without asking anyone.
  * the **live feed**, one request, every poll. It is the only thing that
    changes minute to minute, and it is what says a match has kicked off or
    finished.

That is roughly 1,500 requests a day. The counter below exists so the claim can
be checked rather than believed.
"""

from __future__ import annotations

from datetime import date, datetime, timezone

import requests

from .events import Fixture


class ApiFootballError(RuntimeError):
    pass


class ApiFootball:
    def __init__(
        self,
        key: str,
        base: str = "https://v3.football.api-sports.io",
        session: requests.Session | None = None,
    ) -> None:
        self._key = key
        self._base = base.rstrip("/")
        self._session = session or requests.Session()
        #: Every request this process has made, for the budget log line.
        self.requests_made = 0

    @staticmethod
    def season_for(day: date) -> int:
        """The season label API-Football expects for [day].

        European and Saudi leagues both run August through May, so a February
        fixture still belongs to the season named by the previous year.
        """
        return day.year if day.month >= 7 else day.year - 1

    # ── the two reads ──────────────────────────────────────────────────────

    def fixtures_on(
        self, day: date, leagues: tuple[int, ...] | None = None
    ) -> list[Fixture]:
        """Every fixture on [day], in one request, filtered locally."""
        fixtures = self._get("/fixtures", {"date": day.isoformat()})
        if leagues is None:
            return fixtures
        wanted = set(leagues)
        return [f for f in fixtures if f.league_id in wanted]

    def live(self, leagues: tuple[int, ...] | None = None) -> list[Fixture]:
        """Every match in play right now, in one request."""
        fixtures = self._get("/fixtures", {"live": "all"})
        if leagues is None:
            return fixtures
        wanted = set(leagues)
        return [f for f in fixtures if f.league_id in wanted]

    def by_ids(self, fixture_ids: list[int]) -> list[Fixture]:
        """Specific fixtures, for confirming a result the live feed dropped.

        API-Football accepts at most twenty ids per call, so this is chunked.
        """
        out: list[Fixture] = []
        for start in range(0, len(fixture_ids), 20):
            chunk = fixture_ids[start : start + 20]
            if not chunk:
                continue
            out.extend(self._get("/fixtures", {"ids": "-".join(map(str, chunk))}))
        return out

    # ── one place that talks to the network ────────────────────────────────

    def _get(self, path: str, params: dict[str, str]) -> list[Fixture]:
        self.requests_made += 1
        try:
            response = self._session.get(
                f"{self._base}{path}",
                headers={"x-apisports-key": self._key},
                params=params,
                timeout=20,
            )
        except requests.RequestException as error:
            raise ApiFootballError(
                f"{path} {params}: {error.__class__.__name__}"
            ) from error

        if response.status_code != 200:
            raise ApiFootballError(f"{path} {params}: http {response.status_code}")

        try:
            body = response.json()
        except ValueError as error:
            raise ApiFootballError(f"{path} {params}: body is not JSON") from error

        # A dead key, a lapsed subscription and an exhausted quota all arrive as
        # HTTP 200 with an empty response and a populated `errors`. Reading that
        # as "no matches" is how a sender goes quiet for a week unnoticed.
        errors = body.get("errors")
        if isinstance(errors, (dict, list)) and errors:
            raise ApiFootballError(f"{path}: api error {errors}")

        raw = body.get("response")
        if not isinstance(raw, list):
            raise ApiFootballError(f"{path}: no response list")

        out = []
        for item in raw:
            fixture = Fixture.from_api(item)
            if fixture is not None:
                out.append(fixture)
        return out

    @staticmethod
    def today_utc() -> date:
        return datetime.now(timezone.utc).date()


def estimate_daily_requests(
    poll_seconds: int, schedule_refresh_seconds: int, days_ahead: int = 2
) -> int:
    """Requests per day for a given cadence, so the budget can be asserted."""
    day = 24 * 60 * 60
    live_calls = day // max(1, poll_seconds)
    schedule_calls = (day // max(1, schedule_refresh_seconds)) * days_ahead
    return int(live_calls + schedule_calls)
