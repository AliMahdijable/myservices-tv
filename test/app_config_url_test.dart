import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/config/app_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppConfig.save(
      serverUrl: 'https://tv.example.test:8443/iptv/',
      username: 'user&one',
      password: 'p/#? word',
    );
  });

  test('Xtream URLs preserve base paths and encode credentials', () {
    final standard = Uri.parse(AppConfig.xtreamApiBase);
    final fallback = Uri.parse(AppConfig.xtreamApiFallbackBase);

    expect(standard.pathSegments, ['iptv', 'player_api.php']);
    expect(fallback.pathSegments, ['iptv', 'api', 'player_api.php']);
    expect(standard.queryParameters['username'], 'user&one');
    expect(standard.queryParameters['password'], 'p/#? word');
    expect(standard.port, 8443);
  });

  test('playlist URL supplies HLS parameters safely', () {
    final playlist = Uri.parse(AppConfig.playlistUrl);

    expect(playlist.pathSegments, ['iptv', 'get.php']);
    expect(playlist.queryParameters, {
      'username': 'user&one',
      'password': 'p/#? word',
      'type': 'm3u_plus',
      'output': 'm3u8',
    });
  });

  test('live URL encodes credentials as individual path segments', () {
    final live = Uri.parse(AppConfig.liveStreamUrl(42, ext: 'm3u8'));

    expect(live.pathSegments, [
      'iptv',
      'live',
      'user&one',
      'p/#? word',
      '42.m3u8',
    ]);
    expect(live.query, isEmpty);
  });
}
