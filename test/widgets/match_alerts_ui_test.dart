import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/models/fixture.dart';
import 'package:myservices_tv/models/match_alert.dart';
import 'package:myservices_tv/screens/alert_settings_screen.dart';
import 'package:myservices_tv/services/match_alerts_service.dart';
import 'package:myservices_tv/theme/app_theme.dart';
import 'package:myservices_tv/widgets/club_follow_button.dart';
import 'package:myservices_tv/widgets/match_alert_bell.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The controls have one job beyond working: being honest. A bell that lights
/// up while the subscription behind it failed tells the user they will be
/// warned about a match they will then miss, and they stop watching for it
/// themselves.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const realMadrid = 541;
  const barcelona = 529;

  Fixture match({int id = 1001, String status = 'NS'}) => Fixture(
    id: id,
    kickoff: DateTime.now().add(const Duration(hours: 3)),
    statusShort: status,
    leagueId: 2,
    leagueName: 'UCL',
    leagueLogoUrl: '',
    round: 'Regular Season - 5',
    home: const FixtureTeam(id: realMadrid, name: 'ريال مدريد', logoUrl: ''),
    away: const FixtureTeam(id: barcelona, name: 'برشلونة', logoUrl: ''),
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

  /// Exactly as the app opens it: its own route, with nothing added.
  /// Service calls in a test body cross the storage channel, which the fake
  /// clock does not drive — so they are made through runAsync, which gives the
  /// real event loop a turn. Arranging state any other way hangs before the
  /// first frame is drawn.
  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.darkTheme, home: const AlertSettingsScreen()),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          backgroundColor: AppColors.primaryDark,
          body: Center(child: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('the bell', () {
    testWidgets('is outlined when nothing is wanted', (tester) async {
      await pump(tester, MatchAlertBell(fixture: match()));
      expect(find.byIcon(Icons.notifications_none_rounded), findsOneWidget);
    });

    testWidgets('fills once the subscription has really taken', (tester) async {
      await tester.runAsync(() => alerts.setBell(match(), true));
      expect(alerts.coverageOf(match()), AlertCoverage.on);

      await pump(tester, MatchAlertBell(fixture: match()));
      expect(find.byIcon(Icons.notifications_active_rounded), findsOneWidget);
    });

    testWidgets('does not fill when permission was refused', (tester) async {
      gateway.permissionGranted = false;
      await tester.runAsync(() => alerts.setBell(match(), true));

      await pump(tester, MatchAlertBell(fixture: match()));

      expect(
        find.byIcon(Icons.notifications_none_rounded),
        findsOneWidget,
        reason: 'a bell that lights up without a subscription is a lie',
      );
      expect(alerts.hasBell(1001), isFalse);
    });

    testWidgets('marks itself when the subscription failed', (tester) async {
      gateway.subscribeSucceeds = false;
      await tester.runAsync(() => alerts.setBell(match(), true));

      await pump(tester, MatchAlertBell(fixture: match()));

      // The wish is kept and will be retried, but the control must not claim
      // the alert is set: the user would stop watching for the match.
      expect(alerts.hasBell(1001), isTrue);
      expect(alerts.coverageOf(match()), AlertCoverage.failed);
      expect(find.byIcon(Icons.notification_important_rounded), findsOneWidget);
      expect(find.byIcon(Icons.notifications_active_rounded), findsNothing);
    });

    testWidgets('marks itself when switching off failed to unsubscribe', (
      tester,
    ) async {
      await tester.runAsync(
        () => alerts.setFollowClub(realMadrid, true, name: 'ريال مدريد'),
      );
      gateway.unsubscribeSucceeds = false;
      await tester.runAsync(() => alerts.setFollowClub(realMadrid, false));

      await pump(tester, MatchAlertBell(fixture: match()));

      // The device may still be subscribed. Showing "off" is the same lie in
      // reverse — the user believes they switched it off and it still rings.
      expect(alerts.coverageOf(match()), AlertCoverage.failed);
      expect(find.byIcon(Icons.notification_important_rounded), findsOneWidget);
    });

    testWidgets('shows as on for a match covered by a followed club', (
      tester,
    ) async {
      await tester.runAsync(
        () => alerts.setFollowClub(realMadrid, true, name: 'ريال مدريد'),
      );
      await pump(tester, MatchAlertBell(fixture: match()));

      expect(find.byIcon(Icons.notifications_active_rounded), findsOneWidget);
    });

    testWidgets('is not on while a stranded mute still excludes it', (
      tester,
    ) async {
      await tester.runAsync(
        () => alerts.setFollowClub(realMadrid, true, name: 'ريال مدريد'),
      );
      await tester.runAsync(() => alerts.setBell(match(), false));
      expect(alerts.subscribedTopics, contains(muteTopic(1001)));

      // Unmuting fails, so the exclusion is still in force at the sender. The
      // wanted topics are all joined — but an alert sent to them would be
      // filtered out for this device, so "on" would be a promise it cannot
      // keep.
      gateway.unsubscribeSucceeds = false;
      await tester.runAsync(() => alerts.unmute(1001));

      await pump(tester, MatchAlertBell(fixture: match()));

      expect(alerts.coverageOf(match()), isNot(AlertCoverage.on));
      expect(find.byIcon(Icons.notifications_active_rounded), findsNothing);
    });

    testWidgets('switching it off mutes just that match', (tester) async {
      await tester.runAsync(
        () => alerts.setFollowClub(realMadrid, true, name: 'ريال مدريد'),
      );
      await tester.runAsync(() => alerts.setBell(match(), false));

      await pump(tester, MatchAlertBell(fixture: match()));

      expect(find.byIcon(Icons.notifications_none_rounded), findsOneWidget);
      expect(alerts.isMuted(1001), isTrue);
      expect(
        alerts.followsClub(realMadrid),
        isTrue,
        reason: 'the club was not what was refused',
      );
    });
  });

  group('pressing it', () {
    // The service call crosses a platform channel, which lives outside the
    // test's fake clock: pumping alone never lets it finish. runAsync gives
    // the real event loop a turn, and the pump afterwards draws the result.
    Future<void> press(WidgetTester tester, Finder target) async {
      await tester.runAsync(() async {
        await tester.tap(target);
        await Future<void>.delayed(const Duration(milliseconds: 120));
      });
      await tester.pump();
    }

    testWidgets('subscribes the match', (tester) async {
      await pump(tester, MatchAlertBell(fixture: match()));
      await press(tester, find.byType(MatchAlertBell));

      expect(alerts.hasBell(1001), isTrue);
      expect(alerts.subscribedTopics, alerts.desiredTopics());
      expect(find.byIcon(Icons.notifications_active_rounded), findsOneWidget);
    });

    testWidgets('pressing again unsubscribes it', (tester) async {
      await pump(tester, MatchAlertBell(fixture: match()));
      await press(tester, find.byType(MatchAlertBell));
      expect(alerts.hasBell(1001), isTrue);

      await press(tester, find.byType(MatchAlertBell));

      expect(alerts.hasBell(1001), isFalse);
      expect(alerts.subscribedTopics, isEmpty);
      expect(find.byIcon(Icons.notifications_none_rounded), findsOneWidget);
    });

    testWidgets('a failed unsubscribe is marked, not claimed as off', (
      tester,
    ) async {
      await pump(tester, MatchAlertBell(fixture: match()));
      await press(tester, find.byType(MatchAlertBell));

      gateway.unsubscribeSucceeds = false;
      await press(tester, find.byType(MatchAlertBell));

      expect(
        alerts.subscribedTopics,
        isNotEmpty,
        reason: 'the device is still subscribed',
      );
      expect(find.byIcon(Icons.notification_important_rounded), findsOneWidget);
    });

    testWidgets('pressing a failed bell retries rather than reverses it', (
      tester,
    ) async {
      gateway.subscribeSucceeds = false;
      await pump(tester, MatchAlertBell(fixture: match()));
      await press(tester, find.byType(MatchAlertBell));
      expect(alerts.coverageOf(match()), AlertCoverage.failed);

      gateway.subscribeSucceeds = true;
      await press(tester, find.byType(MatchAlertBell));

      expect(alerts.hasBell(1001), isTrue, reason: 'the wish was not undone');
      expect(find.byIcon(Icons.notifications_active_rounded), findsOneWidget);
    });
  });

  group('the follow star', () {
    testWidgets('fills when a club is followed', (tester) async {
      await pump(
        tester,
        const ClubFollowButton(
          club: FixtureTeam(id: realMadrid, name: 'ريال مدريد', logoUrl: ''),
        ),
      );

      expect(find.byIcon(Icons.star_border_rounded), findsOneWidget);

      await tester.runAsync(
        () => alerts.setFollowClub(realMadrid, true, name: 'ريال مدريد'),
      );
      await tester.pump();

      expect(find.byIcon(Icons.star_rounded), findsOneWidget);
      expect(alerts.followsClub(realMadrid), isTrue);
    });

    testWidgets('remembers the name, so settings can say which club', (
      tester,
    ) async {
      await pump(
        tester,
        const ClubFollowButton(
          club: FixtureTeam(id: realMadrid, name: 'ريال مدريد', logoUrl: ''),
        ),
      );
      await tester.runAsync(
        () => alerts.setFollowClub(realMadrid, true, name: 'ريال مدريد'),
      );
      await tester.pump();

      // A followed club's next fixture may not be loaded, or may not exist
      // yet, so there is nothing to look the name up from later.
      expect(alerts.clubName(realMadrid), 'ريال مدريد');
    });

    testWidgets('does not fill when permission is refused', (tester) async {
      gateway.permissionGranted = false;
      await pump(
        tester,
        const ClubFollowButton(
          club: FixtureTeam(id: realMadrid, name: 'ريال مدريد', logoUrl: ''),
        ),
      );

      await tester.runAsync(
        () => alerts.setFollowClub(realMadrid, true, name: 'ريال مدريد'),
      );
      await tester.pump();

      expect(find.byIcon(Icons.star_border_rounded), findsOneWidget);
    });
  });

  group('the settings screen', () {
    testWidgets('opens on the quiet defaults', (tester) async {
      await pumpScreen(tester);

      expect(find.text(MatchAlertType.before15.label), findsOneWidget);
      expect(find.text(MatchAlertType.fullTime.label), findsOneWidget);
      expect(find.text(MatchAlertType.before45.label), findsOneWidget);

      final switches = tester.widgetList<SwitchListTile>(
        find.byType(SwitchListTile),
      );
      // master + four types
      expect(switches.length, 5);
    });

    testWidgets('the master switch turns everything off', (tester) async {
      await tester.runAsync(
        () => alerts.setFollowClub(realMadrid, true, name: 'ريال مدريد'),
      );
      await pumpScreen(tester);

      await tester.runAsync(() => alerts.setEnabled(false));
      await tester.pump();

      expect(alerts.enabled, isFalse);
      expect(alerts.desiredTopics(), isEmpty);
    });

    testWidgets('names the clubs being followed', (tester) async {
      await tester.runAsync(
        () => alerts.setFollowClub(realMadrid, true, name: 'ريال مدريد'),
      );
      await pumpScreen(tester);

      expect(find.text('ريال مدريد'), findsOneWidget);
    });

    testWidgets('lists a muted match and lets it be unmuted', (tester) async {
      await tester.runAsync(
        () => alerts.setFollowClub(realMadrid, true, name: 'ريال مدريد'),
      );
      await tester.runAsync(() => alerts.setBell(match(), false));
      await pumpScreen(tester);

      // The muted section sits below the types and the clubs, so reaching it
      // means scrolling — which is also what a user does.
      await tester.scrollUntilVisible(
        find.text('ريال مدريد × برشلونة'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      expect(find.text('ريال مدريد × برشلونة'), findsOneWidget);

      await tester.runAsync(() => alerts.unmute(1001));
      await tester.pump();

      expect(alerts.isMuted(1001), isFalse);
    });

    testWidgets('says so when the device is not really subscribed', (
      tester,
    ) async {
      gateway.subscribeSucceeds = false;
      await tester.runAsync(
        () => alerts.setFollowClub(realMadrid, true, name: 'ريال مدريد'),
      );
      await pumpScreen(tester);

      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
      expect(find.text('إعادة'), findsOneWidget);
    });

    testWidgets('retry clears the banner once it works', (tester) async {
      gateway.subscribeSucceeds = false;
      await tester.runAsync(
        () => alerts.setFollowClub(realMadrid, true, name: 'ريال مدريد'),
      );
      await pumpScreen(tester);

      gateway.subscribeSucceeds = true;
      await tester.runAsync(() => alerts.retrySync());
      await tester.pump();

      expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
      expect(alerts.subscribedTopics, alerts.desiredTopics());
    });
  });

  group('no overflow', () {
    for (final size in const [Size(320, 568), Size(430, 932)]) {
      for (final scale in const [1.0, 1.5, 2.0, 3.0]) {
        testWidgets('settings at ${size.width.toInt()}dp @${scale}x', (
          tester,
        ) async {
          await tester.runAsync(
            () => alerts.setFollowClub(realMadrid, true, name: 'ريال مدريد'),
          );
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.darkTheme,
              home: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: TextScaler.linear(scale),
                ),
                child: const AlertSettingsScreen(),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}

class _FakeGateway implements AlertsGateway {
  bool permissionGranted = true;
  bool subscribeSucceeds = true;
  bool unsubscribeSucceeds = true;
  final StreamController<void> tokenChanges =
      StreamController<void>.broadcast();

  @override
  Future<bool> ensurePermission() async => permissionGranted;

  @override
  Future<bool> subscribe(String topic) async => subscribeSucceeds;

  @override
  Future<bool> unsubscribe(String topic) async => unsubscribeSucceeds;

  @override
  Stream<void> get onTokenChanged => tokenChanges.stream;
}
