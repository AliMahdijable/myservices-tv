import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import '../models/channel.dart';
import '../player/playback_preferences.dart';

class XtreamService {
  // v4 builds live URLs with the container format resolved per server rather
  // than hardcoding HLS. The bump discards v3's m3u8-only cache, which made
  // every channel fail its first open on panels that refuse HLS under load.
  static const String _cacheKey = 'xtream_categories_v4';
  static const String _cacheTimeKey = 'xtream_cache_time_v4';

  static const Map<String, String> _headers = {
    'User-Agent': AppConfig.userAgent,
  };

  // Flutter web's http client goes through the browser's own fetch/XHR cache.
  // Xtream panels rarely send Cache-Control: no-store on their API responses
  // (they're built for native apps, not browsers), so a repeat GET to the
  // same URL can be served straight from the browser cache -- silently
  // ignoring forceRefresh, which only controls our own SharedPreferences
  // cache, not whether the network call itself is real. A unique query
  // param per request defeats that regardless of platform.
  static Uri _bust(String url) {
    final uri = Uri.parse(url);
    return uri.replace(
      queryParameters: {
        ...uri.queryParameters,
        '_': DateTime.now().millisecondsSinceEpoch.toString(),
      },
    );
  }

  /// Returns true when the server responds with valid user_info.
  /// Tries standard path first, then /api/ prefix fallback.
  static Future<bool> testConnection(
    String serverUrl,
    String username,
    String password,
  ) async {
    for (final fallback in [false, true]) {
      try {
        final url = AppConfig.buildXtreamApiUrl(
          serverUrl,
          username,
          password,
          fallback: fallback,
        );
        final res = await http
            .get(_bust(url), headers: _headers)
            .timeout(const Duration(seconds: 10));
        if (res.statusCode == 200) {
          final data = _tryDecode(res.bodyBytes);
          if (data is Map && data['user_info'] != null) return true;
        }
      } catch (_) {}
    }
    return false;
  }

  /// Returns the working Xtream API base URL (tries standard then /api/ prefix).
  ///
  /// Also records the formats the panel says it will serve, so live URLs are
  /// built with one the server accepts instead of a hardcoded guess.
  static Future<String?> _resolveApiBase() async {
    for (final base in [
      AppConfig.xtreamApiBase,
      AppConfig.xtreamApiFallbackBase,
    ]) {
      try {
        final res = await http
            .get(_bust(base), headers: _headers)
            .timeout(const Duration(seconds: 8));
        if (res.statusCode == 200) {
          final data = _tryDecode(res.bodyBytes);
          if (data is Map && data['user_info'] != null) {
            await _recordAllowedFormats(data['user_info']);
            return base;
          }
        }
      } catch (_) {}
    }
    return null;
  }

  static Future<void> _recordAllowedFormats(dynamic userInfo) async {
    if (userInfo is! Map) return;
    final raw = userInfo['allowed_output_formats'];
    if (raw is! List) return;
    await PlaybackPreferences.applyAllowedFormats(
      AppConfig.baseUrl,
      raw.map((format) => format.toString().toLowerCase()).toList(),
    );
  }

