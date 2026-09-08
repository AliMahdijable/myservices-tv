import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/models/channel.dart';
import 'package:myservices_tv/screens/home_screen.dart';
import 'package:myservices_tv/services/fixtures_service.dart';
import 'package:myservices_tv/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The fixtures section used to replace the whole screen with a route that had
/// neither a bottom bar nor a back button, so opening it stranded the user
/// there. It is now a page of the home shell: the bar stays put, marks where
/// you are, and a horizontal drag moves between destinations.
void main() {
  String fixturesJson() => jsonEncode({
    'updated': '2026-09-08T18:00:00+03:00',
    'matches': [
      {
        'id': 'm1',
        'ts': '2026-09-08T19:45:00+03:00',
        'league': 'دوري أبطال أوروبا',
        'rank': 1,
        'state': 'in',
        'home': {'name': 'كلوب بروج', 'logo': '', 'score': '1'},
        'away': {'name': 'أستون فيلا', 'logo': '', 'score': '3'},
      },
    ],
    'standings': [
      {
        'league': 'دوري أبطال أوروبا',
        'rank': 1,
        'rows': [
          {
            'pos': 1,
            'name': 'ريال مدريد',
            'logo': '',
            'played': 6,
            'won': 5,
            'draw': 1,
            'lost': 0,
            'gf': 14,
            'ga': 4,
            'points': 16,
          },
        ],
      },
    ],
  });

  List<ChannelCategory> categories() => [
    ChannelCategory(
      name: 'sport',
      displayName: 'باقة رياضة',
      channels: List.generate(
        6,
        (i) => Channel(
          name: 'beIN SPORTS $i',
          url: 'http://host/$i',
          group: 'رياضة',
          streamId: i,
        ),
      ),
      sortOrder: 0,
    ),
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'fixtures_cache_v1': fixturesJson(),
      'fixtures_cache_time_v1': DateTime.now().millisecondsSinceEpoch,
    });
    FixturesService.debugSetAvailable(true);
  });

  tearDown(() => FixturesService.debugSetAvailable(null));

  Future<void> pumpShell(
    WidgetTester tester, {
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        locale: const Locale('ar'),
        home: HomeScreen(preloadedCategories: categories()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the bar stays visible on the fixtures page', (tester) async {
    await pumpShell(tester);

    await tester.tap(find.text('المباريات'));
    await tester.pumpAndSettle();

    expect(find.text('كلوب بروج'), findsOneWidget);
    // The whole bar — not just the destination that was tapped.
    expect(find.text('الرئيسية'), findsOneWidget);
    expect(find.text('بحث'), findsOneWidget);
    expect(find.text('الإعدادات'), findsOneWidget);
  });

  testWidgets('tapping الرئيسية from fixtures goes back', (tester) async {
    await pumpShell(tester);

    await tester.tap(find.text('المباريات'));
    await tester.pumpAndSettle();
    expect(find.text('كلوب بروج'), findsOneWidget);

    await tester.tap(find.text('الرئيسية'));
    await tester.pumpAndSettle();

    expect(find.text('كلوب بروج'), findsNothing);
    expect(find.text('باقة رياضة'), findsOneWidget);
  });

  testWidgets('dragging moves between destinations in both directions', (
    tester,
  ) async {
    await pumpShell(tester);
    expect(find.text('كلوب بروج'), findsNothing);

    // The app lays out left-to-right, so the next destination sits to the
    // right of this one and a leftward drag pulls it in.
    await tester.drag(find.text('باقة رياضة'), const Offset(-380, 0));
    await tester.pumpAndSettle();
    expect(find.text('كلوب بروج'), findsOneWidget);

    await tester.drag(find.text('كلوب بروج'), const Offset(380, 0));
    await tester.pumpAndSettle();
    expect(find.text('كلوب بروج'), findsNothing);
  });

  testWidgets('system back returns to home instead of leaving the app', (
    tester,
  ) async {
    await pumpShell(tester);

    await tester.tap(find.text('المباريات'));
    await tester.pumpAndSettle();
    expect(find.text('كلوب بروج'), findsOneWidget);

    final popped = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(popped, isTrue, reason: 'the shell must consume the pop');
    expect(find.text('كلوب بروج'), findsNothing);
  });

  testWidgets('the standings pill still switches the list', (tester) async {
    await pumpShell(tester);

    await tester.tap(find.text('المباريات'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('ترتيب الأندية'));
    await tester.pumpAndSettle();

    expect(find.text('ريال مدريد'), findsOneWidget);
  });

  testWidgets('no fixtures destination means nothing to swipe to', (
    tester,
  ) async {
    FixturesService.debugSetAvailable(false);
    await pumpShell(tester);

    expect(find.text('المباريات'), findsNothing);

    await tester.drag(find.text('باقة رياضة'), const Offset(-380, 0));
    await tester.pumpAndSettle();

    expect(find.text('باقة رياضة'), findsOneWidget);
  });
}
