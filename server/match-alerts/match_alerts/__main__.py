"""Command line entry point.

    python -m match_alerts --config /etc/match-alerts/config.toml --once
    python -m match_alerts --config ... --validate-condition
    python -m match_alerts --config ... --send        # leaves dry-run

Sending is opt-in at every level: the config defaults to dry_run, and --send is
required to override it. Nothing here can send by accident.
"""

from __future__ import annotations

import argparse
import fcntl
import logging
import sys
from dataclasses import replace

from .config import Config, ConfigError
from .worker import Worker


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="match-alerts")
    parser.add_argument(
        "--config", default="/etc/match-alerts/config.toml", help="TOML config"
    )
    parser.add_argument(
        "--once", action="store_true", help="run a single pass and exit"
    )
    parser.add_argument(
        "--send",
        action="store_true",
        help="override dry_run for this run; config controls the service",
    )
    parser.add_argument(
        "--validate-condition",
        action="store_true",
        help=(
            "ask FCM whether it accepts the muted-exclusion condition. Uses "
            "validate_only, so it reaches no device and costs no quota."
        ),
    )
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    try:
        config = Config.load(args.config)
    except ConfigError as error:
        print(f"config: {error}", file=sys.stderr)
        return 2

    if args.send:
        config = replace(
            config, worker=replace(config.worker, dry_run=False)
        )

    worker = Worker(config)

    if args.validate_condition:
        result = worker.validate()
        if result.ok:
            print("FCM accepted a condition containing '!' — muting works.")
            return 0
        print(
            "FCM rejected the condition. Muting a single match of a followed "
            "club cannot be done this way.\n"
            f"  {result.detail}",
            file=sys.stderr,
        )
        return 1

    if not config.worker.dry_run:
        # Refusing to start rather than sending without the exclusion proven.
        result = worker.validate()
        if not result.ok:
            print(
                "refusing to send: the muted-exclusion condition was not "
                f"accepted by FCM.\n  {result.detail}",
                file=sys.stderr,
            )
            return 1
        logging.getLogger("match-alerts").info("condition validated, sending is live")

    # A manual --once invocation must not race the systemd service and send
    # the same event before either process writes its success to SQLite.
    process_lock = open(str(config.worker.state_db) + ".lock", "a")
    try:
        fcntl.flock(process_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("another sender is already using this state database", file=sys.stderr)
        return 2

    if args.once:
        report = worker.tick()
        print(
            f"seen={report.fixtures_seen} due={report.due} sent={report.sent} "
            f"dry={report.dry_run} stale={report.skipped_stale} "
            f"failed={report.failed} retried={report.retried} "
            f"baseline={report.baselined} "
            f"api_errors={len(report.api_errors)} "
            f"requests={worker.api.requests_made}"
        )
        for problem in report.api_errors:
            print(f"  api: {problem}", file=sys.stderr)
        return 1 if report.failed or report.api_errors else 0

    worker.run_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