  /// Fetches live categories + streams in **parallel**, then merges them.
  static Future<List<ChannelCategory>> fetchCategories({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh) {
      final cached = await _getCached();
      if (cached != null) return cached;
    }

    // Resolve which API base URL works for this server
    final apiBase = await _resolveApiBase();
    if (apiBase == null) throw Exception('لا يمكن الوصول إلى Xtream API');

    // ── Parallel HTTP requests ────────────────────────────────────────────
    final responses = await Future.wait([
      http
          .get(_bust('$apiBase&action=get_live_categories'), headers: _headers)
          .timeout(const Duration(seconds: 20)),
      http
          .get(_bust('$apiBase&action=get_live_streams'), headers: _headers)
          .timeout(const Duration(seconds: 30)),
    ]);

    final catRes = responses[0];
    final streamsRes = responses[1];

    if (catRes.statusCode != 200) {
      throw Exception('فشل جلب التصنيفات: ${catRes.statusCode}');
    }
    if (streamsRes.statusCode != 200) {
      throw Exception('فشل جلب القنوات: ${streamsRes.statusCode}');
    }

    // ── Safe JSON decode ──────────────────────────────────────────────────
    final rawCats = _tryDecodeList(catRes.bodyBytes);
    final rawStreams = _tryDecodeList(streamsRes.bodyBytes);

    if (rawCats == null) throw Exception('استجابة التصنيفات غير صالحة');
    if (rawStreams == null) throw Exception('استجابة القنوات غير صالحة');

    // ── Build category map ────────────────────────────────────────────────
    final Map<String, String> catMap = {};
    final List<String> catOrder = [];
    for (final cat in rawCats) {
      final id = cat['category_id']?.toString() ?? '';
      final name = cat['category_name']?.toString() ?? 'أخرى';
      catMap[id] = name;
      if (!catOrder.contains(name)) catOrder.add(name);
    }

    // Resolved once for the whole playlist: whichever container this server
    // has actually served before, defaulting to MPEG-TS.
    final format = await PlaybackPreferences.formatForServer(AppConfig.baseUrl);

    // ── Group streams ─────────────────────────────────────────────────────
    final Map<String, List<Channel>> grouped = {};
    for (final s in rawStreams) {
      // Many Xtream/PHP panels serialize numeric fields as JSON strings.
      final streamId = int.tryParse(s['stream_id']?.toString() ?? '') ?? 0;
      if (streamId == 0) continue;

      final catName = catMap[s['category_id']?.toString() ?? ''] ?? 'أخرى';
      grouped
          .putIfAbsent(catName, () => [])
          .add(
            Channel(
              name: s['name']?.toString() ?? '',
              // Built with the format this server is known to serve. The
              // player still falls back to the other container if a specific
              // channel fails in a way that a format switch could fix.
              url: AppConfig.liveStreamUrl(streamId, ext: format),
              logoUrl: s['stream_icon']?.toString() ?? '',
              group: catName,
              tvgId: s['epg_channel_id']?.toString() ?? '',
              tvgName: s['name']?.toString() ?? '',
              streamId: streamId,
            ),
          );
    }

    // ── Build result in server order ──────────────────────────────────────
    final result = <ChannelCategory>[];
    for (final name in catOrder) {
      if (grouped.containsKey(name)) {
        result.add(
          ChannelCategory(
            name: name,
            displayName: name,
            channels: grouped[name]!,
            sortOrder: result.length,
          ),
        );
      }
    }
    // Append any uncategorised streams
    grouped.forEach((name, channels) {
      if (!catOrder.contains(name)) {
        result.add(
          ChannelCategory(
            name: name,
            displayName: name,
            channels: channels,
            sortOrder: 999,
          ),
        );
      }
    });

    await _cache(result);
    return result;
  }

  // ── JSON helpers ──────────────────────────────────────────────────────────

  static dynamic _tryDecode(List<int> bytes) {
    try {
      return jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      return null;
    }
  }

  static List<dynamic>? _tryDecodeList(List<int> bytes) {
    final v = _tryDecode(bytes);
    return v is List ? v : null;
  }

  // ── Cache ─────────────────────────────────────────────────────────────────

  static Future<void> _cache(List<ChannelCategory> categories) async {
    final prefs = await SharedPreferences.getInstance();
    final data = categories
        .map(
          (cat) => {
            'name': cat.name,
            'displayName': cat.displayName,
            'sortOrder': cat.sortOrder,
            'channels': cat.channels.map((c) => c.toJson()).toList(),
          },
        )
        .toList();
    await prefs.setString(_cacheKey, jsonEncode(data));
    await prefs.setInt(_cacheTimeKey, DateTime.now().millisecondsSinceEpoch);
  }

  static Future<List<ChannelCategory>?> _getCached() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_cacheKey);
    if (json == null) return null;

    final cacheTime = prefs.getInt(_cacheTimeKey);
    if (cacheTime != null) {
      final age = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(cacheTime),
      );
      if (age > AppConfig.cacheDuration) return null;
    }

    try {
      final List<dynamic> data = jsonDecode(json);
      return data
          .map(
            (cat) => ChannelCategory(
              name: cat['name'],
              displayName: cat['displayName'],
              channels: (cat['channels'] as List)
                  .map((c) => Channel.fromJson(c as Map<String, dynamic>))
                  .toList(),
              sortOrder: cat['sortOrder'],
            ),
          )
          .toList();
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey);
    await prefs.remove(_cacheTimeKey);
    await prefs.remove('xtream_categories_v2');
    await prefs.remove('xtream_cache_time_v2');
    await prefs.remove('xtream_categories_v3');
    await prefs.remove('xtream_cache_time_v3');
  }
}
