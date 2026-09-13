import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myservices_tv/services/football_api_service.dart';

/// Loading a day of fixtures asks a provider that allows five requests a
/// second. Eight leagues fired at once is eight in the same millisecond, and
/// the refusals came back as "تعذّر تحميل الدوري" on a screen the user had
/// only just re-entered.
void main() {
  _standingsCases();
  final emptyDay = jsonEncode({'errors': <String, String>{}, 'response': []});

  String dayWith(int fixtureId, int leagueId) => jsonEncode({
    'errors': <String, String>{},
    'response': [
      {
        'fixture': {
          'id': fixtureId,
          'date': '2026-09-20T19:00:00+00:00',
          'status': {'short': 'NS', 'elapsed': null},
        },
        'league': {
          'id': leagueId,
          'name': 'L$leagueId',
          'logo': '',
          'round': 'Regular Season - 5',
        },
        'teams': {
          'home': {'id': 1, 'name': 'Home', 'logo': ''},
          'away': {'id': 2, 'name': 'Away', 'logo': ''},
        },
        'goals': {'home': null, 'away': null},
      },
    ],
  });

  setUp(FootballApiService.debugReset);
  tearDown(FootballApiService.debugReset);

  final day = DateTime(2026, 9, 20);

  group('overlapping loads', () {
    test('two callers asking at once make one request', () async {
      var requests = 0;
      await http.runWithClient(
        () => Future.wait([
          FootballApiService.fixturesForLeague(39, day, forceRefresh: true),
          FootballApiService.fixturesForLeague(39, day, forceRefresh: true),
        ]),
        () => MockClient((_) async {
          requests++;
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return http.Response(emptyDay, 200);
        }),
      );
      expect(requests, 1);
    });

    test('a second ask after the first finished does hit the network', () async {
      var requests = 0;
      await http.runWithClient(() async {
        await FootballApiService.fixturesForLeague(39, day, forceRefresh: true);
        await FootballApiService.fixturesForLeague(39, day, forceRefresh: true);
      }, () => MockClient((_) async {
        requests++;
        return http.Response(emptyDay, 200);
      }));
      expect(requests, 2, reason: 'dedup must not become a permanent cache');
    });
  });

  group('a blip is not an error', () {
    test('a 503 is retried and never reaches the screen', () async {
      var requests = 0;
      final result = await http.runWithClient(
        () => FootballApiService.fixturesForLeague(140, day, forceRefresh: true),
        () => MockClient((_) async {
          requests++;
          return requests == 1
              ? http.Response('unavailable', 503)
              : http.Response(emptyDay, 200);
        }),
      );
      expect(requests, 2);
      expect(result.hasFailures, isFalse);
    });

    test('a 429 is retried', () async {
      var requests = 0;
      final result = await http.runWithClient(
        () => FootballApiService.fixturesForLeague(140, day, forceRefresh: true),
        () => MockClient((_) async {
          requests++;
          return requests == 1
              ? http.Response('slow down', 429)
              : http.Response(emptyDay, 200);
        }),
      );
      expect(requests, 2);
      expect(result.hasFailures, isFalse);
    });

    test('the per-second limit inside a 200 body is retried', () async {
      var requests = 0;
      final limited = jsonEncode({
        'errors': {'rateLimit': 'Too many requests per second'},
        'response': <dynamic>[],
      });
      final result = await http.runWithClient(
        () => FootballApiService.fixturesForLeague(140, day, forceRefresh: true),
        () => MockClient((_) async {
          requests++;
          return http.Response(requests == 1 ? limited : emptyDay, 200);
        }),
      );
      expect(
        requests,
        2,
        reason: 'the provider reports this as HTTP 200 with an errors object',
      );
      expect(result.hasFailures, isFalse);
    });

    test('a dead key is not retried', () async {
      var requests = 0;
      final dead = jsonEncode({
        'errors': {'token': 'invalid api key'},
        'response': <dynamic>[],
      });
      final result = await http.runWithClient(
        () => FootballApiService.fixturesForLeague(140, day, forceRefresh: true),
        () => MockClient((_) async {
          requests++;
          return http.Response(dead, 200);
        }),
      );
      expect(
        requests,
        1,
        reason: 'asking again spends a request to be told the same thing',
      );
      expect(result.hasFailures, isTrue);
    });

    test('an exhausted daily quota is not retried', () async {
      var requests = 0;
      final quota = jsonEncode({
        'errors': {'requests': 'daily limit reached'},
        'response': <dynamic>[],
      });
      await http.runWithClient(
        () => FootballApiService.fixturesForLeague(140, day, forceRefresh: true),
        () => MockClient((_) async {
          requests++;
          return http.Response(quota, 200);
        }),
      );
      expect(requests, 1);
    });

    test('two failures in a row do surface', () async {
      var requests = 0;
      final result = await http.runWithClient(
        () => FootballApiService.fixturesForLeague(140, day, forceRefresh: true),
        () => MockClient((_) async {
          requests++;
          return http.Response('unavailable', 503);
        }),
      );
      expect(requests, 2, reason: 'one retry, not an infinite one');
      expect(
        result.hasFailures,
        isTrue,
        reason: 'a real outage must not be hidden',
      );
    });
  });

  group('pacing a whole day', () {
    test('eight leagues never exceed five starts in any second', () async {
      final starts = <DateTime>[];
      await http.runWithClient(
        () => FootballApiService.fixturesForDate(day, forceRefresh: true),
        () => MockClient((_) async {
          starts.add(DateTime.now());
          return http.Response(emptyDay, 200);
        }),
      );

      expect(starts.length, 8);
      for (var i = 0; i < starts.length; i++) {
        final windowEnd = starts[i].add(const Duration(seconds: 1));
        final inWindow = starts.where(
          (s) => !s.isBefore(starts[i]) && s.isBefore(windowEnd),
        );
        expect(
          inWindow.length,
          lessThanOrEqualTo(5),
          reason: 'the provider allows five a second; this fired '
              '${inWindow.length}',
        );
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('retrying only what failed', () {
    test('the leagues that answered are not asked again', () async {
      final asked = <String>[];
      final result = await http.runWithClient(() async {
        final first = await FootballApiService.fixturesForDate(
          day,
          forceRefresh: true,
        );
        return FootballApiService.retryFailed(day, first);
      }, () => MockClient((request) async {
        final league = request.url.queryParameters['league']!;
        asked.add(league);
        // One league is down throughout; the rest answer first time.
        if (league == '39') return http.Response('unavailable', 503);
        return http.Response(dayWith(int.parse(league), int.parse(league)), 200);
      }));

      // Seven answered once; the failing one was tried twice by the retry
      // inside the first load, then twice more by retryFailed.
      expect(asked.where((l) => l != '39').toSet().length, 7);
      expect(
        asked.where((l) => l != '39').length,
        7,
        reason: 'a league that answered must not be asked again',
      );
      expect(result.hasFailures, isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a recovered league replaces its stale rows rather than doubling them',
        () async {
      var leagueThirtyNineCalls = 0;
      final result = await http.runWithClient(() async {
        // Seed a real cached value for league 39, so the failure that follows
        // genuinely serves stale data rather than nothing. Without this the
        // test proves only that an empty list plus a result is that result.
        await FootballApiService.fixturesForLeague(39, day, forceRefresh: true);
        expect(leagueThirtyNineCalls, 1, reason: 'the seed should have loaded');

        final first = await FootballApiService.fixturesForDate(
          day,
          forceRefresh: true,
        );
        // The stale row is being served while the league is down.
        expect(first.failedLeagueIds, contains(39));
        expect(first.fixtures.where((f) => f.id == 7777), hasLength(1));

        return FootballApiService.retryFailed(day, first);
      }, () => MockClient((request) async {
        final league = request.url.queryParameters['league']!;
        if (league != '39') return http.Response(emptyDay, 200);

        leagueThirtyNineCalls++;
        if (leagueThirtyNineCalls == 1) {
          // The seed: an older fixture that will later be superseded.
          return http.Response(dayWith(7777, 39), 200);
        }
        // Down during the day's load (two attempts), then back with a
        // different fixture when retried.
        return leagueThirtyNineCalls <= 3
            ? http.Response('unavailable', 503)
            : http.Response(dayWith(9001, 39), 200);
      }));

      final ids = result.fixtures.map((f) => f.id).toList();
      expect(ids, contains(9001));
      expect(
        ids,
        isNot(contains(7777)),
        reason: 'the stale row must be replaced, not kept beside its successor',
      );
      expect(ids.where((id) => id == 9001), hasLength(1));
      expect(result.hasFailures, isFalse);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}

/// A table that does not exist yet and a table that failed to load look the
/// same on screen unless the service keeps them apart.
void _standingsCases() {
  final empty = jsonEncode({'errors': <String, String>{}, 'response': []});

  group('standings', () {
    setUp(FootballApiService.debugReset);
    tearDown(FootballApiService.debugReset);

    test('an empty response with no errors is an answer', () async {
      final result = await http.runWithClient(
        () => FootballApiService.standings(2, forceRefresh: true),
        () => MockClient((_) async => http.Response(empty, 200)),
      );
      expect(result.isEmpty, isTrue);
      expect(
        result.answered,
        isTrue,
        reason: 'a competition whose table has not started is not a failure',
      );
    });

    test('a transport failure is not an answer', () async {
      final result = await http.runWithClient(
        () => FootballApiService.standings(2, forceRefresh: true),
        () => MockClient((_) async => http.Response('down', 503)),
      );
      expect(result.answered, isFalse);
    });

    test('a blip is retried before it becomes a failure', () async {
      var calls = 0;
      final result = await http.runWithClient(
        () => FootballApiService.standings(2, forceRefresh: true),
        () => MockClient((_) async {
          calls++;
          return calls == 1
              ? http.Response('down', 503)
              : http.Response(empty, 200);
        }),
      );
      expect(calls, 2);
      expect(result.answered, isTrue);
    });

    test('a failed refresh still hands back the cached table', () async {
      final table = jsonEncode({
        'errors': <String, String>{},
        'response': [
          {
            'league': {
              'standings': [
                [
                  {
                    'rank': 1,
                    'team': {'id': 1, 'name': 'Alpha', 'logo': ''},
                    'points': 10,
                    'goalsDiff': 5,
                    'all': {
                      'played': 5,
                      'win': 3,
                      'draw': 1,
                      'lose': 1,
                      'goals': {'for': 9, 'against': 4},
                    },
                  },
                ],
              ],
            },
          },
        ],
      });

      var calls = 0;
      final result = await http.runWithClient(() async {
        await FootballApiService.standings(2, forceRefresh: true);
        return FootballApiService.standings(2, forceRefresh: true);
      }, () => MockClient((_) async {
        calls++;
        return calls == 1
            ? http.Response(table, 200)
            : http.Response('down', 503);
      }));

      expect(
        result.groups,
        isNotEmpty,
        reason: 'the table already on screen should stay there',
      );
      expect(
        result.answered,
        isFalse,
        reason: 'but the refresh failed, and the screen has to be able to say so',
      );
    });
  });
}
