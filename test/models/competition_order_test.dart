import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/models/competition.dart';

/// Competition.all is the single source of the running order: the filter pills
/// on both tabs, the standings tab's opening selection, and the league sections
/// down the schedule all read it. These pin the order and, just as importantly,
/// pin what the order is *not* allowed to touch.
void main() {
  const championsLeague = 2;
  const saudiLeague = 307;

  group('running order', () {
    test('the Champions League comes first', () {
      expect(Competition.all.first.id, championsLeague);
      expect(Competition.displayRank(championsLeague), 0);
    });

    test('Arab competitions come last', () {
      expect(Competition.all.last.id, saudiLeague);
      expect(
        Competition.displayRank(saudiLeague),
        Competition.all.length - 1,
        reason: 'the Saudi league used to be first, which also made it the '
            'table the standings tab opened on',
      );
    });

    test('every European competition outranks every Arab one', () {
      const arab = {saudiLeague};
      final european = Competition.all
          .where((c) => !arab.contains(c.id))
          .map((c) => c.id);
      for (final id in european) {
        expect(
          Competition.displayRank(id),
          lessThan(Competition.displayRank(saudiLeague)),
          reason: '${Competition.find(id)?.shortName} must precede السعودي',
        );
      }
    });

    test('the European competitions keep the order they already had', () {
      // Unchanged from before the reorder — only the Saudi league moved.
      expect(
        Competition.all.map((c) => c.id).where((id) => id != saudiLeague),
        [2, 3, 39, 140, 135, 78, 61],
      );
    });

    test('the standings tab opens on the Champions League', () {
      // The tab selects Competition.all.first on init.
      expect(Competition.all.first.shortName, 'أبطال أوروبا');
    });
  });

  group('displayRank', () {
    test('ranks each listed competition by its position', () {
      for (var i = 0; i < Competition.all.length; i++) {
        expect(Competition.displayRank(Competition.all[i].id), i);
      }
    });

    test('an unlisted competition sorts after every listed one', () {
      expect(
        Competition.displayRank(999999),
        greaterThanOrEqualTo(Competition.all.length),
        reason: 'an unknown league must not jump ahead of the Champions League',
      );
    });
  });

  group('what the running order must not change', () {
    test('no competition is lost or duplicated', () {
      final ids = Competition.all.map((c) => c.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'duplicate id');
      expect(ids, containsAll([2, 3, 39, 140, 135, 78, 61, 307]));
      expect(ids, hasLength(8));
    });

    test('every competition still resolves to its Arabic name', () {
      for (final c in Competition.all) {
        expect(Competition.nameFor(c.id, 'fallback'), c.name);
        expect(c.name, isNotEmpty);
        expect(c.shortName, isNotEmpty);
      }
    });

    test('seasonFor is untouched by the reorder', () {
      // A February fixture still belongs to the season labelled by the
      // previous calendar year; July onwards starts the new one.
      expect(Competition.seasonFor(DateTime(2027, 2, 14)), 2026);
      expect(Competition.seasonFor(DateTime(2026, 7, 1)), 2026);
      expect(Competition.seasonFor(DateTime(2026, 6, 30)), 2025);
    });
  });
}
