import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../models/fixture.dart';

/// Reads match schedules, results and league tables from the home server.
///
/// The whole feature is deliberately LAN-only: the JSON lives on the owner's
/// own box, is refreshed there by cron, and is not published anywhere else.
/// Off the home network there is nothing to show — so [isAvailable] gates the
/// navigation destination rather than letting the user open a screen that can
/// only ever fail.
class FixturesService {
  /// The web front-end and the app read the same file, so the two never
  /// disagree about what is playing.
  static const String host = '10.10.10.254';
  static const String fixturesUrl = 'http://$host/data/fixtures.json';

  static const String _cacheKey = 'fixtures_cache_v1';
  static const String _cacheTimeKey = 'fixtures_cache_time_v1';

  /// The server refreshes every two hours; caching for one keeps the screen
  /// instant on reopen without ever showing yesterday's scores.
  static const Duration cacheDuration = Duration(hours: 1);

  static const Duration _probeTimeout = Duration(seconds: 2);
  static const Duration _retryDelay = Duration(milliseconds: 700);
  static const Duration _requestTimeout = Duration(seconds: 12);

  static bool? _availableCache;

  /// The probe currently in flight, so two callers cannot race.
  ///
  /// The home screen asks on start and again on resume; without this the two
  /// probes overlap and whichever finishes last wins, so a slow failure could
  /// overwrite a fresh success and hide the section until the next resume.
  static Future<bool>? _inFlight;

  /// Whether the home server is reachable from wherever the device is now.
  ///
  /// A TCP connect rather than an HTTP request: it answers in milliseconds on
  /// the LAN and fails just as fast off it, so the nav bar never stalls
  /// waiting on a server that is not there.
  static Future<bool> isAvailable({bool forceRecheck = false}) {
    if (!forceRecheck && _availableCache != null) {
      return Future.value(_availableCache!);
    }
    return _inFlight ??= _probe().whenComplete(() => _inFlight = null);
  }

  static Future<bool> _probe() async {
    // A phone woken at the front door answers the first probe before its radio
    // has associated, and one refusal used to hide the section for the rest of
    // the session. A second attempt costs a moment on a network that really is
    // absent and rescues the far more common case of one that is merely slow.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final socket = await Socket.connect(host, 80, timeout: _probeTimeout);
        socket.destroy();
        _availableCache = true;
        return true;
      } catch (_) {
        if (attempt == 0) await Future<void>.delayed(_retryDelay);
      }
    }
    _availableCache = false;
    return false;
  }

  /// Sets the reachability answer without probing.
  ///
  /// Exists so widget tests that render the home screen do not open a real
  /// socket — `Socket.connect`'s timeout leaves a pending timer that fails the
  /// test binding's invariant check, and a unit test should not depend on
  /// whether the machine running it happens to be on the owner's LAN.
  @visibleForTesting
  static void debugSetAvailable(bool? value) {
    _availableCache = value;
    _inFlight = null;
  }

  /// Forgets the reachability answer, so the next check probes again.
  ///
  /// Called when the app resumes: a phone that left the house between one
  /// session and the next must not keep showing a destination that no longer
  /// works, and one that came home must get it back.
  static void invalidateAvailability() => _availableCache = null;

  /// Fetches the file, falling back to the cache when the network fails.
  ///
  /// Returns null only when there is neither a live response nor a cached one.
  static Future<FixturesData?> fetch({bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final cached = await _readCache();
      if (cached != null) return cached;
    }

    try {
      final response = await http
          .get(
            Uri.parse(fixturesUrl),
            headers: const {
              'User-Agent': AppConfig.userAgent,
              // The file is rewritten in place every two hours, and a stale
              // 200 from a proxy would show finished matches as upcoming.
              'Cache-Control': 'no-cache',
            },
          )
          .timeout(_requestTimeout);

      if (response.statusCode == 200) {
        final decoded = jsonDecode(
          utf8.decode(response.bodyBytes, allowMalformed: true),
        );
        if (decoded is Map<String, dynamic>) {
          final data = FixturesData.fromJson(decoded);
          if (!data.isEmpty) {
            await _writeCache(response.bodyBytes);
            return data;
          }
        }
      }
      debugPrint('[Fixtures] unexpected response: ${response.statusCode}');
    } catch (error) {
      debugPrint('[Fixtures] fetch failed: $error');
    }

    // Network failed: stale data beats an empty screen, so ignore the TTL here.
    return _readCache(ignoreAge: true);
  }

  static Future<void> _writeCache(List<int> bytes) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cacheKey,
        utf8.decode(bytes, allowMalformed: true),
      );
      await prefs.setInt(_cacheTimeKey, DateTime.now().millisecondsSinceEpoch);
    } catch (error) {
      debugPrint('[Fixtures] cache write failed: $error');
    }
  }

  static Future<FixturesData?> _readCache({bool ignoreAge = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null) return null;

      if (!ignoreAge) {
        final stamp = prefs.getInt(_cacheTimeKey);
        if (stamp == null) return null;
        final age = DateTime.now().difference(
          DateTime.fromMillisecondsSinceEpoch(stamp),
        );
        if (age > cacheDuration) return null;
      }

      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final data = FixturesData.fromJson(decoded);
      return data.isEmpty ? null : data;
    } catch (error) {
      debugPrint('[Fixtures] cache read failed: $error');
      return null;
    }
  }

  static Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey);
    await prefs.remove(_cacheTimeKey);
  }
}
