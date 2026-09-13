import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/models/fixture.dart';
import 'package:myservices_tv/models/match_alert.dart';
import 'package:myservices_tv/services/match_alerts_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the device asks to be told about, and what it is actually subscribed
/// to, are two different things — and the gap between them is where this
/// feature fails quietly. These pin the wishes and the topic set they produce.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const realMadrid = 541;
  const barcelona = 529;
  const alHilal = 2932;

  Fixture fixture({
    required int id,
    required int homeId,
    required int awayId,
    DateTime? kickoff,
    String status = 'NS',
  }) => Fixture(
    id: id,
    kickoff: kickoff ?? DateTime.utc(2026, 9, 20, 19, 0),
    statusShort: status,
    leagueId: 2,
    leagueName: 'UEFA Champions League',
    leagueLogoUrl: '',
    round: 'Regular Season - 5',
    home: FixtureTeam(id: homeId, name: 'Home', logoUrl: ''),
    away: FixtureTeam(id: awayId, name: 'Away', logoUrl: ''),
  );

  late MatchAlertsService alerts;
  late _FakeGateway gateway;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = _FakeGateway();
    alerts = MatchAlertsService.instance;
    await alerts.debugReset(withGateway: gateway);
    await alerts.load();
  });

  group('defaults', () {
    test('a new user gets the quiet pair, not all four', () {
      expect(alerts.types, MatchAlertType.quietDefault);
      expect(alerts.types, contains(MatchAlertType.before15));
      expect(alerts.types, contains(MatchAlertType.fullTime));
      expect(alerts.types, isNot(contains(MatchAlertType.before45)));
      expect(alerts.types, isNot(contains(MatchAlertType.kickoff)));
    });

    test('nothing is subscribed until something is asked for', () {
      expect(alerts.desiredTopics(), isEmpty);
    });
  });

  group('following a club', () {
    test('produces durable club topics, one per enabled type', () async {
      await alerts.setFollowClub(realMadrid, true);

      expect(alerts.desiredTopics(), {
        clubAlertTopic(realMadrid, MatchAlertType.before15),
        clubAlertTopic(realMadrid, MatchAlertType.fullTime),
      });
    });

    test('covers a fixture that does not exist on this device yet', () async {
      await alerts.setFollowClub(realMadrid, true);

      // The point of a club topic: nothing about a future fixture has to be
      // known here for the sender to reach this device.
      final topics = alerts.desiredTopics();
      expect(topics.every((t) => t.startsWith('c$realMadrid')), isTrue);
      expect(
        topics.any((t) => t.contains('999999')),
        isFalse,
        reason: 'club coverage must not depend on per-match subscriptions',
      );
    });

    test('enabling a type widens every followed club at once', () async {
      await alerts.setFollowClub(realMadrid, true);
      await alerts.setFollowClub(barcelona, true);
      await alerts.setType(MatchAlertType.kickoff, true);

      expect(alerts.desiredTopics(), containsAll([
        clubAlertTopic(realMadrid, MatchAlertType.kickoff),
        clubAlertTopic(barcelona, MatchAlertType.kickoff),
      ]));
    });
  });

  group('a bell on one match', () {
    test('subscribes that fixture, per enabled type', () async {
      final match = fixture(id: 1001, homeId: realMadrid, awayId: barcelona);
      await alerts.setBell(match, true);

      expect(alerts.desiredTopics(), {
        matchAlertTopic(1001, MatchAlertType.before15),
        matchAlertTopic(1001, MatchAlertType.fullTime),
      });
    });

    test('survives the screen moving to another day', () async {
      final match = fixture(id: 1001, homeId: realMadrid, awayId: barcelona);
      await alerts.setBell(match, true);

      // Nothing tells the service what is on screen any more; the bell knows
      // its own kickoff. An earlier design dropped anything missing from the
      // loaded day, so flicking to tomorrow unsubscribed today.
      expect(alerts.desiredTopics(), isNotEmpty);
    });

    test('expires only well after its own kickoff', () async {
      final kickoff = DateTime.utc(2026, 9, 20, 19, 0);
      await alerts.setBell(
        fixture(id: 1001, homeId: realMadrid, awayId: barcelona, kickoff: kickoff),
        true,
      );

      // Still wanted at the final whistle, and through extra time and
      // penalties — the result alert has not been sent yet.
      expect(
        alerts.desiredTopics(now: kickoff.add(const Duration(hours: 3))),
        isNotEmpty,
        reason: 'the result alert would be lost if this expired at full time',
      );
      expect(
        alerts.desiredTopics(now: kickoff.add(const Duration(hours: 6))),
        isEmpty,
      );
    });
  });

  group('the two together', () {
    test('a bell and a followed club cannot produce two notifications', () async {
      await alerts.setFollowClub(realMadrid, true);
      final match = fixture(id: 1001, homeId: realMadrid, awayId: barcelona);
      await alerts.setBell(match, true);

      // Both routes exist, but the sender addresses one club topic and one
      // match topic for different audiences; the device is in both, so the
      // worker must send once. What this pins is that the app does not invent
      // a third, overlapping subscription.
      final topics = alerts.desiredTopics();
      expect(topics, contains(clubAlertTopic(realMadrid, MatchAlertType.fullTime)));
      expect(topics, contains(matchAlertTopic(1001, MatchAlertType.fullTime)));
    });

    test('following both clubs of one match adds no third subscription', () async {
      await alerts.setFollowClub(realMadrid, true);
      await alerts.setFollowClub(barcelona, true);

      expect(alerts.desiredTopics(), hasLength(4)); // 2 clubs x 2 types
    });
  });

  group('muting one match of a followed club', () {
    test('joins the mute topic and drops that match', () async {
      await alerts.setFollowClub(realMadrid, true);
      final match = fixture(id: 1001, homeId: realMadrid, awayId: barcelona);
      await alerts.setBell(match, true);
      await alerts.setBell(match, false);

      final topics = alerts.desiredTopics();
      expect(alerts.isMuted(1001), isTrue);
      expect(topics, contains(muteTopic(1001)));
      expect(
        topics,
        isNot(contains(matchAlertTopic(1001, MatchAlertType.fullTime))),
      );
      // The club itself is untouched — only this match was refused.
      expect(
        topics,
        contains(clubAlertTopic(realMadrid, MatchAlertType.fullTime)),
      );
    });

    test('a match with no followed club is simply unsubscribed', () async {
      final match = fixture(id: 2002, homeId: alHilal, awayId: 99);
      await alerts.setBell(match, true);
      await alerts.setBell(match, false);

      expect(alerts.isMuted(2002), isFalse, reason: 'nothing to mute it from');
      expect(alerts.desiredTopics(), isEmpty);
    });

    test('setting the bell again overrules an earlier mute', () async {
      await alerts.setFollowClub(realMadrid, true);
      final match = fixture(id: 1001, homeId: realMadrid, awayId: barcelona);
      await alerts.setBell(match, true);
      await alerts.setBell(match, false);
      await alerts.setBell(match, true);

      expect(alerts.isMuted(1001), isFalse);
      expect(alerts.desiredTopics(), isNot(contains(muteTopic(1001))));
    });
  });

  group('the master switch', () {
    test('off means nothing is wanted, whatever else is set', () async {
      await alerts.setFollowClub(realMadrid, true);
      await alerts.setBell(
        fixture(id: 1001, homeId: realMadrid, awayId: barcelona),
        true,
      );
      expect(alerts.desiredTopics(), isNotEmpty);

      await alerts.setEnabled(false);
      expect(alerts.desiredTopics(), isEmpty);
    });

    test('on again restores exactly what was there before', () async {
      await alerts.setFollowClub(realMadrid, true);
      final before = alerts.desiredTopics();

      await alerts.setEnabled(false);
      await alerts.setEnabled(true);

      expect(alerts.desiredTopics(), before);
    });

    test('turning every type off leaves nothing wanted', () async {
      await alerts.setFollowClub(realMadrid, true);
      for (final type in MatchAlertType.quietDefault) {
        await alerts.setType(type, false);
      }
      expect(alerts.desiredTopics(), isEmpty);
    });
  });

  group('persistence', () {
    test('wishes survive a restart', () async {
      await alerts.setFollowClub(realMadrid, true);
      await alerts.setType(MatchAlertType.before45, true);
      await alerts.setBell(
        fixture(id: 1001, homeId: realMadrid, awayId: barcelona),
        true,
      );
      final before = alerts.desiredTopics();

      // A fresh process reading the same disk.
      await alerts.debugReset();
      await alerts.load();

      expect(alerts.followsClub(realMadrid), isTrue);
      expect(alerts.hasBell(1001), isTrue);
      expect(alerts.types, contains(MatchAlertType.before45));
      expect(alerts.desiredTopics(), before);
    });
  });

  group('permission is asked for at the right moment, and only then', () {
    test('nothing is asked for at rest', () {
      expect(gateway.permissionAsks, 0);
    });

    test('the first bell asks once', () async {
      await alerts.setBell(
        fixture(id: 1001, homeId: realMadrid, awayId: barcelona),
        true,
      );
      expect(gateway.permissionAsks, 1);
    });

    test('a refusal records no wish, so no switch shows as on', () async {
      gateway.permissionGranted = false;
      await alerts.setFollowClub(realMadrid, true);

      expect(alerts.followsClub(realMadrid), isFalse);
      expect(alerts.desiredTopics(), isEmpty);
      expect(alerts.syncState, AlertSyncState.permissionDenied);
      expect(alerts.lastError, isNotNull);
    });

    test('turning things OFF never asks for permission', () async {
      await alerts.setFollowClub(realMadrid, true);
      final asksAfterOptIn = gateway.permissionAsks;

      await alerts.setEnabled(false);
      await alerts.setFollowClub(realMadrid, false);

      expect(
        gateway.permissionAsks,
        asksAfterOptIn,
        reason: 'asking for permission in order to switch something off would '
            'be perverse',
      );
    });
  });

  group('a subscription that does not take', () {
    test('leaves the state failed rather than ok', () async {
      gateway.subscribeSucceeds = false;
      await alerts.setFollowClub(realMadrid, true);

      expect(alerts.syncState, AlertSyncState.failed);
      expect(alerts.subscribedTopics, isEmpty);
      expect(alerts.lastError, isNotNull);
    });

    test('retrying after the cause clears succeeds', () async {
      gateway.subscribeSucceeds = false;
      await alerts.setFollowClub(realMadrid, true);
      expect(alerts.syncState, AlertSyncState.failed);

      gateway.subscribeSucceeds = true;
      await alerts.retrySync();

      expect(alerts.syncState, AlertSyncState.ok);
      expect(alerts.subscribedTopics, alerts.desiredTopics());
    });
  });

  group('switching everything off when the unsubscribe fails', () {
    test('does not claim success, and keeps the topics on the books', () async {
      await alerts.setFollowClub(realMadrid, true);
      expect(alerts.subscribedTopics, isNotEmpty);

      gateway.unsubscribeSucceeds = false;
      await alerts.setEnabled(false);

      expect(
        alerts.syncState,
        AlertSyncState.failed,
        reason: 'the device is still subscribed; saying "done" here means the '
            'user keeps getting alerts they switched off',
      );
      expect(
        alerts.subscribedTopics,
        isNotEmpty,
        reason: 'the record must still show what we have not managed to remove',
      );
    });

    test('and succeeds once the cause clears', () async {
      await alerts.setFollowClub(realMadrid, true);
      gateway.unsubscribeSucceeds = false;
      await alerts.setEnabled(false);

      gateway.unsubscribeSucceeds = true;
      await alerts.retrySync();

      expect(alerts.syncState, AlertSyncState.ok);
      expect(alerts.subscribedTopics, isEmpty);
    });
  });

  group('a reissued token', () {
    test('is re-asserted from scratch, not assumed to have carried over',
        () async {
      await alerts.setFollowClub(realMadrid, true);
      final wanted = alerts.desiredTopics();
      gateway.subscribed.clear();

      gateway.tokenChanges.add(null);
      await Future<void>.delayed(Duration.zero);
      await alerts.retrySync();

      expect(
        gateway.subscribed.toSet(),
        wanted,
        reason: 'subscriptions live against a token; a new one has none',
      );
      expect(alerts.subscribedTopics, wanted);
    });
  });

  group('rapid changes', () {
    test('three bells in a row leave the record matching the wishes', () async {
      final matches = [
        fixture(id: 1, homeId: realMadrid, awayId: 11),
        fixture(id: 2, homeId: barcelona, awayId: 22),
        fixture(id: 3, homeId: alHilal, awayId: 33),
      ];

      // Not awaited individually: overlapping reconciles against one record is
      // exactly the race this has to survive.
      await Future.wait(matches.map((m) => alerts.setBell(m, true)));

      expect(alerts.subscribedTopics, alerts.desiredTopics());
      expect(alerts.syncState, AlertSyncState.ok);
    });

    test('a bell flicked on and off settles on off', () async {
      final match = fixture(id: 7, homeId: alHilal, awayId: 33);
      await alerts.setBell(match, true);
      await alerts.setBell(match, false);
      await alerts.setBell(match, true);
      await alerts.setBell(match, false);

      expect(alerts.hasBell(7), isFalse);
      expect(alerts.subscribedTopics, alerts.desiredTopics());
      expect(alerts.subscribedTopics, isEmpty);
    });
  });

  group('pruning', () {
    test('a long-finished bell is forgotten and unsubscribed', () async {
      final kickoff = DateTime.utc(2026, 9, 20, 19, 0);
      await alerts.setBell(
        fixture(id: 1001, homeId: realMadrid, awayId: barcelona, kickoff: kickoff),
        true,
      );
      expect(alerts.subscribedTopics, isNotEmpty);

      await alerts.pruneAndSync(now: kickoff.add(const Duration(hours: 9)));

      expect(alerts.hasBell(1001), isFalse);
      expect(alerts.subscribedTopics, isEmpty);
      expect(gateway.unsubscribed, isNotEmpty);
    });
  });
}

/// A push layer that does exactly what it is told to do, including failing.
class _FakeGateway implements AlertsGateway {
  bool permissionGranted = true;
  bool subscribeSucceeds = true;
  bool unsubscribeSucceeds = true;

  final List<String> subscribed = [];
  final List<String> unsubscribed = [];
  int permissionAsks = 0;

  final StreamController<void> tokenChanges = StreamController<void>.broadcast();

  @override
  Future<bool> ensurePermission() async {
    permissionAsks++;
    return permissionGranted;
  }

  @override
  Future<bool> subscribe(String topic) async {
    if (!subscribeSucceeds) return false;
    subscribed.add(topic);
    return true;
  }

  @override
  Future<bool> unsubscribe(String topic) async {
    if (!unsubscribeSucceeds) return false;
    unsubscribed.add(topic);
    return true;
  }

  @override
  Stream<void> get onTokenChanged => tokenChanges.stream;
}
