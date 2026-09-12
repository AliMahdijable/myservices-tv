import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/competition.dart';
import '../models/fixture.dart';
import '../models/standing.dart';

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
  static final Map<String, _CacheEntry<List<List<Standing>>>>
  _standingsCache = {};

  static Map<String, String> get _headers => {
    'x-apisports-key': AppConfig.footballApiKey,
  };

  /// Fixtures for [date] across every competition in [Competition.all],
  /// merged and sorted by kickoff time. Each league is fetched in parallel;
  /// one failing league doesn't take the others down with it.
  static Future<List<Fixture>> fixturesForDate(
    DateTime date, {
    bool forceRefresh = false,
  }) async {
    final results = await Future.wait(
      Competition.all.map(
        (c) => fixturesForLeague(c.id, date, forceRefresh: forceRefresh),
      ),
    );
    final merged = results.expand((f) => f).toList()
      ..sort((a, b) => a.kickoff.compareTo(b.kickoff));
    return merged;
  }

  static Future<List<Fixture>> fixturesForLeague(
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
      if (cached != null && cached.isFresh(_fixturesTtl)) return cached.value;
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
      if (res.statusCode != 200) return const [];

      final body = jsonDecode(utf8.decode(res.bodyBytes));
      final rawResponse = body is Map ? body['response'] : null;
      if (rawResponse is! List) return const [];

      final fixtures = rawResponse
          .whereType<Map<String, dynamic>>()
          .map(Fixture.fromJson)
          .toList();
      _fixturesCache[cacheKey] = _CacheEntry(fixtures, DateTime.now());
      return fixtures;
    } catch (_) {
      // A stale cached value beats a blank section on a transient failure.
      return _fixturesCache[cacheKey]?.value ?? const [];
    }
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
