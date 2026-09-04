import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/player/playback_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  const server = 'http://panel.example.com:8080';

  group('stream format resolution', () {
    test('defaults to MPEG-TS for an unknown server', () async {
      // TS opens one long-lived connection; HLS re-requests a segment every
      // few seconds, which is what saturates connection-limited panels.
      expect(await PlaybackPreferences.formatForServer(server), 'ts');
    });

    test('remembers the format that played stably', () async {
      await PlaybackPreferences.rememberFormat(server, 'm3u8');
      expect(await PlaybackPreferences.formatForServer(server), 'm3u8');
    });

    test('keeps formats separate per server', () async {
      await PlaybackPreferences.rememberFormat(server, 'm3u8');
      expect(
        await PlaybackPreferences.formatForServer('http://other.example.com'),
        'ts',
      );
    });

    test('ignores a format the app cannot open', () async {
      await PlaybackPreferences.rememberFormat(server, 'rtmp');
      expect(await PlaybackPreferences.formatForServer(server), 'ts');
    });

    test('falls back to the default for an empty server key', () async {
      expect(await PlaybackPreferences.formatForServer(''), 'ts');
    });
  });

  group('allowed_output_formats', () {
    test('narrows the default to what the panel will serve', () async {
      await PlaybackPreferences.applyAllowedFormats(server, ['m3u8', 'rtmp']);
      expect(await PlaybackPreferences.formatForServer(server), 'm3u8');
    });

    test('never overrides a format already proven in playback', () async {
      // Panels have been seen advertising m3u8 and still refusing it under
      // load, so what actually played wins over what the panel claims.
      await PlaybackPreferences.rememberFormat(server, 'ts');
      await PlaybackPreferences.applyAllowedFormats(server, ['ts', 'm3u8']);
      expect(await PlaybackPreferences.formatForServer(server), 'ts');
    });

    test('replaces a stored format the panel no longer allows', () async {
      await PlaybackPreferences.rememberFormat(server, 'm3u8');
      await PlaybackPreferences.applyAllowedFormats(server, ['ts']);
      expect(await PlaybackPreferences.formatForServer(server), 'ts');
    });

    test('an unusable or empty advertisement changes nothing', () async {
      await PlaybackPreferences.rememberFormat(server, 'm3u8');
      await PlaybackPreferences.applyAllowedFormats(server, ['rtmp']);
      await PlaybackPreferences.applyAllowedFormats(server, []);
      expect(await PlaybackPreferences.formatForServer(server), 'm3u8');
    });
  });

  group('persisted player settings', () {
    test('round-trip decoder mode and buffer profile', () async {
      await PlaybackPreferences.setDecoderMode(DecoderMode.software);
      await PlaybackPreferences.setBufferProfile(BufferProfile.stable);

      await PlaybackPreferences.load();
      expect(PlaybackPreferences.decoderMode, DecoderMode.software);
      expect(PlaybackPreferences.bufferProfile, BufferProfile.stable);
    });

    test('unknown stored values fall back to the safe defaults', () async {
      SharedPreferences.setMockInitialValues({
        'player_decoder_mode': 'quantum',
        'player_buffer_profile': 'infinite',
      });
      await PlaybackPreferences.load();

      expect(PlaybackPreferences.decoderMode, DecoderMode.auto);
      expect(PlaybackPreferences.bufferProfile, BufferProfile.balanced);
    });

    test('buffer profiles trade start-up latency against resilience', () {
      final wait = BufferProfile.values
          .map((p) => double.parse(p.cachePauseWait))
          .toList();
      final secs = BufferProfile.values
          .map((p) => int.parse(p.cacheSeconds))
          .toList();

      // fast → balanced → stable must be monotonically more buffered.
      expect(wait[0] < wait[1] && wait[1] < wait[2], isTrue);
      expect(secs[0] < secs[1] && secs[1] < secs[2], isTrue);
    });

    test('decoder modes map to distinct mpv hwdec values', () {
      expect(DecoderMode.software.mpvHwdec, 'no');
      expect(DecoderMode.auto.mpvHwdec, 'auto-safe');
      expect(DecoderMode.hardware.mpvHwdec, 'auto');
    });
  });
}
