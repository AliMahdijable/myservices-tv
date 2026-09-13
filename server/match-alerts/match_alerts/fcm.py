"""Talking to FCM HTTP v1.

Two things are load-bearing here.

The first is the condition. One message per match moment reaches everyone who
asked for it — through a bell on that match or through following either club —
and excludes anyone who muted it. Four topics, within FCM's documented limit of
five.

The second is that the negation in that condition is treated as unproven.
Firebase's topic documentation describes `&&` and `||` and does not mention `!`
anywhere, and neither does the REST reference. An operator that may not exist
cannot be discovered in production, where the only symptom would be people who
muted a match being notified about it anyway. So the worker can validate it
against the live API — a real request with validate_only set, which FCM parses
and rejects or accepts without delivering anything — and refuses to send until
that has passed.

No credential, access token, or authorization header is ever logged.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import google.auth
import requests
from google.auth.transport.requests import Request as GoogleAuthRequest
from google.oauth2 import service_account

SCOPE = "https://www.googleapis.com/auth/firebase.messaging"

#: FCM's documented ceiling for a conditional expression.
MAX_TOPICS_PER_CONDITION = 5


class FcmError(RuntimeError):
    """A send or validation that did not succeed."""


def alert_condition(
    fixture_id: int,
    home_id: int,
    away_id: int,
    alert_type: str,
    *,
    exclude_muted: bool = True,
) -> str:
    """The audience for one match moment.

    Everyone with a bell on this match, plus everyone following either club,
    minus anyone who muted this match. Because a bell and a club subscription
    are separate topics in one OR, a device in both is still reached once —
    duplicate suppression is a property of sending one message rather than a
    rule applied afterwards.
    """
    terms = [
        f"'m{fixture_id}_{alert_type}' in topics",
        f"'c{home_id}_{alert_type}' in topics",
        f"'c{away_id}_{alert_type}' in topics",
    ]
    condition = "(" + " || ".join(terms) + ")"
    topics = len(terms)

    if exclude_muted:
        condition += f" && !('mute{fixture_id}' in topics)"
        topics += 1

    if topics > MAX_TOPICS_PER_CONDITION:
        raise FcmError(
            f"condition needs {topics} topics, FCM allows "
            f"{MAX_TOPICS_PER_CONDITION}"
        )
    return condition


@dataclass
class SendResult:
    ok: bool
    detail: str


class FcmClient:
    """Sends and validates messages for one Firebase project."""

    def __init__(
        self,
        project_id: str,
        credentials_file: Path | None = None,
        session: requests.Session | None = None,
    ) -> None:
        self.project_id = project_id
        self._credentials_file = credentials_file
        self._session = session or requests.Session()
        self._credentials = None

    @property
    def endpoint(self) -> str:
        return (
            "https://fcm.googleapis.com/v1/projects/"
            f"{self.project_id}/messages:send"
        )

    def _token(self) -> str:
        if self._credentials is None:
            if self._credentials_file is not None:
                self._credentials = (
                    service_account.Credentials.from_service_account_file(
                        str(self._credentials_file), scopes=[SCOPE]
                    )
                )
            else:
                # Application Default Credentials, for a box where the
                # credential is provided by the environment instead of a file.
                self._credentials, _ = google.auth.default(scopes=[SCOPE])
        if not self._credentials.valid:
            self._credentials.refresh(GoogleAuthRequest())
        return self._credentials.token

    def _post(self, message: dict, validate_only: bool) -> SendResult:
        body = {"message": message}
        if validate_only:
            body["validateOnly"] = True
        try:
            response = self._session.post(
                self.endpoint,
                headers={
                    # Never logged, never echoed. The only place it appears.
                    "Authorization": f"Bearer {self._token()}",
                    "Content-Type": "application/json; charset=UTF-8",
                },
                data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
                timeout=20,
            )
        except requests.RequestException as error:
            return SendResult(False, f"transport: {error.__class__.__name__}")

        if response.status_code == 200:
            return SendResult(True, "ok")

        # The response body carries FCM's own explanation and no secret of
        # ours, so it is worth keeping — truncated, because a stack of HTML
        # from a proxy is not worth a log file.
        return SendResult(
            False, f"http {response.status_code}: {response.text[:300]}"
        )

    def send_alert(
        self,
        *,
        condition: str,
        title: str,
        body: str,
        data: dict[str, str] | None = None,
        validate_only: bool = False,
    ) -> SendResult:
        message = {
            "condition": condition,
            "notification": {"title": title, "body": body},
            "data": {k: str(v) for k, v in (data or {}).items()},
            "apns": {
                "payload": {"aps": {"sound": "default"}},
                "headers": {
                    # A match alert is worthless an hour late; letting APNs
                    # drop it beats delivering it after the final whistle.
                    "apns-expiration": "0",
                },
            },
            "android": {"priority": "high", "ttl": "3600s"},
        }
        return self._post(message, validate_only)

    def validate_negation(self) -> SendResult:
        """Asks FCM whether it accepts a condition containing `!`.

        validate_only means FCM parses and checks the message and returns
        without delivering it, so this costs nothing and reaches no device. A
        rejection here is the difference between knowing the mute works and
        assuming it.
        """
        condition = alert_condition(1, 2, 3, "ft", exclude_muted=True)
        return self.send_alert(
            condition=condition,
            title="validation",
            body="validation",
            validate_only=True,
        )
