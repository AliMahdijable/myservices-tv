import 'stream_failure.dart';

/// What the player should do next after a stream failed.
enum RecoveryAction {
  /// Reopen immediately and keep showing the loading state — the user is never
  /// told anything happened. Reserved for glitches during a stream's warm-up,
  /// which self-correct almost always.
  silentRetry,

  /// Reopen after [RecoveryDecision.delay], showing reconnect progress.
  backoffRetry,

  /// Stop attempting. Connectivity is gone, so retrying would only burn
  /// attempts; the controller resumes the moment the network returns.
  waitForNetwork,

  /// Show the terminal error. Either the failure cannot be fixed by retrying
  /// or the attempt budget is spent.
  giveUp,
}

/// The decision plus the parameters the next attempt should run with.
class RecoveryDecision {
  final RecoveryAction action;
  final Duration delay;
  final StreamFailureKind kind;

  /// Attempt number this decision schedules, 1-based. Zero for actions that
  /// do not open a stream.
  final int attempt;

  /// Total attempts allowed for this failure kind, for progress display.
  final int maxAttempts;

  /// Open the provider's other container format (.m3u8 ↔ .ts) this time.
  final bool useAlternateFormat;

  /// Open with software decoding this time.
  final bool useSoftwareDecoder;

  const RecoveryDecision({
    required this.action,
    required this.kind,
    this.delay = Duration.zero,
    this.attempt = 0,
    this.maxAttempts = 0,
    this.useAlternateFormat = false,
    this.useSoftwareDecoder = false,
  });
}

/// Decides how to recover from playback failures.
///
/// Kept free of `media_kit`, timers and Flutter so the rules that decide
/// whether the app hammers a struggling server — the single biggest influence
/// on perceived stability — can be tested directly.
///
/// The central rule is that recovery cost is not uniform. On Xtream panels
/// every open, *including a failed one*, holds a connection slot for a while.
/// A saturated panel answers 403 and the naive response — retry fast, five
/// times, alternating container formats — consumes more slots and keeps the
/// account past its ceiling. So a busy server gets few attempts spaced widely,
/// while a decoder glitch (which costs the server nothing) gets more attempts
/// spaced tightly.
class RecoveryPolicy {
  /// Attempts allowed before giving up, per failure kind.
  static const int _serverBusyAttempts = 3;
  static const int _defaultAttempts = 5;

  /// Free retries that stay invisible to the user, spent only on failures
  /// inside a fresh stream's warm-up window.
  static const int silentRetryBudget = 1;
  static const Duration silentRetryDelay = Duration(milliseconds: 400);

  int _attempt = 0;
  int _silentRetriesLeft = silentRetryBudget;
  int _playbackFailures = 0;
  bool _alternateFormatProven = false;
  bool _softwareDecoderEngaged = false;
  bool _lastAttemptUsedAlternateFormat = false;

  /// Attempts already spent on the current channel.
  int get attempt => _attempt;

  /// True once a failure forced software decoding for this channel.
  bool get softwareDecoderEngaged => _softwareDecoderEngaged;

  /// True once the alternate container format proved stable, so later
  /// reconnects in this session should keep using it rather than rediscovering
  /// it through another round of failures.
  bool get alternateFormatProven => _alternateFormatProven;

  /// Starts a fresh channel with a full budget.
  void reset() {
    _attempt = 0;
    _silentRetriesLeft = silentRetryBudget;
    _playbackFailures = 0;
    _alternateFormatProven = false;
    _softwareDecoderEngaged = false;
    _lastAttemptUsedAlternateFormat = false;
  }

  /// Called once a stream has played continuously with real progress.
  ///
  /// Only the attempt budget is refilled. Whatever format and decoder finally
  /// worked are deliberately retained: they are the configuration that proved
  /// itself, and rediscovering them costs the user another visible stall.
  void markStable({required bool onAlternateFormat}) {
    _attempt = 0;
    _playbackFailures = 0;
    _alternateFormatProven = onAlternateFormat;
    _lastAttemptUsedAlternateFormat = false;
  }

