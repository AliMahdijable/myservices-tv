# match-alerts

Announces football matches to the phones that asked to hear about them: a
45-minute warning, a 15-minute warning, the kickoff, and the result.

It reads API-Football and sends through FCM. It stores no registration tokens
and keeps no record of who is listening — a device subscribes itself to topics,
and this only ever addresses a topic.

## What it sends to

One message per match moment, addressed with an FCM *condition*:

```
('m1234_ft' in topics || 'c541_ft' in topics || 'c529_ft' in topics)
  && !('mute1234' in topics)
```

* `m<fixture>_<type>` — someone put a bell on this match.
* `c<club>_<type>` — someone follows one of the clubs. This is what makes
  following work for fixtures that do not exist yet: the topic is durable and
  is resolved here, at send time, with nothing required of the phone.
* `mute<fixture>` — someone silenced this one match of a club they follow.

Four topics, inside FCM's documented limit of five. A device in more than one
of the OR terms is still sent one message, so a bell plus a followed club
cannot produce two notifications.

**The negation was unproven, so it was proven.** Firebase's topic
documentation describes `&&` and `||` and does not mention `!` anywhere, and
neither does the REST reference. Rather than assume it, the worker asks:

    2026-09-13 — validateOnly=True against the live API returned HTTP 200 for
    a condition combining a match bell with both club topics and excluding a
    mute topic with `!`. The operator works.

The check is not a one-off. It runs before every live start:

```
python -m match_alerts --config /etc/match-alerts/config.toml --validate-condition
```

That uses `validateOnly`, so FCM parses and checks the message and returns
without delivering it; no device is reached. Running
without a successful validation refuses to send rather than quietly sending
without the exclusion, because the failure would be invisible: the only symptom
is people who muted a match being notified about it.

## Requirements

* Python 3.10 or newer (Ubuntu 22.04's 3.10.12 is fine)
* An API-Football key
* A Google service account with `cloudmessaging.messages.create` and nothing
  else, as a JSON key file — or Application Default Credentials

## Install

```sh
sudo useradd --system --home /opt/match-alerts --shell /usr/sbin/nologin match-alerts
sudo mkdir -p /opt/match-alerts /etc/match-alerts
sudo cp -r match_alerts requirements.txt /opt/match-alerts/
sudo python3 -m venv /opt/match-alerts/venv
sudo /opt/match-alerts/venv/bin/pip install -r /opt/match-alerts/requirements.txt

sudo cp config.example.toml /etc/match-alerts/config.toml
sudo $EDITOR /etc/match-alerts/config.toml

# The service account key. Readable by the service user and nobody else.
sudo install -o match-alerts -g match-alerts -m 0400 \
    service-account.json /etc/match-alerts/service-account.json
sudo chown -R root:match-alerts /etc/match-alerts
sudo chmod 0750 /etc/match-alerts
sudo chmod 0640 /etc/match-alerts/config.toml /etc/match-alerts/service-account.json
sudo install -d -o match-alerts -g match-alerts -m 0750 /var/lib/match-alerts
```

## Run it once, sending nothing

`dry_run = true` is the default. Setting it to false enables the service;
`--send` overrides it for a single manual invocation. Use a separate state
database for simulations, because dry-run events are recorded as handled.

```sh
sudo -u match-alerts /opt/match-alerts/venv/bin/python -m match_alerts \
    --config /etc/match-alerts/config.toml --once --verbose
```

It prints what it *would* send, with the condition for each. The first pass
against an empty database is a baseline: moments that have already gone past
are written off so a first start does not announce an evening of results that
everyone already knows. Moments still to come are left alone.

## Go live

```sh
# 1. prove the condition
sudo -u match-alerts /opt/match-alerts/venv/bin/python -m match_alerts \
    --config /etc/match-alerts/config.toml --validate-condition

# 2. one real pass, watched
sudo -u match-alerts /opt/match-alerts/venv/bin/python -m match_alerts \
    --config /etc/match-alerts/config.toml --once --send --verbose

# 3. as a service
sudo cp systemd/match-alerts.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now match-alerts
journalctl -u match-alerts -f
```

`dry_run` in the config is the only thing that decides this for the service.
`--send` overrides it for one manual run and nothing else — there is no second
switch and no environment variable. Set `dry_run = false` once you are happy.

## The request budget

API-Football's plan allows 7,500 requests a day, shared with the app itself.

| read | cost | how often | per day |
|---|---|---|---|
| the day's fixtures, all competitions in one call | 1 request | every 30 min, for today and tomorrow | 96 |
| the live feed | 1 request | every 60 s | 1,440 |
| result lookups and confirming cached reminders | 1 request per 20 | as needed before sending | varies |

**1,536 base requests a day**, plus batched confirmations and retries. The obvious shape — one request per competition per day,
every poll — costs 11,520 and would exhaust the plan before the evening
kickoffs. There is a test asserting this.

## What it will not do

* Announce a kickoff because the clock said so. It waits for an observed
  transition into play, and only if that transition is recent — a worker that
  was down for an hour comes back to `NS` followed by `2H`, which is a
  transition by the letter of it.
* Report a score it does not have. A finished fixture whose goals have not
  been populated yet is not announced until they are; filling the gap with
  zeroes would announce a 0-0 that never happened.
* Report a shootout by its extra-time score, which is level by definition.
* Send a 45-minute warning 35 minutes before kickoff. The window is the
  polling interval, not a comfortable-sounding ten minutes, and the title
  states the real number of minutes left.
* Send times in the server's timezone. The box is on UTC; notifications say
  Asia/Baghdad.
* Repeat a recorded successful send after restarting. A process lock prevents
  two local senders sharing the same ledger. FCM has no exactly-once delivery
  guarantee: ambiguous transport outcomes are recorded and not retried, to
  avoid a second broadcast after a timeout that may have followed acceptance.
* Lose a moment because a send failed. A transition happens once, so a failed
  send is queued with the time it was observed and retried from there. A
  result may be retried for 15 minutes by default; "in 45 minutes" does not, so a queued
  reminder has a window of minutes, is regenerated from the current kickoff
  rather than replayed, and is dropped the moment the match starts, moves, or
  is called off.
* Give up on a result because the match left the live feed. A fixture marked
  finished before its goals arrive is kept on an awaiting-result list and
  asked about directly — its status will never change again, so nothing else
  would ever look.
* Announce a result first discovered after a long outage. A final result
  requires a live observation within the preceding five minutes; missing
  goals and shootout scores are awaited for up to 15 minutes. A long match
  is supported because freshness is independent of its scheduled kickoff.

## Files

```
match_alerts/config.py        settings, and the errors for getting them wrong
match_alerts/api_football.py  the two reads, and the request counter
match_alerts/events.py        which moments are due, and what each one says
match_alerts/store.py         the sent-log, the statuses, the retry queue
match_alerts/fcm.py           the condition, the send, the validation
match_alerts/worker.py        the loop
tests/                        54 behavior tests, using a controlled clock
```
