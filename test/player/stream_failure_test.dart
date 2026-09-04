import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/player/stream_failure.dart';

void main() {
  group('isBenignStreamLog', () {
    test("mpv's live seekability probe is not a failure", () {
      expect(
        isBenignStreamLog('Cannot seek in this stream, no seeking possible'),
        isTrue,
      );
    });

    test('a missing audio device is silent video, not stopped video', () {
      // Seen on the iOS simulator and on boxes with HDMI audio negotiation
      // trouble. Reconnecting cannot conjure an audio device, so treating this
      // as a failure just stalls a stream that is playing.
      expect(
        isBenignStreamLog(
          'Could not open/initialize audio device -> no sound.',
        ),
        isTrue,
      );
    });

    test('real failures are not filtered out', () {
      expect(isBenignStreamLog('Server returned 403 Forbidden'), isFalse);
      expect(isBenignStreamLog('vd: Could not open codec.'), isFalse);
      expect(isBenignStreamLog('tcp: Connection refused'), isFalse);
    });
  });

  group('classifyStreamFailure', () {
    test('reads FFmpeg HTTP status codes', () {
      expect(
        classifyStreamFailure(
          'tcp://10.10.10.252:8080: Server returned 403 Forbidden (access denied)',
        ),
        StreamFailureKind.serverBusy,
      );
      expect(
        classifyStreamFailure('Server returned 401 Unauthorized'),
        StreamFailureKind.unauthorized,
      );
      expect(
        classifyStreamFailure('Server returned 404 Not Found'),
        StreamFailureKind.notFound,
      );
      expect(
        classifyStreamFailure('Server returned 5XX Server Error reply'),
        StreamFailureKind.serverError,
      );
    });

    test('does not read a status code out of unrelated digits', () {
      // A channel named "MBC 403" or a URL ending in 404.ts must not be
      // mistaken for an HTTP status.
      expect(
        classifyStreamFailure('Opening http://host/live/u/p/403.ts'),
        isNot(StreamFailureKind.serverBusy),
      );
      expect(
        classifyStreamFailure('demuxer: read 404 bytes'),
        isNot(StreamFailureKind.notFound),
      );
    });

    test('recognises transport failures', () {
      expect(
        classifyStreamFailure('tcp: ffurl_open failed: Connection refused'),
        StreamFailureKind.unreachable,
      );
      expect(
        classifyStreamFailure('Failed to resolve hostname panel.example.com'),
        StreamFailureKind.unreachable,
      );
      expect(
        classifyStreamFailure('tcp: Network is unreachable'),
        StreamFailureKind.offline,
      );
    });

    test('recognises decoder breakdowns', () {
      expect(
        classifyStreamFailure('vd: Could not open codec.'),
        StreamFailureKind.playback,
      );
      expect(
        classifyStreamFailure(
          'Failed to initialize a decoder for codec hevc',
        ),
        StreamFailureKind.playback,
      );
      expect(
        classifyStreamFailure('mediacodec: failed to configure surface'),
        StreamFailureKind.playback,
      );
    });

    test('falls back to unknown for unrecognised text', () {
      expect(
        classifyStreamFailure('something entirely unexpected'),
        StreamFailureKind.unknown,
      );
    });
  });

  group('recovery metadata', () {
    test('permanent failures are not retryable', () {
      expect(StreamFailureKind.unauthorized.isRetryable, isFalse);
      expect(StreamFailureKind.notFound.isRetryable, isFalse);
      expect(StreamFailureKind.serverBusy.isRetryable, isTrue);
      expect(StreamFailureKind.playback.isRetryable, isTrue);
    });

    test('a busy or unreachable server does not warrant a format switch', () {
      // Switching .m3u8 ↔ .ts against a saturated panel doubles the connection
      // churn that caused the refusal in the first place.
      expect(StreamFailureKind.serverBusy.suggestsAlternateFormat, isFalse);
      expect(StreamFailureKind.unreachable.suggestsAlternateFormat, isFalse);
      expect(StreamFailureKind.offline.suggestsAlternateFormat, isFalse);
      expect(StreamFailureKind.playback.suggestsAlternateFormat, isTrue);
      expect(StreamFailureKind.notFound.suggestsAlternateFormat, isTrue);
    });

    test('only playback failures suggest a software-decoding retry', () {
      expect(StreamFailureKind.playback.suggestsDecoderFallback, isTrue);
      expect(StreamFailureKind.serverBusy.suggestsDecoderFallback, isFalse);
    });

    test('every kind carries a non-empty Arabic message', () {
      for (final kind in StreamFailureKind.values) {
        expect(kind.title, isNotEmpty, reason: '$kind title');
        expect(kind.guidance, isNotEmpty, reason: '$kind guidance');
      }
    });
  });
}
