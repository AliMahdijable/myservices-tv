import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myservices_tv/screens/matches_screen.dart';
import 'package:myservices_tv/services/football_api_service.dart';
import 'package:myservices_tv/theme/app_theme.dart';

void main() {
  setUp(FootballApiService.debugReset);

  testWidgets('first standings failure finishes loading and offers retry', (
    tester,
  ) async {
    FootballApiService.debugReset();
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var failStandings = true;
    Future<void> drain() async {
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
      }
    }

    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          MaterialApp(theme: AppTheme.darkTheme, home: const MatchesScreen()),
        );
        await drain();
        await tester.tap(find.text('الترتيب'));
        await drain();
        expect(find.textContaining('تعذّر تحديث الترتيب'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byType(TextButton), findsWidgets);
        failStandings = false;
        await tester.tap(find.byType(TextButton).last);
        await drain();
        expect(find.textContaining('الترتيب غير متاح حالياً'), findsOneWidget);
        expect(find.textContaining('تعذّر'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await drain();
      },
      () => MockClient(
        (request) async =>
            failStandings && request.url.path.endsWith('/standings')
            ? http.Response('unavailable', 503)
            : http.Response(jsonEncode({'errors': {}, 'response': []}), 200),
      ),
    );
  });

  testWidgets(
    'refresh keeps current rows, changing day hides them and ignores an older reply',
    (tester) async {
      FootballApiService.debugReset();
      tester.view.physicalSize = const Size(430, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final now = DateTime.now();
      final today =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      var hold = false;
      var failStandings = false;
      final gate = Completer<void>();
      final asked = <String>[];
      Future<void> drain() async {
        for (var i = 0; i < 80; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);
        }
      }

      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MaterialApp(theme: AppTheme.darkTheme, home: const MatchesScreen()),
          );
          await drain();
          expect(
            find.text('Today Home'),
            findsOneWidget,
            reason:
                'requests=$asked, text=${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()}',
          );

          hold = true;
          final refresh = tester
              .state<RefreshIndicatorState>(find.byType(RefreshIndicator).first)
              .show();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          expect(
            find.text('Today Home'),
            findsOneWidget,
            reason: 'existing rows remain visible during a slow refresh',
          );

          await tester.tap(find.text('غداً'));
          await tester.pump();
          expect(
            find.text('Today Home'),
            findsNothing,
            reason: 'today rows must not be labelled as tomorrow',
          );

          hold = false;
          gate.complete();
          await drain();
          await refresh;
          expect(find.text('Today Home'), findsNothing);
          expect(find.text('Tomorrow Home'), findsOneWidget);
          await tester.tap(find.text('الترتيب'));
          await drain();
          expect(
            tester.takeException(),
            isNull,
            reason: 'nonempty standings must have a bounded scrolling viewport',
          );
          expect(find.text('Standing Club'), findsOneWidget);
          failStandings = true;
          final standingsRefresh = tester
              .state<RefreshIndicatorState>(find.byType(RefreshIndicator).first)
              .show();
          await tester.pump();
          await drain();
          await standingsRefresh;
          expect(find.text('Standing Club'), findsOneWidget);
          expect(
            find.textContaining('تعذّر'),
            findsOneWidget,
            reason:
                'cached standings stay visible but must report the failed refresh',
          );
          await tester.tap(find.text('الجدول'));
          await drain();
          expect(
            find.text('Tomorrow Home'),
            findsOneWidget,
            reason: 'returning from standings preserves the selected day',
          );
          expect(find.text('Today Home'), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await drain();
        },
        () => MockClient((request) async {
          asked.add('${request.url.path}?${request.url.query}');
          if (hold) await gate.future;
          final league = request.url.queryParameters['league'];
          final date = request.url.queryParameters['date'];
          if (request.url.path.endsWith('/standings')) {
            if (failStandings) return http.Response('unavailable', 503);
            return http.Response(
              jsonEncode({
                'errors': {},
                'response': [
                  {
                    'league': {
                      'standings': [
                        [
                          {
                            'rank': 1,
                            'team': {
                              'id': 1,
                              'name': 'Standing Club',
                              'logo': '',
                            },
                            'points': 9,
                            'goalsDiff': 5,
                            'group': 'League',
                            'all': {
                              'played': 3,
                              'win': 3,
                              'draw': 0,
                              'lose': 0,
                              'goals': {'for': 6, 'against': 1},
                            },
                          },
                        ],
                      ],
                    },
                  },
                ],
              }),
              200,
            );
          }
          final fixtures = league == '39' && date != null
              ? [
                  {
                    'fixture': {
                      'id': date == today ? 101 : 102,
                      'date': '${date}T19:00:00Z',
                      'status': {'short': 'NS'},
                    },
                    'league': {'id': 39, 'name': 'Premier League'},
                    'teams': {
                      'home': {
                        'id': 1,
                        'name': date == today ? 'Today Home' : 'Tomorrow Home',
                      },
                      'away': {'id': 2, 'name': 'Away'},
                    },
                  },
                ]
              : [];
          return http.Response(
            jsonEncode({'errors': {}, 'response': fixtures}),
            200,
          );
        }),
      );
    },
  );
}
