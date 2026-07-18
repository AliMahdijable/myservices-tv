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
}
