import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/models/fixture.dart';
import 'package:myservices_tv/services/football_api_service.dart';

/// An empty list used to mean two different things — "no matches today" and
/// "every request failed" — and the screen could only render the first. A
/// rate-limited moment was therefore shown to the user as a confident
/// "لا توجد مباريات في هذا اليوم".
void main() {
  Fixture fixture(int id) => Fixture(
    id: id,
    kickoff: DateTime.utc(2026, 9, 13, 19, 45),
    statusShort: 'NS',
    leagueId: 140,
    leagueName: 'La Liga',
    leagueLogoUrl: '',
    round: 'Regular Season - 5',
    home: const FixtureTeam(id: 1, name: 'Barcelona', logoUrl: ''),
    away: const FixtureTeam(id: 2, name: 'Malaga', logoUrl: ''),
  );

  group('FixturesResult', () {
    test('a quiet day is not a failure', () {
      const result = FixturesResult([]);
      expect(result.hasFailures, isFalse);
      expect(
        result.isGenuinelyEmpty,
        isTrue,
        reason: 'nothing returned and nothing failed is a real empty day',
      );
    });

    test('everything failing is not a quiet day', () {
      const result = FixturesResult([], failedLeagueIds: [39, 140]);
      expect(result.hasFailures, isTrue);
      expect(
        result.isGenuinelyEmpty,
        isFalse,
        reason: 'this must never render as "لا توجد مباريات"',
      );
    });

    test('a partial answer still reports what is missing', () {
      final result = FixturesResult([fixture(1)], failedLeagueIds: const [39]);
      expect(result.fixtures, hasLength(1));
      expect(
        result.hasFailures,
        isTrue,
        reason: 'showing only the leagues that answered, silently, tells the '
            'user their league has no match when nobody asked',
      );
      expect(result.failedLeagueIds, [39]);
    });

    test('a clean fetch carries no failures', () {
      final result = FixturesResult([fixture(1), fixture(2)]);
      expect(result.hasFailures, isFalse);
      expect(result.isGenuinelyEmpty, isFalse);
    });
  });
}