  /// Maps a failure to the next step.
  ///
  /// [withinWarmup] is true while the stream is still in its startup window,
  /// where spurious errors are expected. [networkAvailable] reflects the
  /// device's own connectivity.
  RecoveryDecision onFailure(
    StreamFailureKind kind, {
    required bool withinWarmup,
    required bool networkAvailable,
  }) {
    if (!networkAvailable || kind == StreamFailureKind.offline) {
      // The attempt budget is untouched: a dropped Wi-Fi connection is not the
      // channel's fault, and spending retries on it means the stream is
      // already marked dead by the time the network comes back.
      return const RecoveryDecision(
        action: RecoveryAction.waitForNetwork,
        kind: StreamFailureKind.offline,
      );
    }

    if (!kind.isRetryable) {
      // 401 and 404 cannot resolve themselves. Five retries would add ~30 s of
      // false hope and five wasted connection slots.
      return RecoveryDecision(action: RecoveryAction.giveUp, kind: kind);
    }

    if (kind == StreamFailureKind.playback) _playbackFailures++;

    if (withinWarmup && _silentRetriesLeft > 0) {
      _silentRetriesLeft--;
      return RecoveryDecision(
        action: RecoveryAction.silentRetry,
        kind: kind,
        delay: silentRetryDelay,
        attempt: _attempt,
        maxAttempts: _maxAttemptsFor(kind),
        useAlternateFormat: _shouldUseAlternateFormat(kind),
        useSoftwareDecoder: _shouldUseSoftwareDecoder(),
      );
    }

    final maxAttempts = _maxAttemptsFor(kind);
    if (_attempt >= maxAttempts) {
      return RecoveryDecision(
        action: RecoveryAction.giveUp,
        kind: kind,
        maxAttempts: maxAttempts,
      );
    }

    _attempt++;
    return RecoveryDecision(
      action: RecoveryAction.backoffRetry,
      kind: kind,
      delay: _delayFor(kind, _attempt),
      attempt: _attempt,
      maxAttempts: maxAttempts,
      useAlternateFormat: _shouldUseAlternateFormat(kind),
      useSoftwareDecoder: _shouldUseSoftwareDecoder(),
    );
  }

  int _maxAttemptsFor(StreamFailureKind kind) =>
      kind == StreamFailureKind.serverBusy
      ? _serverBusyAttempts
      : _defaultAttempts;

  Duration _delayFor(StreamFailureKind kind, int attempt) {
    if (kind == StreamFailureKind.serverBusy) {
      // Slots on an Xtream panel are released lazily. Retrying inside a couple
      // of seconds reliably lands on the same refusal while adding another
      // half-open connection, so back off far enough for the server to catch
      // up: 5 s, 10 s, 20 s.
      return Duration(seconds: 5 * (1 << (attempt - 1)));
    }
    if (kind == StreamFailureKind.serverError ||
        kind == StreamFailureKind.unreachable) {
      // 2 s, 4 s, 8 s, capped — the host may be restarting.
      return Duration(seconds: _capped(1 << attempt, 8));
    }
    // Decoder and unknown failures cost the server nothing, so recover fast:
    // 1 s, 2 s, 4 s, capped at 5 s.
    return Duration(seconds: _capped(1 << (attempt - 1), 5));
  }

  /// Switching container format is worth an attempt only when the failure
  /// could plausibly be format-specific, and only after the original format
  /// has genuinely failed twice.
  ///
  /// Once eligible, this ALTERNATES rather than committing permanently: many
  /// Xtream panels only ever serve one of the two container formats for a
  /// given stream (the other 404s or times out regardless of the real
  /// channel's health), so a naive "switch and stay switched" rule burns the
  /// rest of the attempt budget on a format that can never work if the format
  /// picked at attempt 2 happens to be the unsupported one -- even though the
  /// original format may have already recovered from whatever caused the
  /// first two failures. Toggling means neither format can monopolize more
  /// than roughly half of the remaining attempts.
  bool _shouldUseAlternateFormat(StreamFailureKind kind) {
    if (_alternateFormatProven) return true;
    if (!kind.suggestsAlternateFormat || _attempt < 2) {
      _lastAttemptUsedAlternateFormat = false;
      return false;
    }
    _lastAttemptUsedAlternateFormat = !_lastAttemptUsedAlternateFormat;
    return _lastAttemptUsedAlternateFormat;
  }

  /// Falls back to software decoding after the hardware decoder has failed
  /// twice on this channel. Once engaged it stays engaged for the channel:
  /// flipping back would just reproduce the failure.
  bool _shouldUseSoftwareDecoder() {
    if (_softwareDecoderEngaged) return true;
    if (_playbackFailures >= 2) {
      _softwareDecoderEngaged = true;
      return true;
    }
    return false;
  }

  static int _capped(int value, int max) => value > max ? max : value;
}
