import pytest

from match_alerts.fcm import FcmClient, SendResult


@pytest.mark.parametrize("kind,ttl", [
    ("t45", 120), ("t15", 120), ("ko", 120), ("ft", 900),
    ("manual_test", 120),
])
def test_apns_can_retry_briefly_without_keeping_stale_notifications(
    monkeypatch, kind, ttl
):
    monkeypatch.setattr("match_alerts.fcm.time.time", lambda: 1800000000.9)
    client = FcmClient("test-project")
    captured = []

    def capture(message, validate_only):
        captured.append((message, validate_only))
        return SendResult(True, "ok")

    monkeypatch.setattr(client, "_post", capture)
    client.send_alert(
        condition="'m1_t15' in topics", title="test", body="test",
        data={"fixtureId": "1", "type": kind}, validate_only=True,
    )
    message, validate_only = captured[0]
    headers = message["apns"]["headers"]
    assert int(headers["apns-expiration"]) == 1800000000 + ttl
    assert headers["apns-priority"] == "10"
    assert headers["apns-push-type"] == "alert"
    assert headers["apns-collapse-id"] == f"match-1-{kind}"
    assert message["android"]["ttl"] == f"{ttl}s"
    assert validate_only is True
