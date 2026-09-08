import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/screens/fixtures_screen.dart';
import 'package:myservices_tv/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The screen is built from fixed-width pieces — 34dp numeric cells, a 66dp
/// day strip, two pills in one row — none of which can grow. These pin the
/// cases where that bit: a club name squeezed to a couple of letters on a
/// small phone, a day strip that opened on fixtures already played, and a
/// standings page with no way back to the matches.
void main() {
  Map<String, dynamic> team(int pos, String name) => {
    'pos': pos,
    'name': name,
    'logo': '',
    'played': 12,
    'won': 9,
    'draw': 2,
    'lost': 1,
    'gf': 28,
    'ga': 9,
    'points': 29,
  };

  Map<String, dynamic> match(String day, String home, String away) => {
    'id': '$day-$home',
    'ts': '${day}T19:45:00+03:00',
    'league': 'دوري أبطال أوروبا',
    'rank': 1,
    'state': 'post',
    'home': {'name': home, 'logo': '', 'score': '2'},
    'away': {'name': away, 'logo': '', 'score': '1'},
  };

  void seed({
    List<Map<String, dynamic>>? matches,
    List<Map<String, dynamic>>? standings,
  }) {
    SharedPreferences.setMockInitialValues({
      'fixtures_cache_v1': jsonEncode({
        'updated': '2026-09-08T18:00:00+03:00',
        'matches': matches ?? [],
        'standings': standings ?? [],
      }),
      'fixtures_cache_time_v1': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(320, 568),
    double scale = 1.0,
  }) async {
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
          child: const Scaffold(
            backgroundColor: AppColors.primaryDark,
            body: FixturesScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('standings on a small phone', () {
    setUp(() {
      seed(
        standings: [
          {
            'league': 'الدوري الإنجليزي',
            'rank': 3,
            'rows': [
              team(1, 'مانشستر سيتي'),
              team(2, 'نوتنغهام فوريست'),
            ],
          },
        ],
      );
    });

    testWidgets('leaves the club name room to be read', (tester) async {
      await pump(tester);
      await tester.tap(find.text('ترتيب الأندية'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);

      // A 320dp phone previously left this column about 36dp, which ellipsised
      // every club to a letter or two.
      final name = tester.getSize(find.text('نوتنغهام فوريست'));
      expect(
        name.width,
        greaterThan(80),
        reason: 'club name column collapsed to ${name.width}dp',
      );
    });

    testWidgets('drops the columns it cannot fit, keeping points', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.text('ترتيب الأندية'));
      await tester.pumpAndSettle();

      expect(find.text('نقاط'), findsOneWidget);
      expect(find.text('لعب'), findsOneWidget);
      expect(find.text('فاز'), findsNothing);
      expect(find.text('خسر'), findsNothing);
    });

    for (final scale in const [1.0, 1.5, 2.0, 3.0]) {
      testWidgets('survives text scale ${scale}x', (tester) async {
        await pump(tester, scale: scale);
        await tester.tap(find.text('ترتيب الأندية'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('a refresh with no tables cannot strand the user on them', (
    tester,
  ) async {
    seed(
      matches: [match('2026-09-08', 'ليفربول', 'أرسنال')],
      standings: [
        {
          'league': 'الدوري الإنجليزي',
          'rank': 3,
          'rows': [team(1, 'ليفربول')],
        },
      ],
    );
    await pump(tester);

    await tester.tap(find.text('ترتيب الأندية'));
    await tester.pumpAndSettle();
    expect(find.text('لعب'), findsOneWidget);

    // The tab row disappears with the tables, so the standings page would have
    // become a dead end.
    seed(matches: [match('2026-09-08', 'ليفربول', 'أرسنال')]);
    await tester.tap(find.byIcon(Icons.refresh_rounded).first);
    await tester.pumpAndSettle();

    expect(find.text('ترتيب الأندية'), findsNothing);
    expect(find.text('ليفربول'), findsWidgets);
  });

  testWidgets('with every fixture in the past it opens on the newest day', (
    tester,
  ) async {
    seed(
      matches: [
        match('2020-03-01', 'فريق قديم', 'خصم قديم'),
        match('2020-03-09', 'أحدث فريق', 'أحدث خصم'),
      ],
    );
    await pump(tester);

    // `days.first` used to win here, opening the screen eight days stale.
    expect(find.text('أحدث فريق'), findsOneWidget);
    expect(find.text('فريق قديم'), findsNothing);
  });

  testWidgets('the day strip scrolls the selected day into view', (
    tester,
  ) async {
    final today = DateTime.now();
    String stamp(int back) {
      final d = today.subtract(Duration(days: back));
      return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
    }

    seed(
      matches: [
        for (var i = 8; i >= 0; i--) match(stamp(i), 'مضيف $i', 'ضيف $i'),
      ],
    );
    await pump(tester);

    final chip = find.text('اليوم');
    expect(chip, findsOneWidget);

    final box = tester.getRect(chip);
    expect(
      box.left >= 0 && box.right <= 320,
      isTrue,
      reason: 'today sat off-screen at ${box.left}..${box.right}',
    );
  });
}
