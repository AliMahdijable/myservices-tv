"""Reading and checking the worker's configuration.

Every value the worker needs is named here, so a missing or nonsensical
setting is a startup error with a sentence explaining it rather than a
traceback three hours later when a match kicks off.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass, field
from pathlib import Path

if sys.version_info >= (3, 11):
    import tomllib
else:  # Ubuntu 22.04 ships Python 3.10.
    import tomli as tomllib


class ConfigError(RuntimeError):
    """A configuration problem the operator has to fix before starting."""


@dataclass(frozen=True)
class ApiFootballConfig:
    key: str
    base: str
    leagues: tuple[int, ...]


@dataclass(frozen=True)
class FcmConfig:
    project_id: str
    #: Path to a service-account JSON, or None to use Application Default
    #: Credentials. The file is read by google-auth and never logged.
    credentials_file: Path | None


@dataclass(frozen=True)
class WorkerConfig:
    #: How often the live feed is read. One request each time.
    poll_seconds: int
    #: How often the day's fixture list is re-read. One request per day covered.
    schedule_refresh_seconds: int
    state_db: Path
    #: How late a pre-match alert may be and still be sent. Sized to the poll,
    #: not to a comfortable round number: an alert titled "in 45 minutes" that
    #: arrives 35 minutes before kickoff is wrong in a way nobody can detect.
    pre_match_window_seconds: int
    #: A result older than this is not announced. Measured from when the
    #: finish was first seen, not from kickoff.
    max_result_age_minutes: int
    #: How long a failed pre-match alert stays worth retrying. Short: "in 45
    #: minutes" is worth nothing once the match has started.
    pre_match_retry_seconds: int
    dry_run: bool


@dataclass(frozen=True)
class Config:
    api: ApiFootballConfig
    fcm: FcmConfig
    worker: WorkerConfig
    #: Where this came from, for the startup banner.
    source: Path | None = field(default=None)

    @staticmethod
    def load(path: str | Path) -> "Config":
        path = Path(path)
        if not path.is_file():
            raise ConfigError(f"no config file at {path}")
        with path.open("rb") as handle:
            raw = tomllib.load(handle)
        return Config.from_dict(raw, source=path)

    @staticmethod
    def from_dict(raw: dict, source: Path | None = None) -> "Config":
        api = raw.get("api_football") or {}
        fcm = raw.get("fcm") or {}
        worker = raw.get("worker") or {}

        key = str(api.get("key") or "").strip()
        if not key or key.startswith("PUT-THE"):
            raise ConfigError("api_football.key is not set")

        leagues = tuple(int(x) for x in (api.get("leagues") or []))
        if not leagues:
            raise ConfigError("api_football.leagues is empty — nothing to watch")

        project_id = str(fcm.get("project_id") or "").strip()
        if not project_id:
            raise ConfigError("fcm.project_id is not set")

        credentials_raw = str(fcm.get("credentials_file") or "").strip()
        credentials = Path(credentials_raw) if credentials_raw else None
        if credentials is not None and not credentials.is_file():
            raise ConfigError(
                f"fcm.credentials_file points at {credentials}, which does not "
                "exist. Leave it empty to use Application Default Credentials."
            )

        poll = int(worker.get("poll_seconds", 60))
        if poll < 20:
            raise ConfigError(
                "worker.poll_seconds below 20 spends the daily API quota before "
                "the evening kickoffs"
            )

        schedule_refresh = int(worker.get("schedule_refresh_seconds", 1800))
        if schedule_refresh < poll:
            raise ConfigError(
                "worker.schedule_refresh_seconds must not be shorter than the "
                "poll; fixture times do not change that often"
            )

        window = int(worker.get("pre_match_window_seconds", 0)) or (poll * 2)
        if window < poll:
            raise ConfigError(
                "worker.pre_match_window_seconds shorter than the poll would "
                "let alerts fall between two passes and never be sent"
            )

        max_result_age = int(worker.get("max_result_age_minutes", 240))
        if max_result_age < 1:
            raise ConfigError("worker.max_result_age_minutes must be positive")

        pre_match_retry = int(worker.get("pre_match_retry_seconds", 300))
        if pre_match_retry < poll:
            raise ConfigError(
                "worker.pre_match_retry_seconds shorter than the poll leaves no "
                "pass in which to retry"
            )

        state_db = Path(str(worker.get("state_db") or "")).expanduser()
        if not str(state_db):
            raise ConfigError("worker.state_db is not set")

        return Config(
            api=ApiFootballConfig(
                key=key,
                base=str(api.get("base") or "https://v3.football.api-sports.io"),
                leagues=leagues,
            ),
            fcm=FcmConfig(project_id=project_id, credentials_file=credentials),
            worker=WorkerConfig(
                poll_seconds=poll,
                schedule_refresh_seconds=schedule_refresh,
                state_db=state_db,
                pre_match_window_seconds=window,
                max_result_age_minutes=max_result_age,
                pre_match_retry_seconds=pre_match_retry,
                # Absent means dry-run. Sending is the thing you opt into.
                dry_run=bool(worker.get("dry_run", True)),
            ),
            source=source,
        )
