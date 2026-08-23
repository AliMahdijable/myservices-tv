import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import '../models/channel.dart';
import '../models/fixture.dart';

/// Thrown when [AppConfig.fixturesApiKey] is empty. Callers should show a
/// "not configured" state, not an error.
class FixturesNotConfiguredException implements Exception {
  const FixturesNotConfiguredException();
}

class FixturesService {
  static const String _baseUrl = 'https://v3.football.api-sports.io/fixtures';
  static const String _cacheKey = 'fixtures_cache_v1';
  static const String _cacheTimeKey = 'fixtures_cache_time_v1';
  // The free API-Football tier is 100 requests/day — cache generously
  // rather than poll for live updates.
  static const Duration _cacheDuration = Duration(hours: 2);

  /// Fixtures for today, local time. Throws [FixturesNotConfiguredException]
  /// if no API key is set.
  static Future<List<Fixture>> fetchTodayFixtures({
    bool forceRefresh = false,
  }) async {
    if (AppConfig.fixturesApiKey.isEmpty) {
      throw const FixturesNotConfiguredException();
    }

    if (!forceRefresh) {
      final cached = await _getCached();
      if (cached != null) return cached;
    }

    final today = DateTime.now();
    final dateParam =
        '${today.year.toString().padLeft(4, '0')}-'
        '${today.month.toString().padLeft(2, '0')}-'
        '${today.day.toString().padLeft(2, '0')}';

    final uri = Uri.parse('$_baseUrl?date=$dateParam');
    final response = await http
        .get(uri, headers: {'x-apisports-key': AppConfig.fixturesApiKey})
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw Exception('فشل جلب جدول المباريات: ${response.statusCode}');
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
    if (decoded is! Map || decoded['response'] is! List) {
      throw Exception('استجابة جدول المباريات غير صالحة');
    }

    final fixtures = (decoded['response'] as List)
        .whereType<Map<String, dynamic>>()
        .map(Fixture.fromJson)
        .toList()
      ..sort((a, b) => a.kickoff.compareTo(b.kickoff));

    await _cache(fixtures);
    return fixtures;
  }

  // ── Best-effort match → channel suggestion ──────────────────────────────
  // No fixtures API knows this app's own IPTV channel lineup. This maps a
  // handful of well-known competitions to keywords commonly found in Arab
  // sports-channel names, then looks for a real channel matching those
  // keywords among the categories already loaded in the app. It's a
  // suggestion, not a guarantee -- always show the fixture even with none.
  static const Map<String, List<String>> _competitionKeywordHints = {
    'champions league': ['bein', 'بين'],
    'europa league': ['bein', 'بين'],
    'premier league': ['bein', 'بين'],
    'la liga': ['bein', 'بين'],
    'serie a': ['bein', 'بين'],
    'ligue 1': ['bein', 'بين'],
    'bundesliga': ['bein', 'بين'],
    'saudi': ['ssc', 'ألوان', 'alwan', 'الوان'],
    'world cup': ['bein', 'بين'],
  };

  static Channel? suggestChannel(
    Fixture fixture,
    List<ChannelCategory> categories,
  ) {
    final leagueLower = fixture.league.toLowerCase();
    List<String>? keywords;
    for (final entry in _competitionKeywordHints.entries) {
      if (leagueLower.contains(entry.key)) {
        keywords = entry.value;
        break;
      }
    }
    if (keywords == null) return null;

    for (final category in categories) {
      final nameLower = category.name.toLowerCase();
      final displayLower = category.displayName.toLowerCase();
      final matches = keywords.any(
        (keyword) =>
            nameLower.contains(keyword) || displayLower.contains(keyword),
      );
      if (matches && category.channels.isNotEmpty) {
        return category.channels.first;
      }
    }
    return null;
  }

  // ── Cache ────────────────────────────────────────────────────────────────

  static Future<void> _cache(List<Fixture> fixtures) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _cacheKey,
      jsonEncode(fixtures.map((f) => f.toJson()).toList()),
    );
    await prefs.setInt(_cacheTimeKey, DateTime.now().millisecondsSinceEpoch);
  }

  static Future<List<Fixture>?> _getCached() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_cacheKey);
    if (json == null) return null;

    final cacheTime = prefs.getInt(_cacheTimeKey);
    if (cacheTime != null) {
      final age = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(cacheTime),
      );
      if (age > _cacheDuration) return null;
    }

    try {
      final List<dynamic> data = jsonDecode(json);
      return data
          .map((e) => Fixture.fromCacheJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return null;
    }
  }
}
