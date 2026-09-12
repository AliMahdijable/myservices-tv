import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/competition.dart';
import '../models/fixture.dart';
import '../models/standing.dart';

/// What a fixtures fetch produced, and whether every competition answered.
///
/// An empty list used to mean both "no matches today" and "every request
/// failed", and the screen could only render the first — so a rate-limited or
/// offline moment was shown to the user as a quiet, confident "لا توجد
/// مباريات في هذا اليوم".
class FixturesResult {
  final List<Fixture> fixtures;

  /// Competitions whose request did not answer. Empty on a clean fetch.
  final List<int> failedLeagueIds;

  const FixturesResult(this.fixtures, {this.failedLeagueIds = const []});

  bool get hasFailures => failedLeagueIds.isNotEmpty;

  /// True when nothing was returned and nothing failed — a genuinely empty day.
  bool get isGenuinelyEmpty => fixtures.isEmpty && failedLeagueIds.isEmpty;
}

/// One league's answer, kept separate from the merge so a failure survives it.
class _LeagueFetch {
  final List<Fixture> fixtures;
  final bool answered;
  const _LeagueFetch(this.fixtures, {required this.answered});
}

class _CacheEntry<T> {
  final T value;
  final DateTime storedAt;
  const _CacheEntry(this.value, this.storedAt);

  bool isFresh(Duration ttl) => DateTime.now().difference(storedAt) < ttl;
}

/// Wraps API-Football v3 (schedule + standings only — no goal-by-goal feed).
///
/// Results are cached in memory per call signature so switching between the
/// date chips or competition tabs the user already visited this session
/// doesn't re-spend the daily request quota.
class FootballApiService {
  static const _fixturesTtl = Duration(seconds: 60);
  static const _standingsTtl = Duration(minutes: 10);

  static final Map<String, _CacheEntry<List<Fixture>>> _fixturesCache = {};
  static final Map<String, _CacheEntry<List<List<Standing>>>> _standingsCache =
      {};

  static Map<String, String> get _headers => {
    'x-apisports-key': AppConfig.footballApiKey,
  };

  /// Fixtures for [date] across every competition in [Competition.all],
  /// merged and sorted by kickoff time. Each league is fetched in parallel;
  /// one failing league doesn't take the others down with it.
  static Future<FixturesResult> fixturesForDate(
    DateTime date, {
    bool forceRefresh = false,
  }) async {
    final ids = Competition.all.map((c) => c.id).toList();
    final results = await Future.wait(
      ids.map((id) => _fetchLeague(id, date, forceRefresh: forceRefresh)),
    );

    final merged = <Fixture>[];
    final failed = <int>[];
    for (var i = 0; i < results.length; i++) {
      merged.addAll(results[i].fixtures);
      if (!results[i].answered) failed.add(ids[i]);
    }
    merged.sort((a, b) => a.kickoff.compareTo(b.kickoff));
    return FixturesResult(merged, failedLeagueIds: failed);
  }

  static Future<FixturesResult> fixturesForLeague(
    int leagueId,
    DateTime date, {
    bool forceRefresh = false,
  }) async {
    final fetch = await _fetchLeague(
      leagueId,
      date,
      forceRefresh: forceRefresh,
    );
    return FixturesResult(
      fetch.fixtures,
      failedLeagueIds: fetch.answered ? const [] : [leagueId],
    );
  }

  static Future<_LeagueFetch> _fetchLeague(
    int leagueId,
    DateTime date, {
    bool forceRefresh = false,
  }) async {
    final dateKey =
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    final cacheKey = '$leagueId|$dateKey';

    if (!forceRefresh) {
      final cached = _fixturesCache[cacheKey];
      if (cached != null && cached.isFresh(_fixturesTtl)) {
        return _LeagueFetch(cached.value, answered: true);
      }
    }

    final season = Competition.seasonFor(date);
    final uri = Uri.parse('${AppConfig.footballApiBase}/fixtures').replace(
      queryParameters: {
        'league': '$leagueId',
        'season': '$season',
        'date': dateKey,
      },
    );

    try {
      final res = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        return _staleOrNothing(cacheKey);
      }

      final body = jsonDecode(utf8.decode(res.bodyBytes));

      // API-Football answers a dead key, a lapsed subscription and an
      // exhausted quota with HTTP 200, an empty response and a populated
      // `errors`. Read as a bare 200 that is "no matches today" for every
      // league, every day, until someone thinks to check the dashboard.
      if (_carriesError(body)) {
        return _staleOrNothing(cacheKey);
      }

      final rawResponse = body is Map ? body['response'] : null;
      if (rawResponse is! List) return _staleOrNothing(cacheKey);

      final fixtures = rawResponse
          .whereType<Map<String, dynamic>>()
          .map(Fixture.fromJson)
          .toList();
      _fixturesCache[cacheKey] = _CacheEntry(fixtures, DateTime.now());
      return _LeagueFetch(fixtures, answered: true);
    } catch (_) {
      // A stale cached value beats a blank section on a transient failure, but
      // it is still not an answer — the caller has to be able to say so.
      return _staleOrNothing(cacheKey);
    }
  }

  /// A failed fetch: hand back whatever was cached, but never claim it as an
  /// answer, so the screen can tell the user something went wrong.
  static _LeagueFetch _staleOrNothing(String cacheKey) => _LeagueFetch(
    _fixturesCache[cacheKey]?.value ?? const [],
    answered: false,
  );

  /// True when a 200 body carries an API-level error rather than data.
  static bool _carriesError(dynamic body) {
    if (body is! Map) return false;
    final errors = body['errors'];
    if (errors is Map) return errors.isNotEmpty;
    if (errors is List) return errors.isNotEmpty;
    return false;
  }

  /// The league table for [leagueId], as one list of rows per group (most
  /// competitions have exactly one group; the Champions League group stage
  /// has several).
  static Future<List<List<Standing>>> standings(
    int leagueId, {
    int? season,
    bool forceRefresh = false,
  }) async {
    final resolvedSeason = season ?? Competition.seasonFor(DateTime.now());
    final cacheKey = '$leagueId|$resolvedSeason';

    if (!forceRefresh) {
      final cached = _standingsCache[cacheKey];
      if (cached != null && cached.isFresh(_standingsTtl)) return cached.value;
    }

    final uri = Uri.parse('${AppConfig.footballApiBase}/standings').replace(
      queryParameters: {'league': '$leagueId', 'season': '$resolvedSeason'},
    );

    try {
      final res = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        return _standingsCache[cacheKey]?.value ?? const [];
      }

      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (_carriesError(body)) {
        return _standingsCache[cacheKey]?.value ?? const [];
      }

      final rawResponse = body is Map ? body['response'] : null;
      if (rawResponse is! List || rawResponse.isEmpty) {
        return _standingsCache[cacheKey]?.value ?? const [];
      }

      final leagueJson =
          (rawResponse.first as Map<String, dynamic>)['league']
              as Map<String, dynamic>?;
      final rawGroups = leagueJson?['standings'];
      if (rawGroups is! List) return const [];

      final groups = rawGroups
          .whereType<List>()
          .map(
            (group) => group
                .whereType<Map<String, dynamic>>()
                .map(Standing.fromJson)
                .toList(),
          )
          .where((group) => group.isNotEmpty)
          .toList();

      _standingsCache[cacheKey] = _CacheEntry(groups, DateTime.now());
      return groups;
    } catch (_) {
      return _standingsCache[cacheKey]?.value ?? const [];
    }
  }
}
