"""The sent-log: what has already been announced, and what must never be again.

This is the only piece of state the worker keeps, and the only thing standing
between a restart and a second round of notifications for matches that were
already announced. It is SQLite on disk for exactly that reason — an in-memory
set would be emptied by the very event it exists to survive.
"""

from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from pathlib import Path

_SCHEMA = """
CREATE TABLE IF NOT EXISTS sent (
    fixture_id  INTEGER NOT NULL,
    event_type  TEXT    NOT NULL,
    sent_at     TEXT    NOT NULL,
    outcome     TEXT    NOT NULL,
    detail      TEXT,
    PRIMARY KEY (fixture_id, event_type)
);

CREATE TABLE IF NOT EXISTS kickoffs (
    fixture_id  INTEGER PRIMARY KEY,
    kickoff     TEXT NOT NULL,
    status      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Events that were detected but not successfully sent.
--
-- A transition is observed once. Without somewhere to put it, a kickoff whose
-- send failed would be lost the moment the status was written down: the next
-- pass sees 2H followed by 2H, no transition, nothing to announce. The moment
-- is recorded here when it happens and retried from here afterwards.
CREATE TABLE IF NOT EXISTS pending (
    fixture_id  INTEGER NOT NULL,
    event_type  TEXT    NOT NULL,
    observed_at TEXT    NOT NULL,
    title       TEXT    NOT NULL,
    body        TEXT    NOT NULL,
    attempts    INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (fixture_id, event_type)
);
"""

#: How far a status may move. A live feed that drops a match must not push it
#: back to "not started", and a refreshed schedule must not either.
_STATUS_RANK = {
    "TBD": 0, "NS": 0,
    "1H": 1, "HT": 1, "2H": 1, "ET": 1, "BT": 1, "P": 1, "LIVE": 1,
    "SUSP": 1, "INT": 1,
    "FT": 2, "AET": 2, "PEN": 2,
    "PST": 3, "CANC": 3, "ABD": 3, "AWD": 3, "WO": 3,
}

#: Statuses that mean the match is in play, mirrored from events.PLAYING_CODES
#: so the store can answer "what was live last pass" without importing it.
_LIVE = ("1H", "2H", "HT", "ET", "BT", "P", "LIVE")

#: Recorded against an event that was deliberately not sent, so it is never
#: reconsidered — a stale catch-up, or a match that was called off.
OUTCOME_SKIPPED = "skipped"
OUTCOME_SENT = "sent"
OUTCOME_DRY_RUN = "dry-run"
OUTCOME_FAILED = "failed"


