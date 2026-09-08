import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/player/recovery_policy.dart';
import 'package:myservices_tv/player/stream_failure.dart';

/// Convenience wrapper: the common case is a failure outside the warm-up
/// window with the network up.
RecoveryDecision fail(
  RecoveryPolicy policy,
  StreamFailureKind kind, {
  bool withinWarmup = false,
  bool networkAvailable = true,
}) => policy.onFailure(
  kind,
  withinWarmup: withinWarmup,
  networkAvailable: networkAvailable,
);

void main() {
  late RecoveryPolicy policy;

  setUp(() => policy = RecoveryPolicy());

  group('permanent failures', () {
    test('a 401 gives up on the first failure', () {
      final decision = fail(policy, StreamFailureKind.unauthorized);
      expect(decision.action, RecoveryAction.giveUp);
      // The budget must be untouched — nothing was attempted.
      expect(policy.attempt, 0);
    });

    test('a 404 gives up on the first failure', () {
      expect(
        fail(policy, StreamFailureKind.notFound).action,
        RecoveryAction.giveUp,
      );
    });
  });

  group('offline handling', () {
    test('waits for the network instead of spending attempts', () {
      for (var i = 0; i < 10; i++) {
        final decision = fail(
          policy,
          StreamFailureKind.unknown,
          networkAvailable: false,
        );
        expect(decision.action, RecoveryAction.waitForNetwork);
        expect(decision.kind, StreamFailureKind.offline);
      }
      // Ten offline failures must not have consumed the retry budget, so the
      // channel is still fully recoverable once connectivity returns.
      expect(policy.attempt, 0);
      expect(
        fail(policy, StreamFailureKind.unknown).action,
        RecoveryAction.backoffRetry,
      );
    });

    test('an offline-classified error waits even if the network reads up', () {
      expect(
        fail(policy, StreamFailureKind.offline).action,
        RecoveryAction.waitForNetwork,
      );
    });
  });

  group('warm-up silent retries', () {
    test('the first warm-up failure retries invisibly and for free', () {
      final decision = fail(
        policy,
        StreamFailureKind.playback,
        withinWarmup: true,
      );
      expect(decision.action, RecoveryAction.silentRetry);
      expect(decision.delay, RecoveryPolicy.silentRetryDelay);
      expect(policy.attempt, 0);
    });

    test('the budget is one — a second warm-up failure is treated as real', () {
      fail(policy, StreamFailureKind.playback, withinWarmup: true);
      final second = fail(
        policy,
        StreamFailureKind.playback,
        withinWarmup: true,
      );
      expect(second.action, RecoveryAction.backoffRetry);
      expect(policy.attempt, 1);
    });
  });

  group('server-busy backoff', () {
    test('backs off far wider than for other failures', () {
      final first = fail(policy, StreamFailureKind.serverBusy);
      final second = fail(policy, StreamFailureKind.serverBusy);
      final third = fail(policy, StreamFailureKind.serverBusy);

      expect(first.delay, const Duration(seconds: 5));
      expect(second.delay, const Duration(seconds: 10));
      expect(third.delay, const Duration(seconds: 20));
    });

    test('allows fewer attempts, because each one costs a connection slot', () {
      for (var i = 0; i < RecoveryPolicy.silentRetryBudget; i++) {
        fail(policy, StreamFailureKind.serverBusy, withinWarmup: true);
      }
      var last = fail(policy, StreamFailureKind.serverBusy);
      var attempts = 1;
      while (last.action == RecoveryAction.backoffRetry) {
        last = fail(policy, StreamFailureKind.serverBusy);
        attempts++;
      }
      expect(last.action, RecoveryAction.giveUp);
      expect(attempts, 4, reason: '3 retries then give up');
    });

    test('never switches container format against a saturated server', () {
      // Both formats are refused by a panel that is out of slots, so
      // alternating only doubles the churn that caused the refusal.
      for (var i = 0; i < 3; i++) {
        final decision = fail(policy, StreamFailureKind.serverBusy);
        expect(decision.useAlternateFormat, isFalse);
      }
    });
  });

  group('alternate container format', () {
    test('is not tried before the original format failed twice', () {
      final first = fail(policy, StreamFailureKind.playback);
      expect(first.useAlternateFormat, isFalse);
      final second = fail(policy, StreamFailureKind.playback);
      expect(second.useAlternateFormat, isTrue);
    });

    test(
      'alternates rather than committing when the switched format also fails',
      () {
        // Many Xtream panels only ever serve one container format for a given
        // stream -- the other 404s/times out regardless of the channel's real
        // health. If the format picked at attempt 2 happens to be the
        // unsupported one, the remaining budget must not be spent entirely on
        // a format that can never work while the original format (which may
        // have already recovered) never gets tried again.
        final first = fail(policy, StreamFailureKind.playback); // attempt 1
        expect(first.useAlternateFormat, isFalse);
        final second = fail(policy, StreamFailureKind.playback); // attempt 2
        expect(second.useAlternateFormat, isTrue);
        final third = fail(policy, StreamFailureKind.playback); // attempt 3
        expect(
          third.useAlternateFormat,
          isFalse,
          reason: 'give the original format another chance rather than '
              'repeating the format that just failed',
        );
        final fourth = fail(policy, StreamFailureKind.playback); // attempt 4
        expect(fourth.useAlternateFormat, isTrue);
      },
    );

    test('a format proven stable is kept for later reconnects', () {
      policy.markStable(onAlternateFormat: true);
      expect(policy.alternateFormatProven, isTrue);
      // The very next failure reopens on the proven format immediately rather
      // than rediscovering it through two more visible stalls.
      expect(
        fail(policy, StreamFailureKind.unreachable).useAlternateFormat,
        isTrue,
      );
    });
  });

  group('software decoder fallback', () {
    test('engages after two decoder failures and then sticks', () {
      expect(fail(policy, StreamFailureKind.playback).useSoftwareDecoder,
          isFalse);
      expect(
        fail(policy, StreamFailureKind.playback).useSoftwareDecoder,
        isTrue,
      );
      expect(policy.softwareDecoderEngaged, isTrue);
      // Staying on software decoding matters: flipping back to hardware would
      // reproduce the same failure.
      expect(
        fail(policy, StreamFailureKind.unreachable).useSoftwareDecoder,
        isTrue,
      );
    });

    test('a busy server never triggers a decoder change', () {
      fail(policy, StreamFailureKind.serverBusy);
      fail(policy, StreamFailureKind.serverBusy);
      expect(policy.softwareDecoderEngaged, isFalse);
    });
  });

  group('stability resets', () {
    test('markStable refills the attempt budget', () {
      fail(policy, StreamFailureKind.unknown);
      fail(policy, StreamFailureKind.unknown);
      expect(policy.attempt, 2);

      policy.markStable(onAlternateFormat: false);
      expect(policy.attempt, 0);
    });

    test('markStable keeps the decoder that finally worked', () {
      fail(policy, StreamFailureKind.playback);
      fail(policy, StreamFailureKind.playback);
      expect(policy.softwareDecoderEngaged, isTrue);

      policy.markStable(onAlternateFormat: false);
      expect(policy.softwareDecoderEngaged, isTrue);
    });

    test('reset returns a full budget for a newly selected channel', () {
      fail(policy, StreamFailureKind.playback);
      fail(policy, StreamFailureKind.playback);
      policy.reset();

      expect(policy.attempt, 0);
      expect(policy.softwareDecoderEngaged, isFalse);
      expect(policy.alternateFormatProven, isFalse);
      expect(
        fail(policy, StreamFailureKind.playback, withinWarmup: true).action,
        RecoveryAction.silentRetry,
      );
    });
  });

  test('the default budget is five attempts then give up', () {
    var decision = fail(policy, StreamFailureKind.unknown);
    var attempts = 1;
    while (decision.action == RecoveryAction.backoffRetry) {
      decision = fail(policy, StreamFailureKind.unknown);
      attempts++;
    }
    expect(decision.action, RecoveryAction.giveUp);
    expect(attempts, 6, reason: '5 retries then give up');
  });
}
