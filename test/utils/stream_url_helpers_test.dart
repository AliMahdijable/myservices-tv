import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/utils/stream_url_helpers.dart';

void main() {
  group('alternateLiveStreamUrl', () {
    test('switches HLS to MPEG-TS', () {
      expect(
        alternateLiveStreamUrl('http://example.test/live/user/pass/42.m3u8'),
        'http://example.test/live/user/pass/42.ts',
      );
    });

    test('switches MPEG-TS to HLS and preserves query and fragment', () {
      expect(
        alternateLiveStreamUrl(
          'https://example.test/live/42.TS?token=abc%20123#live',
        ),
        'https://example.test/live/42.m3u8?token=abc%20123#live',
      );
    });

    test('leaves extensionless provider URLs unchanged', () {
      const url = 'https://example.test/channel?id=42';
      expect(alternateLiveStreamUrl(url), url);
    });
  });

  group('liveStreamFormat', () {
    test('reads the container from the path', () {
      expect(liveStreamFormat('http://host/live/u/p/7.ts'), 'ts');
      expect(liveStreamFormat('http://host/live/u/p/7.m3u8'), 'm3u8');
    });

    test('ignores query strings and is case-insensitive', () {
      expect(liveStreamFormat('http://host/live/u/p/7.M3U8?token=x'), 'm3u8');
    });

    test('returns null when no known container is present', () {
      expect(liveStreamFormat('http://host/channel?id=42'), isNull);
      expect(liveStreamFormat('not a url at all'), isNull);
    });
  });

  group('redactUrls', () {
    test('strips stream URLs so credentials never reach the log', () {
      // Xtream stream paths carry the account's username and password, which
      // would otherwise be written to logcat verbatim by mpv's errors.
      const message =
          'Failed to open http://panel.test:8080/live/ali1/secret/1.ts';
      final redacted = redactUrls(message);

      expect(redacted, contains('[stream-url]'));
      expect(redacted, isNot(contains('secret')));
      expect(redacted, isNot(contains('panel.test')));
      expect(redacted, startsWith('Failed to open'));
    });

    test('leaves text without a URL intact', () {
      expect(redactUrls('vd: Could not open codec.'),
          'vd: Could not open codec.');
    });
  });
}