class SentLog:
    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(str(self.path), isolation_level=None)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.executescript(_SCHEMA)

    def close(self) -> None:
        self._db.close()

    # ── the duplicate guard ────────────────────────────────────────────────

    def already_handled(self, fixture_id: int, event_type: str) -> bool:
        """True if this moment has been dealt with, successfully or not.

        A failed send counts as handled only if it was recorded as such by
        [record]; the worker records failures separately so they can be retried
        without the success path having to know the difference.
        """
        row = self._db.execute(
            "SELECT outcome FROM sent WHERE fixture_id=? AND event_type=?",
            (fixture_id, event_type),
        ).fetchone()
        if row is None:
            return False
        # A failure is worth another attempt; everything else is final.
        return row[0] != OUTCOME_FAILED

    def record(
        self,
        fixture_id: int,
        event_type: str,
        outcome: str,
        detail: str | None = None,
    ) -> None:
        self._db.execute(
            "INSERT INTO sent (fixture_id, event_type, sent_at, outcome, detail)"
            " VALUES (?,?,?,?,?)"
            " ON CONFLICT(fixture_id, event_type) DO UPDATE SET"
            "   sent_at=excluded.sent_at,"
            "   outcome=excluded.outcome,"
            "   detail=excluded.detail",
            (
                fixture_id,
                event_type,
                datetime.now(timezone.utc).isoformat(),
                outcome,
                detail,
            ),
        )

    # ── the cold-start baseline ────────────────────────────────────────────

    def is_empty(self) -> bool:
        """True before the first pass has ever run against this database.

        Distinct from "no rows": a run that baselined an empty evening has
        still run, and must not baseline again tomorrow.
        """
        row = self._db.execute(
            "SELECT value FROM meta WHERE key='baselined'"
        ).fetchone()
        return row is None

    def mark_baselined(self) -> None:
        self._db.execute(
            "INSERT INTO meta (key, value) VALUES ('baselined', ?)"
            " ON CONFLICT(key) DO NOTHING",
            (datetime.now(timezone.utc).isoformat(),),
        )

    # ── status, for detecting a real kickoff ───────────────────────────────

    def status_of(self, fixture_id: int) -> str | None:
        """The status this fixture had on the previous pass, if any.

        Kickoff is announced on the transition into play. Without the previous
        status there is no transition to observe, and nothing is announced —
        which is what makes a first sighting of an already-running match quiet.
        """
        row = self._db.execute(
            "SELECT status FROM kickoffs WHERE fixture_id=?", (fixture_id,)
        ).fetchone()
        if row is None or not row[0]:
            return None
        return str(row[0])

    def remember_status(
        self, fixture_id: int, kickoff: datetime, status: str
    ) -> None:
        """Records the status, refusing to move it backwards.

        The schedule read returns every fixture as it was listed — NS — and the
        live feed drops a match the moment it ends. Written naively, a finished
        match reverts to "not started" on the next schedule refresh and is then
        announced as kicking off all over again.
        """
        current = self.status_of(fixture_id)
        if current is not None:
            if _STATUS_RANK.get(status, 0) < _STATUS_RANK.get(current, 0):
                # Keep the more advanced status; still take the new kickoff,
                # since a rescheduled match really does move.
                self._db.execute(
                    "UPDATE kickoffs SET kickoff=? WHERE fixture_id=?",
                    (kickoff.astimezone(timezone.utc).isoformat(), fixture_id),
                )
                return
        self._db.execute(
            "INSERT INTO kickoffs (fixture_id, kickoff, status) VALUES (?,?,?)"
            " ON CONFLICT(fixture_id) DO UPDATE SET"
            "   kickoff=excluded.kickoff, status=excluded.status",
            (fixture_id, kickoff.astimezone(timezone.utc).isoformat(), status),
        )

    # ── outstanding events ─────────────────────────────────────────────────

    def add_pending(
        self,
        fixture_id: int,
        event_type: str,
        observed_at: datetime,
        title: str,
        body: str,
    ) -> None:
        self._db.execute(
            "INSERT INTO pending"
            " (fixture_id, event_type, observed_at, title, body, attempts)"
            " VALUES (?,?,?,?,?,0)"
            " ON CONFLICT(fixture_id, event_type) DO NOTHING",
            (
                fixture_id,
                event_type,
                observed_at.astimezone(timezone.utc).isoformat(),
                title,
                body,
            ),
        )

    def pending_events(self) -> list[tuple[int, str, datetime, str, str, int]]:
        rows = self._db.execute(
            "SELECT fixture_id, event_type, observed_at, title, body, attempts"
            " FROM pending"
        ).fetchall()
        return [
            (
                int(r[0]),
                str(r[1]),
                datetime.fromisoformat(str(r[2])),
                str(r[3]),
                str(r[4]),
                int(r[5]),
            )
            for r in rows
        ]

    def bump_attempt(self, fixture_id: int, event_type: str) -> None:
        self._db.execute(
            "UPDATE pending SET attempts = attempts + 1"
            " WHERE fixture_id=? AND event_type=?",
            (fixture_id, event_type),
        )

    def clear_pending(self, fixture_id: int, event_type: str) -> None:
        self._db.execute(
            "DELETE FROM pending WHERE fixture_id=? AND event_type=?",
            (fixture_id, event_type),
        )

    def live_fixture_ids(self) -> list[int]:
        """Fixtures that were in play last pass.

        One dropping out of the live feed is how a finish announces itself, so
        these are the ones worth asking about directly.
        """
        placeholders = ",".join("?" for _ in _LIVE)
        rows = self._db.execute(
            f"SELECT fixture_id FROM kickoffs WHERE status IN ({placeholders})",
            _LIVE,
        ).fetchall()
        return [int(r[0]) for r in rows]

    # ── rescheduling ───────────────────────────────────────────────────────

    def kickoff_changed(self, fixture_id: int, kickoff: datetime) -> bool:
        """Records [kickoff] and says whether it differs from what we had.

        A fixture that moves has to be able to warn people again: its
        45-minute alert was either already sent for a time that no longer
        exists, or was skipped as stale. Either way the old record is about a
        different match than the one that will now be played.
        """
        stamp = kickoff.astimezone(timezone.utc).isoformat()
        row = self._db.execute(
            "SELECT kickoff FROM kickoffs WHERE fixture_id=?", (fixture_id,)
        ).fetchone()
        changed = row is not None and row[0] != stamp
        self._db.execute(
            "INSERT INTO kickoffs (fixture_id, kickoff, status) VALUES (?,?,?)"
            " ON CONFLICT(fixture_id) DO UPDATE SET kickoff=excluded.kickoff",
            (fixture_id, stamp, ""),
        )
        return changed

    def forget_pre_match(self, fixture_id: int) -> None:
        """Clears the pre-match record for a fixture that has been rescheduled.

        The result alert is deliberately left alone: a match only finishes
        once, whatever its kickoff was moved to.
        """
        self._db.execute(
            "DELETE FROM sent WHERE fixture_id=? AND event_type IN (?,?,?)",
            (fixture_id, "t45", "t15", "ko"),
        )

    # ── housekeeping ───────────────────────────────────────────────────────

    def prune(self, before: datetime) -> int:
        """Drops rows for fixtures that kicked off before [before]."""
        stamp = before.astimezone(timezone.utc).isoformat()
        cursor = self._db.execute(
            "DELETE FROM sent WHERE fixture_id IN"
            " (SELECT fixture_id FROM kickoffs WHERE kickoff < ?)",
            (stamp,),
        )
        removed = cursor.rowcount or 0
        self._db.execute("DELETE FROM kickoffs WHERE kickoff < ?", (stamp,))
        return removed

    def counts(self) -> dict[str, int]:
        rows = self._db.execute(
            "SELECT outcome, COUNT(*) FROM sent GROUP BY outcome"
        ).fetchall()
        return {outcome: count for outcome, count in rows}
