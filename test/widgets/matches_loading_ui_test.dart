import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myservices_tv/screens/matches_screen.dart';
import 'package:myservices_tv/services/football_api_service.dart';
import 'package:myservices_tv/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Entering the page, leaving it and coming back used to throw the day away,
/// reload eight leagues at once, and greet the user with "تعذّر تحميل الدوري".
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FootballApiService.debugReset();
  });
  tearDown(FootballApiService.debugReset);

  String today() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  String payload(String day, {required String home, int league = 39}) =>
      jsonEncode({
        'errors': <String, String>{},
        'response': [
          {
            'fixture': {
              'id': home.hashCode & 0xffff,
              'date': '${day}T19:00:00+00:00',
              'status': {'short': 'NS', 'elapsed': null},
            },
            'league': {
              'id': league,
              'name': 'L$league',
              'logo': '',
              'round': 'R-5',
            },
            'teams': {
              'home': {'id': 1, 'name': home, 'logo': ''},
              'away': {'id': 2, 'name': 'Away', 'logo': ''},
            },
            'goals': {'home': null, 'away': null},
          },
        ],
      });

  final empty = jsonEncode({'errors': <String, String>{}, 'response': []});

  Future<void> drain(WidgetTester tester, {int frames = 90}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets(
    'a league that blips is never shown as an error',
    (tester) async {
      tester.view.physicalSize = const Size(430, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      var attempts = 0;
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.darkTheme,
              home: const MatchesScreen(active: true),
            ),
          );
          await drain(tester);

          expect(find.text('Alpha'), findsOneWidget);
          expect(
            find.textContaining('تعذّر'),
            findsNothing,
            reason: 'one 503 out of eight leagues must not reach the user',
          );
        },
        () => MockClient((request) async {
          final league = request.url.queryParameters['league'];
          if (league == '39') {
            attempts++;
            if (attempts == 1) return http.Response('unavailable', 503);
            return http.Response(payload(today(), home: 'Alpha'), 200);
          }
          return http.Response(empty, 200);
        }),
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets(
    'a league that is really down is named',
    (tester) async {
      tester.view.physicalSize = const Size(430, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.darkTheme,
              home: const MatchesScreen(active: true),
            ),
          );
          await drain(tester);

          expect(find.text('Alpha'), findsOneWidget);
          expect(
            find.textContaining('تعذّر'),
            findsOneWidget,
            reason: 'a real outage must not be swallowed by the retry',
          );
        },
        () => MockClient((request) async {
          final league = request.url.queryParameters['league'];
          if (league == '39') {
            return http.Response(payload(today(), home: 'Alpha'), 200);
          }
          if (league == '140') return http.Response('down', 503);
          return http.Response(empty, 200);
        }),
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets(
    'changing the day never shows the previous day underneath',
    (tester) async {
      tester.view.physicalSize = const Size(430, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final now = DateTime.now();
      final tomorrow = now.add(const Duration(days: 1));
      final tomorrowKey =
          '${tomorrow.year}-${tomorrow.month.toString().padLeft(2, '0')}-'
          '${tomorrow.day.toString().padLeft(2, '0')}';

      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.darkTheme,
              home: const MatchesScreen(active: true),
            ),
          );
          await drain(tester);
          expect(find.text('TodayTeam'), findsOneWidget);

          await tester.tap(find.text('غداً'));
          await tester.pump();

          // The moment the day changes the old rows are gone — before the new
          // answer arrives, not after it.
          expect(
            find.text('TodayTeam'),
            findsNothing,
            reason: "today's fixtures must not sit under tomorrow's heading",
          );

          await drain(tester);
          expect(find.text('TomorrowTeam'), findsOneWidget);
          expect(find.text('TodayTeam'), findsNothing);
        },
        () => MockClient((request) async {
          final league = request.url.queryParameters['league'];
          final date = request.url.queryParameters['date'];
          if (league != '39') return http.Response(empty, 200);
          return http.Response(
            payload(
              date!,
              home: date == tomorrowKey ? 'TomorrowTeam' : 'TodayTeam',
            ),
            200,
          );
        }),
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
