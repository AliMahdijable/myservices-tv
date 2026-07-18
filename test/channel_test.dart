import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/models/channel.dart';

void main() {
  group('Channel HTTP headers JSON', () {
    test('reads old cached channels without an httpHeaders field', () {
      final channel = Channel.fromJson({
        'name': 'Old channel',
        'url': 'https://stream.example/old.m3u8',
        'streamId': 12,
      });

      expect(channel.httpHeaders, isEmpty);
      expect(channel.name, 'Old channel');
      expect(channel.streamId, 12);
    });

    test('round-trips string HTTP headers', () {
      final original = Channel(
        name: 'Protected channel',
        url: 'https://stream.example/live.m3u8',
        httpHeaders: const {
          'User-Agent': 'MyServices TV/1.0',
          'Referer': 'https://portal.example/',
        },
      );

      final restored = Channel.fromJson(original.toJson());

      expect(restored.httpHeaders, original.httpHeaders);
      expect(restored.toJson()['httpHeaders'], const {
        'User-Agent': 'MyServices TV/1.0',
        'Referer': 'https://portal.example/',
      });
    });

    test('ignores malformed cached header entries', () {
      final channel = Channel.fromJson({
        'name': 'Mixed cache',
        'url': 'https://stream.example/live.ts',
        'httpHeaders': <dynamic, dynamic>{
          'User-Agent': 'Valid agent',
          'Retry-Count': 3,
          4: 'invalid key',
        },
      });

      expect(channel.httpHeaders, {'User-Agent': 'Valid agent'});
    });

    test('exposes headers as an unmodifiable map', () {
      final source = <String, String>{'User-Agent': 'Original'};
      final channel = Channel(
        name: 'Channel',
        url: 'https://stream.example/live.ts',
        httpHeaders: source,
      );

      source['User-Agent'] = 'Changed outside';

      expect(channel.httpHeaders['User-Agent'], 'Original');
      expect(
        () => channel.httpHeaders['Referer'] = 'https://portal.example/',
        throwsUnsupportedError,
      );
    });
  });
}
