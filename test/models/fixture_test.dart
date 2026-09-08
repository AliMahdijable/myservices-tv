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
  _groupSplitting();
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

/// The server flattens a competition played in regional groups into one list
/// carrying two of every position. Painted as one ladder that gave the Asian
/// Champions League two leaders, two runners-up and so on down.
void _groupSplitting() {
  group('grouped competitions', () {
    Map<String, dynamic> row(int pos, String name) => {
      'pos': pos,
      'name': name,
      'logo': '',
      'played': 6,
      'won': 3,
      'draw': 1,
      'lost': 2,
      'gf': 8,
      'ga': 7,
      'points': 10,
    };

    test('splits two regions into two ladders, in file order', () {
      final table = LeagueTable.fromJson({
        'league': 'دوري أبطال آسيا',
        'rank': 8,
        // As the file arrives: ordered by position, west then east for each.
        'rows': [
          row(1, 'العين'),
          row(1, 'بوريرام يونايتد'),
          row(2, 'استقلال'),
          row(2, 'كاشيما أنتليرز'),
        ],
      })!;

      expect(table.isGrouped, isTrue);
      expect(table.groups.length, 2);
      expect(table.groups[0].map((r) => r.team), ['العين', 'استقلال']);
      expect(table.groups[1].map((r) => r.team), [
        'بوريرام يونايتد',
        'كاشيما أنتليرز',
      ]);
      // No position may repeat inside one ladder.
      for (final g in table.groups) {
        expect(g.map((r) => r.position).toSet().length, g.length);
      }
    });

    test('an ordinary league stays a single ladder', () {
      final table = LeagueTable.fromJson({
        'league': 'الدوري الإنجليزي',
        'rank': 3,
        'rows': [row(2, 'أرسنال'), row(1, 'ليفربول'), row(3, 'تشيلسي')],
      })!;

      expect(table.isGrouped, isFalse);
      expect(table.groups.single.map((r) => r.team), [
        'ليفربول',
        'أرسنال',
        'تشيلسي',
      ]);
      expect(table.rows.length, 3);
    });
  });
}
