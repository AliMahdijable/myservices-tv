import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/services/m3u_service.dart';

void main() {
  group('M3uService.parseM3u', () {
    test('parses channel metadata without headers', () {
      const playlist = '''
#EXTM3U
#EXTINF:-1 tvg-id="news.id" tvg-name="News HD" tvg-logo="https://img.example/news.png" group-title="News",News Channel
https://stream.example/news.m3u8
''';

      final channels = M3uService.parseM3u(playlist);

      expect(channels, hasLength(1));
      expect(channels.single.name, 'News Channel');
      expect(channels.single.url, 'https://stream.example/news.m3u8');
      expect(channels.single.logoUrl, 'https://img.example/news.png');
      expect(channels.single.group, 'News');
      expect(channels.single.tvgId, 'news.id');
      expect(channels.single.tvgName, 'News HD');
      expect(channels.single.httpHeaders, isEmpty);
    });

    test('parses VLC user-agent and referrer options', () {
      const playlist = '''
#EXTM3U
#EXTINF:-1,Protected Channel
#EXTVLCOPT:http-user-agent=My IPTV Player/2.0
#EXTVLCOPT:http-referrer=https://portal.example/watch
https://stream.example/live.ts
''';

      final channel = M3uService.parseM3u(playlist).single;

      expect(channel.httpHeaders, {
        'User-Agent': 'My IPTV Player/2.0',
        'Referer': 'https://portal.example/watch',
      });
    });

    test('parses flat and nested EXTHTTP JSON headers safely', () {
      const playlist = '''
#EXTM3U
#EXTINF:-1,JSON Headers
#EXTHTTP:{"User-Agent":"JSON Agent","Cookie":"session=abc","Retry-Count":3,"Bad Header":"ignored","headers":{"origin":"https://portal.example","X-Device":"tv"}}
https://stream.example/live.m3u8
''';

      final channel = M3uService.parseM3u(playlist).single;

      expect(channel.httpHeaders, {
        'User-Agent': 'JSON Agent',
        'Cookie': 'session=abc',
        'Origin': 'https://portal.example',
        'X-Device': 'tv',
      });
    });

    test('extracts and percent-decodes pipe headers from the stream URL', () {
      const playlist = '''
#EXTM3U
#EXTINF:-1,Pipe Headers
https://stream.example/live.m3u8?token=abc|User-Agent=IPTV%20Player%2F1.0&Referer=https%3A%2F%2Fportal.example%2Fwatch%3Fa%3D1%26b%3D2&Cookie=session%3Dabc%3B%20theme%3Ddark
''';

      final channel = M3uService.parseM3u(playlist).single;

      expect(channel.url, 'https://stream.example/live.m3u8?token=abc');
      expect(channel.httpHeaders, {
        'User-Agent': 'IPTV Player/1.0',
        'Referer': 'https://portal.example/watch?a=1&b=2',
        'Cookie': 'session=abc; theme=dark',
      });
    });

    test('pipe headers override earlier directives case-insensitively', () {
      const playlist = '''
#EXTM3U
#EXTINF:-1,Header Priority
#EXTVLCOPT:http-user-agent=VLC Agent
#EXTHTTP:{"user-agent":"JSON Agent","referer":"https://json.example/"}
https://stream.example/live.ts|USER-AGENT=Pipe%20Agent&Referrer=https%3A%2F%2Fpipe.example%2F
''';

      final channel = M3uService.parseM3u(playlist).single;

      expect(channel.httpHeaders, {
        'User-Agent': 'Pipe Agent',
        'Referer': 'https://pipe.example/',
      });
    });

    test('keeps the full URL when a pipe suffix is not safely parseable', () {
      const playlist = '''
#EXTM3U
#EXTINF:-1,Application Parameter
https://stream.example/live.ts|token=not-a-header
#EXTINF:-1,Injected Header
https://stream.example/second.ts|User-Agent=good%0D%0AX-Injected%3Ayes
#EXTINF:-1,Bad Encoding
https://stream.example/third.ts|User-Agent=%ZZ
''';

      final channels = M3uService.parseM3u(playlist);

      expect(channels, hasLength(3));
      expect(
        channels[0].url,
        'https://stream.example/live.ts|token=not-a-header',
      );
      expect(
        channels[1].url,
        'https://stream.example/second.ts|User-Agent=good%0D%0AX-Injected%3Ayes',
      );
      expect(channels[2].url, 'https://stream.example/third.ts|User-Agent=%ZZ');
      expect(channels.every((channel) => channel.httpHeaders.isEmpty), isTrue);
    });

    test(
      'does not leak headers and tolerates malformed optional directives',
      () {
        const playlist = '''
#EXTM3U
#EXTINF:-1,First
#EXTVLCOPT:http-user-agent=First Agent
https://stream.example/first.ts
#EXTINF:-1,Abandoned
#EXTVLCOPT:http-referrer=https://abandoned.example/
#EXTINF:-1,Second
#EXTHTTP:{not-json}
https://stream.example/second.ts
''';

        final channels = M3uService.parseM3u(playlist);

        expect(channels, hasLength(2));
        expect(channels[0].httpHeaders, {'User-Agent': 'First Agent'});
        expect(channels[1].name, 'Second');
        expect(channels[1].httpHeaders, isEmpty);
      },
    );
  });
}
