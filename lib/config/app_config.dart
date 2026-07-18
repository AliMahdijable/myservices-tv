import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

class AppConfig {
  // ── Default (private-network) credentials ──────────────────────────────
  static const String defaultBaseUrl = 'http://10.10.10.252:8080';
  static const String defaultUsername = 'ali1';
  static const String defaultPassword = 'ali1';

  // ── Runtime state (loaded from SharedPreferences) ──────────────────────
  static String _baseUrl = '';
  static String _username = '';
  static String _password = '';

  static const String _keyServerUrl = 'server_url';
  static const String _keyUsername = 'xtream_username';
  static const String _keyPassword = 'xtream_password';

  static String get baseUrl => _baseUrl;
  static String get username => _username;
  static String get password => _password;

  static bool get isConfigured =>
      _baseUrl.isNotEmpty && _username.isNotEmpty && _password.isNotEmpty;

  // ── Persistence ────────────────────────────────────────────────────────

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString(_keyServerUrl) ?? '';
    _username = prefs.getString(_keyUsername) ?? '';
    _password = prefs.getString(_keyPassword) ?? '';
  }

  static Future<void> save({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    _baseUrl = serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    _username = username.trim();
    _password = password.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyServerUrl, _baseUrl);
    await prefs.setString(_keyUsername, _username);
    await prefs.setString(_keyPassword, _password);
  }

  static Future<void> clear() async {
    _baseUrl = _username = _password = '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyServerUrl);
    await prefs.remove(_keyUsername);
    await prefs.remove(_keyPassword);
  }

  // ── Network reachability ───────────────────────────────────────────────

  /// Fast TCP ping to the default private server (3 s timeout).
  static Future<bool> isDefaultServerReachable() => _tcpPing(defaultBaseUrl);

  /// Fast TCP ping to the currently configured server (3 s timeout).
  static Future<bool> isCurrentServerReachable() => _tcpPing(_baseUrl);

  static Future<bool> _tcpPing(String serverUrl) async {
    try {
      final uri = Uri.parse(serverUrl);
      final host = uri.host;
      final port = (uri.hasPort && uri.port > 0) ? uri.port : 80;
      final sock = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 3),
      );
      sock.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── API URL builders ───────────────────────────────────────────────────

  // Standard Xtream Codes paths
  static String get xtreamApiBase =>
      buildXtreamApiUrl(_baseUrl, _username, _password);

  // Some servers use /api/ prefix (e.g. this server uses /api/get.php)
  static String get xtreamApiFallbackBase =>
      buildXtreamApiUrl(_baseUrl, _username, _password, fallback: true);

  // Standard M3U path
  static String get playlistUrl => _buildServerUri(
    _baseUrl,
    const ['get.php'],
    queryParameters: {
      'username': _username,
      'password': _password,
      'type': 'm3u_plus',
      'output': 'm3u8',
    },
  ).toString();

  // Fallback M3U path used by some servers (/api/get.php)
  static String get playlistFallbackUrl => _buildServerUri(
    _baseUrl,
    const ['api', 'get.php'],
    queryParameters: {
      'username': _username,
      'password': _password,
      'type': 'm3u_plus',
      'output': 'm3u8',
    },
  ).toString();

  static String liveStreamUrl(int streamId, {String ext = 'ts'}) =>
      _buildServerUri(_baseUrl, [
        'live',
        _username,
        _password,
        '$streamId.$ext',
      ]).toString();

  static String buildXtreamApiUrl(
    String serverUrl,
    String username,
    String password, {
    bool fallback = false,
  }) {
    return _buildServerUri(
      serverUrl.trim().replaceAll(RegExp(r'/+$'), ''),
      [if (fallback) 'api', 'player_api.php'],
      queryParameters: {'username': username, 'password': password},
    ).toString();
  }

  static Uri _buildServerUri(
    String serverUrl,
    List<String> pathSegments, {
    Map<String, String>? queryParameters,
  }) {
    final base = Uri.parse(serverUrl);
    return Uri(
      scheme: base.scheme,
      userInfo: base.userInfo,
      host: base.host,
      port: base.hasPort ? base.port : null,
      pathSegments: [
        ...base.pathSegments.where((segment) => segment.isNotEmpty),
        ...pathSegments,
      ],
      queryParameters: queryParameters,
    );
  }

  // ── Misc ───────────────────────────────────────────────────────────────
  static const Duration cacheDuration = Duration(hours: 6);
  static const String appVersion = '1.1.5';
}
