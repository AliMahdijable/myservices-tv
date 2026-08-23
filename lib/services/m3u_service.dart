import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import '../models/channel.dart';

class M3uService {
  // v2 persists per-channel HTTP headers. Keep it separate from the legacy
  // cache so an upgrade refreshes playlists that previously lost headers.
  static const String _cacheKey = 'cached_channels_v2';
  static const String _cacheTimeKey = 'cached_channels_time_v2';

  // Pre-compiled regex — created once, reused for every channel line.
  static final RegExp _logoRegex = RegExp(r'tvg-logo="([^"]*)"');
  static final RegExp _groupRegex = RegExp(r'group-title="([^"]*)"');
  static final RegExp _tvgIdRegex = RegExp(r'tvg-id="([^"]*)"');
  static final RegExp _tvgNameRegex = RegExp(r'tvg-name="([^"]*)"');
  static final RegExp _headerNameRegex = RegExp(
    r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$",
  );

  static const Set<String> _unhyphenatedInlineHeaderNames = {
    'accept',
    'authorization',
    'connection',
    'cookie',
    'host',
    'origin',
    'range',
    'referer',
    'referrer',
    'upgrade',
  };

  static Future<List<Channel>> fetchChannels({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh) {
      final cached = await _getCachedChannels();
      if (cached != null && cached.isNotEmpty) return cached;
    }

    // Try standard path first (/get.php), then server-specific path (/api/get.php)
    final urls = [AppConfig.playlistUrl, AppConfig.playlistFallbackUrl];

    for (final url in urls) {
      try {
        final response = await http
            .get(Uri.parse(url), headers: {'User-Agent': AppConfig.userAgent})
            .timeout(const Duration(seconds: 30));

        if (response.statusCode == 200) {
          final body = utf8.decode(response.bodyBytes, allowMalformed: true);
          if (body.contains('#EXTM3U')) {
            final channels = parseM3u(body);
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
  static List<Channel> parseM3u(String content) {
    final lines = content.split('\n');
    final channels = <Channel>[];
    String? pendingExtInf;
    var pendingHeaders = <String, String>{};

    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      if (line.toUpperCase().startsWith('#EXTINF:')) {
        pendingExtInf = line;
        pendingHeaders = <String, String>{};
      } else if (pendingExtInf != null &&
          _applyHeaderDirective(line, pendingHeaders)) {
        continue;
      } else if (pendingExtInf != null && !line.startsWith('#')) {
        // This line is the stream URL for the pending EXTINF entry.
        final stream = _parseStreamLine(line);
        final headers = <String, String>{...pendingHeaders};
        for (final entry in stream.httpHeaders.entries) {
          _setHeader(headers, entry.key, entry.value);
        }

        channels.add(
          Channel(
            name: _extractName(pendingExtInf),
            url: stream.url,
            logoUrl: _logoRegex.firstMatch(pendingExtInf)?.group(1) ?? '',
            group: _groupRegex.firstMatch(pendingExtInf)?.group(1) ?? '',
            tvgId: _tvgIdRegex.firstMatch(pendingExtInf)?.group(1) ?? '',
            tvgName: _tvgNameRegex.firstMatch(pendingExtInf)?.group(1) ?? '',
            httpHeaders: headers,
          ),
        );
        pendingExtInf = null;
        pendingHeaders = <String, String>{};
      }
    }
    return channels;
  }

  static bool _applyHeaderDirective(String line, Map<String, String> headers) {
    final upperLine = line.toUpperCase();
    const vlcPrefix = '#EXTVLCOPT:';
    if (upperLine.startsWith(vlcPrefix)) {
      final option = line.substring(vlcPrefix.length);
      final separator = option.indexOf('=');
      if (separator <= 0) return true;

      final optionName = option.substring(0, separator).trim().toLowerCase();
      final value = option.substring(separator + 1).trim();
      switch (optionName) {
        case 'http-user-agent':
          _setHeader(headers, 'User-Agent', value);
          break;
        case 'http-referrer':
        case 'http-referer':
          _setHeader(headers, 'Referer', value);
          break;
      }
      return true;
    }

    const httpPrefix = '#EXTHTTP:';
    if (upperLine.startsWith(httpPrefix)) {
      final payload = line.substring(httpPrefix.length).trim();
      _applyExtHttpJson(payload, headers);
      return true;
    }

    return false;
  }

  static void _applyExtHttpJson(String payload, Map<String, String> headers) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return;

      _addJsonHeaders(decoded, headers);
      final nestedHeaders = decoded['headers'];
      if (nestedHeaders is Map) {
        _addJsonHeaders(nestedHeaders, headers);
      }
    } on FormatException {
      // A malformed optional directive must not discard its channel.
    }
  }

  static void _addJsonHeaders(
    Map<dynamic, dynamic> source,
    Map<String, String> target,
  ) {
    for (final entry in source.entries) {
      if (entry.key is String && entry.value is String) {
        _setHeader(target, entry.key as String, entry.value as String);
      }
    }
  }

  static _ParsedStreamLine _parseStreamLine(String line) {
    final separator = line.lastIndexOf('|');
    if (separator <= 0 || separator == line.length - 1) {
      return _ParsedStreamLine(line);
    }

    final url = line.substring(0, separator).trim();
    final encodedHeaders = line.substring(separator + 1);
    if (url.isEmpty) return _ParsedStreamLine(line);

    final headers = _tryParseInlineHeaders(encodedHeaders);
    return headers == null
        ? _ParsedStreamLine(line)
        : _ParsedStreamLine(url, headers);
  }

  static Map<String, String>? _tryParseInlineHeaders(String value) {
    final headers = <String, String>{};

    try {
      for (final field in value.split('&')) {
        final separator = field.indexOf('=');
        if (separator <= 0) return null;

        final name = Uri.decodeQueryComponent(
          field.substring(0, separator),
        ).trim();
        final headerValue = Uri.decodeQueryComponent(
          field.substring(separator + 1),
        );
        if (!_isLikelyInlineHeader(name) || !_isSafeHeaderValue(headerValue)) {
          return null;
        }
        _setHeader(headers, name, headerValue);
      }
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }

    return headers.isEmpty ? null : headers;
  }

  static bool _isLikelyInlineHeader(String name) {
    final normalized = name.toLowerCase();
    return _headerNameRegex.hasMatch(name) &&
        (normalized.contains('-') ||
            _unhyphenatedInlineHeaderNames.contains(normalized));
  }

  static bool _isSafeHeaderValue(String value) =>
      !value.contains('\r') && !value.contains('\n') && !value.contains('\x00');

  static void _setHeader(
    Map<String, String> headers,
    String rawName,
    String value,
  ) {
    final name = _normalizeHeaderName(rawName);
    if (name == null || !_isSafeHeaderValue(value)) return;

    headers.removeWhere((key, _) => key.toLowerCase() == name.toLowerCase());
    headers[name] = value;
  }

  static String? _normalizeHeaderName(String rawName) {
    final name = rawName.trim();
    if (!_headerNameRegex.hasMatch(name)) return null;

    switch (name.toLowerCase()) {
      case 'http-user-agent':
      case 'user-agent':
        return 'User-Agent';
      case 'http-referrer':
      case 'http-referer':
      case 'referrer':
      case 'referer':
        return 'Referer';
      case 'http-origin':
      case 'origin':
        return 'Origin';
      case 'http-cookie':
      case 'cookie':
        return 'Cookie';
      case 'authorization':
        return 'Authorization';
      default:
        return name;
    }
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

    final categories =
        grouped.entries
            .map(
              (e) => ChannelCategory(
                name: e.key,
                displayName: e.key,
                channels: e.value,
                sortOrder: _sortOrder(e.key),
              ),
            )
            .toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    return categories;
  }

  static int _sortOrder(String name) {
    final l = name.toLowerCase();
    if (l.contains('bein') || l.contains('بين') || l.contains('بي ان')) {
      return 0;
    }
    if (l.contains('alwan') || l.contains('الوان') || l.contains('ألوان')) {
      return 1;
    }
    if (l.contains('kass') || l.contains('الكاس') || l.contains('الكأس')) {
      return 2;
    }
    if (l.contains('entertainment') || l.contains('ترفيه')) return 3;
    return 10;
  }

  static Future<void> _cacheChannels(List<Channel> channels) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _cacheKey,
      jsonEncode(channels.map((c) => c.toJson()).toList()),
    );
    await prefs.setInt(_cacheTimeKey, DateTime.now().millisecondsSinceEpoch);
  }

  static Future<List<Channel>?> _getCachedChannels() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_cacheKey);
    if (jsonString == null) return null;

    final cacheTime = prefs.getInt(_cacheTimeKey);
    if (cacheTime != null) {
      final age = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(cacheTime),
      );
      if (age > AppConfig.cacheDuration) return null;
    }

    try {
      final List<dynamic> list = jsonDecode(jsonString);
      return list
          .map((j) => Channel.fromJson(j as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey);
    await prefs.remove(_cacheTimeKey);
    await prefs.remove('cached_channels');
    await prefs.remove('cached_channels_time');
  }
}

class _ParsedStreamLine {
  final String url;
  final Map<String, String> httpHeaders;

  _ParsedStreamLine(this.url, [this.httpHeaders = const {}]);
}
