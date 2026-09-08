import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/models/fixture.dart';

/// A trimmed sample of exactly what the home server writes, so a change to
/// that file's shape fails here rather than on a TV.
const _sample = '''
{
  "updated": "2026-09-08T16:00:00.000Z",
  "count": 2,
  "matches": [
    {"id":"s365:1","ts":"2026-09-08T21:00:00+03:00","league":"دوري أبطال أوروبا","rank":1,
     "state":"pre","home":{"name":"بورتو","logo":"http://x/1","score":null},
     "away":{"name":"مانشستر سيتي","logo":"http://x/2","score":null}},
    {"id":"s365:2","ts":"2026-09-08T18:45:00+03:00","league":"الدوري العراقي الممتاز","rank":11,
     "state":"post","home":{"name":"دهوك","logo":"","score":"1"},
     "away":{"name":"غاز الشمال","logo":"","score":"2"}}
  ],
  "standings": [
    {"league":"الدوري الإسباني","rank":2,"rows":[
      {"pos":2,"name":"ريال مدريد","logo":"","played":4,"won":3,"draw":0,"lost":1,"gf":9,"ga":4,"points":9},
      {"pos":1,"name":"برشلونة","logo":"","played":4,"won":4,"draw":0,"lost":0,"gf":12,"ga":2,"points":12}
    ]}
  ]
}
''';

void main() {
  group('FixturesData', () {
    late FixturesData data;

    setUp(() {
      data = FixturesData.fromJson(
        jsonDecode(_sample) as Map<String, dynamic>,
      );
    });

    test('parses matches and orders them by kickoff', () {
      expect(data.matches, hasLength(2));
      // The Iraqi match kicks off earlier, so it sorts first despite its
      // lower competition priority.
      expect(data.matches.first.home.name, 'دهوك');
    });

    test('maps the state strings the server writes', () {
      expect(data.matches.first.state, MatchState.finished);
      expect(data.matches.last.state, MatchState.upcoming);
      expect(MatchState.live.label, 'مباشر الآن');
    });

    test('an upcoming match carries no score', () {
      final upcoming = data.matches.last;
      expect(upcoming.home.score, isNull);
      expect(upcoming.state.hasScore, isFalse);
    });

    test('standings are sorted by position, not file order', () {
      final table = data.tables.single;
      expect(table.rows.map((r) => r.team), ['برشلونة', 'ريال مدريد']);
    });

    test('goal difference is derived, not stored', () {
      expect(data.tables.single.rows.first.goalDifference, 10);
    });

    test('kickoff keeps the instant across the timezone conversion', () {
      // The server stamps +03:00; toLocal() must not shift the moment itself.
      final match = data.matches.last;
      expect(
        match.kickoff.toUtc(),
        DateTime.utc(2026, 9, 8, 18, 0),
      );
    });
  });

  group('malformed input', () {
    test('a match with no timestamp is dropped, not fatal', () {
      final data = FixturesData.fromJson({
        'matches': [
          {'id': 'x', 'home': {'name': 'a'}, 'away': {'name': 'b'}},
        ],
      });
      expect(data.matches, isEmpty);
    });

    test('a match missing a side is dropped', () {
      final data = FixturesData.fromJson({
        'matches': [
          {'id': 'x', 'ts': '2026-09-08T21:00:00+03:00', 'home': {'name': 'a'}},
        ],
      });
      expect(data.matches, isEmpty);
    });

    test('an empty standings group is dropped', () {
      final data = FixturesData.fromJson({
        'standings': [
          {'league': 'x', 'rows': []},
        ],
      });
      expect(data.tables, isEmpty);
    });

    test('a wholly empty payload reports itself empty', () {
      expect(FixturesData.fromJson(const {}).isEmpty, isTrue);
    });
  });
}
