import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import '../models/channel.dart';

class M3uService {
  static const String _cacheKey     = 'cached_channels';
  static const String _cacheTimeKey = 'cached_channels_time';

  // Pre-compiled regex — created once, reused for every channel line.
  static final RegExp _logoRegex    = RegExp(r'tvg-logo="([^"]*)"');
  static final RegExp _groupRegex   = RegExp(r'group-title="([^"]*)"');
  static final RegExp _tvgIdRegex   = RegExp(r'tvg-id="([^"]*)"');
  static final RegExp _tvgNameRegex = RegExp(r'tvg-name="([^"]*)"');

  static Future<List<Channel>> fetchChannels({bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final cached = await _getCachedChannels();
      if (cached != null && cached.isNotEmpty) return cached;
    }

    // Try standard path first (/get.php), then server-specific path (/api/get.php)
    final urls = [AppConfig.playlistUrl, AppConfig.playlistFallbackUrl];

    for (final url in urls) {
      try {
        final response = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 30));

        if (response.statusCode == 200) {
          final body = utf8.decode(response.bodyBytes, allowMalformed: true);
          if (body.contains('#EXTM3U')) {
            final channels = _parseM3u(body);
            if (channels.isNotEmpty) {
              await _cacheChannels(channels);
              return channels;
            }
          }
        }
      } catch (_) {}
    }

    // All URLs failed — try cache as last resort
    final cached = await _getCachedChannels();
    if (cached != null && cached.isNotEmpty) return cached;
    throw Exception('فشل في جلب القنوات من جميع المسارات');
  }

  /// Single-pass O(n) parser.
  /// Tracks the last-seen #EXTINF line and pairs it with the next URL line.
  static List<Channel> _parseM3u(String content) {
    final lines    = content.split('\n');
    final channels = <Channel>[];
    String? pendingExtInf;

    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXTINF:')) {
        pendingExtInf = line;
      } else if (pendingExtInf != null && !line.startsWith('#')) {
        // This line is the stream URL for the pending EXTINF entry.
        channels.add(Channel(
          name:     _extractName(pendingExtInf),
          url:      line,
          logoUrl:  _logoRegex.firstMatch(pendingExtInf)?.group(1)    ?? '',
          group:    _groupRegex.firstMatch(pendingExtInf)?.group(1)   ?? '',
          tvgId:    _tvgIdRegex.firstMatch(pendingExtInf)?.group(1)   ?? '',
          tvgName:  _tvgNameRegex.firstMatch(pendingExtInf)?.group(1) ?? '',
        ));
        pendingExtInf = null;
      }
    }
    return channels;
  }

  static String _extractName(String extinf) {
    final idx = extinf.lastIndexOf(',');
    return (idx >= 0 && idx < extinf.length - 1)
        ? extinf.substring(idx + 1).trim()
        : 'Unknown Channel';
  }

  static List<ChannelCategory> organizeChannels(List<Channel> channels) {
    final Map<String, List<Channel>> grouped = {};
    for (final ch in channels) {
      final key = ch.group.isNotEmpty ? ch.group : 'أخرى';
      grouped.putIfAbsent(key, () => []).add(ch);
    }

    final categories = grouped.entries.map((e) => ChannelCategory(
      name:        e.key,
      displayName: e.key,
      channels:    e.value,
      sortOrder:   _sortOrder(e.key),
    )).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    return categories;
  }

  static int _sortOrder(String name) {
    final l = name.toLowerCase();
    if (l.contains('bein')  || l.contains('بين')  || l.contains('بي ان')) return 0;
    if (l.contains('alwan') || l.contains('الوان') || l.contains('ألوان')) return 1;
    if (l.contains('kass')  || l.contains('الكاس') || l.contains('الكأس')) return 2;
    if (l.contains('entertainment') || l.contains('ترفيه')) return 3;
    return 10;
  }

  static Future<void> _cacheChannels(List<Channel> channels) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey, jsonEncode(channels.map((c) => c.toJson()).toList()));
    await prefs.setInt(_cacheTimeKey, DateTime.now().millisecondsSinceEpoch);
  }

  static Future<List<Channel>?> _getCachedChannels() async {
    final prefs      = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_cacheKey);
    if (jsonString == null) return null;

    final cacheTime = prefs.getInt(_cacheTimeKey);
    if (cacheTime != null) {
      final age = DateTime.now().difference(
          DateTime.fromMillisecondsSinceEpoch(cacheTime));
      if (age > AppConfig.cacheDuration) return null;
    }

    try {
      final List<dynamic> list = jsonDecode(jsonString);
      return list.map((j) => Channel.fromJson(j as Map<String, dynamic>)).toList();
    } catch (_) {
      return null;
    }
  }
}
