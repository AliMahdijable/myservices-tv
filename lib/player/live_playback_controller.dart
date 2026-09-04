import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../config/app_config.dart';
import '../models/channel.dart';
import '../utils/stream_url_helpers.dart';
import 'playback_preferences.dart';
import 'recovery_policy.dart';
import 'stream_failure.dart';

/// Everything the player UI needs to render, in one immutable snapshot.
@immutable
class PlaybackUiState {
  /// The stream is loading or rebuffering.
  final bool isBuffering;

  /// A visible reconnect is in progress (`attempt` of `maxAttempts`).
  final bool isReconnecting;
  final int attempt;
  final int maxAttempts;

  /// Playback has stopped for a reason the user must act on. Null while the
  /// controller still believes it can recover on its own.
  final StreamFailureKind? fatalError;

  /// Recovery is suspended until the device regains connectivity.
  final bool waitingForNetwork;

  /// The current attempt is decoding in software, either by preference or
  /// because hardware decoding failed on this channel.
  final bool usingSoftwareDecoder;

  const PlaybackUiState({
    this.isBuffering = true,
    this.isReconnecting = false,
    this.attempt = 0,
    this.maxAttempts = 0,
    this.fatalError,
    this.waitingForNetwork = false,
    this.usingSoftwareDecoder = false,
  });

  bool get hasFatalError => fatalError != null;

  PlaybackUiState copyWith({
    bool? isBuffering,
    bool? isReconnecting,
    int? attempt,
    int? maxAttempts,
    bool? waitingForNetwork,
    bool? usingSoftwareDecoder,
    StreamFailureKind? fatalError,
    bool clearFatalError = false,
  }) {
    return PlaybackUiState(
      isBuffering: isBuffering ?? this.isBuffering,
      isReconnecting: isReconnecting ?? this.isReconnecting,
      attempt: attempt ?? this.attempt,
      maxAttempts: maxAttempts ?? this.maxAttempts,
      waitingForNetwork: waitingForNetwork ?? this.waitingForNetwork,
      usingSoftwareDecoder: usingSoftwareDecoder ?? this.usingSoftwareDecoder,
      fatalError: clearFatalError ? null : (fatalError ?? this.fatalError),
    );
  }
}

/// Owns the native player and every rule about keeping a live stream running.
///
/// Split out of `PlayerScreen` so the playback engine is separable from the
/// D-pad and OSD code it used to be tangled with. The decision-making itself
/// lives in [RecoveryPolicy], which is pure and unit-tested; this class is the
/// part that must talk to mpv, timers and the network.
class LivePlaybackController {
  /// A freshly opened stream misbehaves in ways that self-correct: mpv can
  /// report a spurious "completed" while an HLS manifest warms up, and a
  /// hardware decoder can glitch on the first frame or two. Failures inside
  /// this window get the policy's free silent retry.
  static const Duration _warmupPeriod = Duration(seconds: 5);

  /// Continuous playback needed before an attempt counts as recovered.
  static const Duration _stabilityWindow = Duration(seconds: 12);
  static const Duration _stabilityProgress = Duration(seconds: 8);

  /// Created synchronously so the first `build()` — which runs before
  /// [initialize] has had a chance to complete — already has a controller to
  /// hand the `Video` widget.
  late final Player _player = Player(
    configuration: PlayerConfiguration(
      bufferSize: PlaybackPreferences.bufferProfile.bufferBytes,
    ),
  );
  late final VideoController _videoController = VideoController(_player);
  final RecoveryPolicy _policy = RecoveryPolicy();

  final ValueNotifier<PlaybackUiState> state = ValueNotifier(
    const PlaybackUiState(),
  );

  VideoController get videoController => _videoController;
  Player get player => _player;

  Channel? _channel;
  Channel? get channel => _channel;

  /// Every channel change opens a new session. Delayed callbacks belonging to
  /// a superseded stream are dropped rather than reconnecting the channel the
  /// user has since moved to.
  int _sessionId = 0;
  int _attemptId = 0;
  int? _handledFailureAttemptId;

  bool _mpvConfigApplied = true;
  bool _applyingPreferences = false;
  bool _disposed = false;
  /// True between releasing the old stream and the new open landing. mpv's
  /// stop() pushes buffering:false, which would otherwise blank the spinner
  /// mid-reconnect and make the app look like it lost track of itself.
  bool _openInFlight = false;
  bool _networkAvailable = true;
  bool _resumeWhenNetworkReturns = false;
  bool _currentAttemptUsesAlternateFormat = false;
  bool _currentAttemptUsesSoftwareDecoder = false;

  DateTime? _attemptStartedAt;

  Timer? _reconnectTimer;
  Timer? _stabilityTimer;
  Timer? _completedTimer;
  Timer? _watchdogTicker;

  int _bufferedSeconds = 0;
  int _stalledPositionSeconds = 0;
  Duration _lastKnownPosition = Duration.zero;

  StreamSubscription? _bufferingSub;
  StreamSubscription? _logSub;
  StreamSubscription? _errorSub;
  StreamSubscription? _completedSub;
  StreamSubscription? _playingSub;
  StreamSubscription? _connectivitySub;

  /// The most specific classification seen during the current attempt.
  ///
  /// One failed open produces several messages — an HTTP status from ffmpeg
  /// and mpv's generic 'Failed to open' — so the first to arrive is not
  /// necessarily the informative one. Keeping the most specific means a 403 is
  /// still recognised as a busy server when the generic line lands first.
  StreamFailureKind _attemptKind = StreamFailureKind.unknown;

  /// Carried across attempts within one channel so the watchdog, which times
  /// out with no message of its own, can reuse what mpv last reported.
  StreamFailureKind _lastReportedKind = StreamFailureKind.unknown;

  void _recordClassification(StreamFailureKind kind) {
    if (_specificity(kind) <= _specificity(_attemptKind)) return;
    _attemptKind = kind;
    _lastReportedKind = kind;
  }

  /// How much a classification actually tells us. An identified HTTP status
  /// outranks 'playback', which is where mpv's generic open failure lands.
  static int _specificity(StreamFailureKind kind) => switch (kind) {
    StreamFailureKind.unknown => 0,
    StreamFailureKind.playback => 1,
    _ => 2,
  };

  /// Attaches listeners and applies native properties.
  ///
  /// Must complete before the first stream is opened, since mpv only honours
  /// cache and decoder properties set ahead of the open.
  Future<void> initialize() async {
    _listenToPlayer();
    await _watchConnectivity();
    await _configureMpv();
  }

  // ── Native configuration ──────────────────────────────────────────────

  Future<void> _configureMpv() async {
    try {
      final platform = _player.platform;
      if (platform is! NativePlayer) return;

      final profile = PlaybackPreferences.bufferProfile;
      final properties = <String, String>{
        // Paired with the ffmpeg-level reconnect below: recoverable drops are
        // repaired inside ffmpeg, so this timeout only has to surface the
        // genuinely dead sockets, and can be far shorter than mpv's own wait.
        'network-timeout': '10',
        'cache': 'yes',
        'cache-on-disk': 'no',
        'cache-secs': profile.cacheSeconds,
        // Playback starts as soon as this much is buffered. mpv's default
        // holds the picture until the cache is comfortably full, which is
        // most of what made channel switching feel slow.
        'cache-pause-wait': profile.cachePauseWait,
        'cache-pause': 'yes',
        'cache-pause-initial': 'yes',
        // Live TV never seeks backwards, so keep the back buffer cheap.
        'demuxer-max-back-bytes': '2MiB',
        // The forward cache is installed once from PlayerConfiguration when the
        // Player is built, so without this a buffer-profile change at runtime
        // would raise cache-secs while the byte ceiling stayed at whatever the
        // launch profile set — the "stable" profile would promise depth it
        // could not hold.
        'demuxer-max-bytes': '${profile.bufferBytes}',
        // Let ffmpeg repair a dropped HTTP connection in place. Without this a
        // transient TCP reset ends the file, and recovery costs a full
        // stop()+open() — which on an Xtream panel means surrendering the
        // connection slot and immediately competing for a new one, plus one
        // attempt off a small budget. With it, the drop never surfaces at all.
        //
        // This MUST be stream-lavf-o, not demuxer-lavf-o: media_kit populates
        // demuxer-lavf-o with protocol_whitelist at construction, and
        // overwriting it would silently strip the whitelist.
        'stream-lavf-o': 'reconnect=1,reconnect_streamed=1,'
            'reconnect_on_network_error=1,reconnect_delay_max=5',
      };
      for (final property in properties.entries) {
        await platform.setProperty(property.key, property.value);
      }
      await _applyDecoder(software: false);
      // Configuration succeeded, so the watchdog can trust mpv's own timeout
      // again. Without this the flag latched false on the first transient
      // failure and never recovered, permanently shortening the budget.
      _mpvConfigApplied = true;
    } catch (error) {
      // mpv's own timeout/cache tuning did not apply, so the Dart-side
      // watchdog cannot rely on it and uses a shorter budget instead.
      _mpvConfigApplied = false;
      debugPrint('[Player] mpv configuration failed: ${redactUrls(error)}');
    }
  }

  /// Applies the decoder for the next attempt.
  ///
  /// [software] forces software decoding for a recovery attempt regardless of
  /// the user's preference; an explicit hardware/software preference is always
  /// honoured over the automatic fallback.
  Future<void> _applyDecoder({required bool software}) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;

    final preference = PlaybackPreferences.decoderMode;
    final effective = switch (preference) {
      DecoderMode.software => DecoderMode.software,
      DecoderMode.hardware => DecoderMode.hardware,
      DecoderMode.auto => software ? DecoderMode.software : DecoderMode.auto,
    };
    _currentAttemptUsesSoftwareDecoder = effective == DecoderMode.software;
    try {
      await platform.setProperty('hwdec', effective.mpvHwdec);
    } catch (error) {
      debugPrint('[Player] hwdec change failed: ${redactUrls(error)}');
    }
  }

  /// Re-reads the persisted settings and applies them to the running player.
  ///
  /// Serialised: concurrent invocations would interleave their property writes
  /// with each other's decoder change, leaving the hwdec actually in effect
  /// when an open lands unordered against the preference that triggered it.
  Future<void> applyPreferenceChanges() async {
    if (_applyingPreferences) return;
    _applyingPreferences = true;
    try {
      await _configureMpv();
      if (_channel != null) await play(_channel!);
    } finally {
      _applyingPreferences = false;
    }
  }

  // ── Connectivity ──────────────────────────────────────────────────────

  Future<void> _watchConnectivity() async {
    try {
      _networkAvailable = _hasNetwork(await Connectivity().checkConnectivity());
      _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
        final available = _hasNetwork(results);
        if (available == _networkAvailable) return;
        _networkAvailable = available;
        if (available) {
          _onNetworkRestored();
        } else {
          _onNetworkLost();
        }
      });
    } catch (error) {
      // Without connectivity information the controller simply assumes the
      // network is up, which is the pre-existing behaviour.
      debugPrint('[Player] connectivity unavailable: $error');
      _networkAvailable = true;
    }
  }

  static bool _hasNetwork(List<ConnectivityResult> results) =>
      results.any((result) => result != ConnectivityResult.none);

  void _onNetworkLost() {
    if (_disposed || _channel == null) return;
    // Stop immediately rather than letting mpv time out slowly against a dead
    // interface, and release the server-side connection while doing so.
    _cancelRecoveryTimers();
    _resumeWhenNetworkReturns = true;
    unawaited(_releaseStream());
    _emit(
      state.value.copyWith(
        isBuffering: true,
        isReconnecting: false,
        waitingForNetwork: true,
        clearFatalError: true,
      ),
    );
  }

  void _onNetworkRestored() {
    if (_disposed || _channel == null) return;
    if (!_resumeWhenNetworkReturns && !state.value.waitingForNetwork) return;
    _resumeWhenNetworkReturns = false;
    // Connectivity came back, so the channel deserves a clean budget rather
    // than resuming mid-way through a backoff sequence it never earned.
    _policy.reset();
    _emit(state.value.copyWith(waitingForNetwork: false));
    unawaited(play(_channel!));
  }

  // ── Player event wiring ───────────────────────────────────────────────

  void _listenToPlayer() {
    _bufferingSub = _player.stream.buffering.listen((buffering) {
      if (_disposed) return;
      // Between releasing the old stream and the new one opening, mpv's stop()
      // reports buffering:false. Mirroring it would blank the spinner and the
      // "reconnecting" counter for the length of the teardown, and would arm a
      // stability timer against a stream that is not playing.
      if (!buffering && _openInFlight) return;
      _emit(state.value.copyWith(isBuffering: buffering));
      if (buffering) {
        _stabilityTimer?.cancel();
      } else {
        _scheduleStabilityCheck(_sessionId, _attemptId);
      }
    });

    // media_kit's error stream drops FFmpeg's HTTP status lines: it forwards
    // the 'ffmpeg' prefix only when the text starts with 'tcp:', and an HTTP
    // status is emitted by the http URLContext ('http: HTTP error 403
    // Forbidden'), not the tcp one. Without this listener every 403 from a
    // saturated panel arrived only as mpv's generic 'Failed to open' and was
    // classified as a decoder problem — earning the fast retry ladder that
    // hammers the panel, a forced software-decoder switch, and a container
    // flip, which is the exact behaviour RecoveryPolicy exists to prevent.
    //
    // The log stream carries every message with its prefix and level, but
    // media_kit applies .distinct() to it, so a repeated identical line can be
    // swallowed. It is therefore used only to ENRICH the classification; the
    // error stream — explicitly not distinct — stays the trigger.
    _logSub = _player.stream.log.listen((entry) {
      if (_disposed) return;
      if (entry.level != 'error' && entry.level != 'fatal') return;
      if (isBenignStreamLog(entry.text)) return;
      _recordClassification(classifyStreamFailure(entry.text));
    });

    _errorSub = _player.stream.error.listen((message) {
      if (_disposed) return;
      debugPrint('[Player] stream error: ${redactUrls(message)}');
      if (isBenignStreamLog(message)) return;

      _recordClassification(classifyStreamFailure(message));
      _handleFailure(_sessionId, _attemptId, _attemptKind);
    });

    // A live endpoint may briefly report completion during a disconnect.
    _completedSub = _player.stream.completed.listen((completed) {
      if (_disposed) return;
      if (!completed) {
        _completedTimer?.cancel();
        return;
      }
      if (_withinWarmup) return;

      final sessionId = _sessionId;
      final attemptId = _attemptId;
      _completedTimer?.cancel();
      if (!state.value.isBuffering && !state.value.hasFatalError) {
        _emit(state.value.copyWith(isBuffering: true));
      }
      _completedTimer = Timer(const Duration(seconds: 3), () {
        if (_disposed ||
            sessionId != _sessionId ||
            attemptId != _attemptId ||
            !_player.state.completed) {
          return;
        }
        _handleFailure(sessionId, attemptId, StreamFailureKind.unreachable);
      });
    });

    _playingSub = _player.stream.playing.listen((playing) {
      if (_disposed) return;
      if (playing && !state.value.isBuffering) {
        _scheduleStabilityCheck(_sessionId, _attemptId);
      }
    });
  }

  bool get _withinWarmup {
    final startedAt = _attemptStartedAt;
    return startedAt != null &&
        DateTime.now().difference(startedAt) < _warmupPeriod;
  }

  // ── Playback ──────────────────────────────────────────────────────────

  /// Switches to [channel] with a fresh recovery budget.
  Future<void> play(Channel channel) async {
    if (_disposed) return;
    _cancelRecoveryTimers();
    _policy.reset();
    _channel = channel;
    _resumeWhenNetworkReturns = false;
    // A previous channel's failure must not label this one: an inherited
    // serverBusy would hand a merely-dead stream the 5s/10s/20s budget and
    // tell the user to close their other devices.
    _attemptKind = StreamFailureKind.unknown;
    _lastReportedKind = StreamFailureKind.unknown;

    _emit(
      const PlaybackUiState(isBuffering: true).copyWith(
        usingSoftwareDecoder: _currentAttemptUsesSoftwareDecoder,
      ),
    );

    final sessionId = ++_sessionId;
    await _open(sessionId, useAlternateFormat: false, useSoftware: false);
  }

  /// Reopens the current channel at the user's request, from the error screen.
  Future<void> retry() async {
    final channel = _channel;
    if (channel == null) return;
    await play(channel);
  }

  /// Invalidates in-flight callbacks without opening anything.
  ///
  /// Used while D-pad input is still being debounced, so an old stream's
  /// delayed error cannot reconnect a channel the user has already left.
  void beginPendingSwitch(Channel channel) {
    _sessionId++;
    _cancelRecoveryTimers();
    _policy.reset();
    _channel = channel;
    _attemptKind = StreamFailureKind.unknown;
    _lastReportedKind = StreamFailureKind.unknown;
    _emit(const PlaybackUiState(isBuffering: true));
  }

  Future<void> _open(
    int sessionId, {
    required bool useAlternateFormat,
    required bool useSoftware,
  }) async {
    if (_disposed || sessionId != _sessionId) return;
    final channel = _channel;
    if (channel == null) return;

    // Release the previous stream before opening the next one. On Xtream
    // panels an abandoned open keeps holding a connection slot, and those
    // slots are what a struggling account runs out of first — reopening
    // without releasing is what turns one failure into a cascade of 403s.
    _openInFlight = true;
    try {
      await _releaseStream();
      if (_disposed || sessionId != _sessionId) return;

      final attemptId = ++_attemptId;
      _handledFailureAttemptId = null;
      _attemptStartedAt = DateTime.now();
      _currentAttemptUsesAlternateFormat = useAlternateFormat;
      // Each attempt classifies itself from scratch; only the channel-level
      // _lastReportedKind carries over for the watchdog's fallback.
      _attemptKind = StreamFailureKind.unknown;

      await _applyDecoder(software: useSoftware);
      if (_disposed || sessionId != _sessionId) return;

      _startWatchdog(sessionId, attemptId);

      final url = useAlternateFormat
          ? alternateLiveStreamUrl(channel.url)
          : channel.url;
      final headers = <String, String>{
        'User-Agent': AppConfig.userAgent,
        ...channel.httpHeaders,
      };

      try {
        await _player.open(Media(url, httpHeaders: headers));
      } catch (error) {
        debugPrint('[Player] open failed: ${redactUrls(error)}');
        _recordClassification(classifyStreamFailure('$error'));
        _handleFailure(sessionId, attemptId, _attemptKind);
      }
    } finally {
      _openInFlight = false;
    }
  }

  Future<void> _releaseStream() async {
    try {
      await _player.stop();
    } catch (error) {
      debugPrint('[Player] stop failed: ${redactUrls(error)}');
    }
  }

  // ── Failure handling ──────────────────────────────────────────────────

  void _handleFailure(int sessionId, int attemptId, StreamFailureKind kind) {
    if (_disposed || sessionId != _sessionId || attemptId != _attemptId) return;
    if (attemptId == 0) return;

    // mpv emits several log errors plus a completed event for one failed
    // open. Recover from that attempt exactly once.
    if (_handledFailureAttemptId == attemptId) return;
    _handledFailureAttemptId = attemptId;

    _cancelRecoveryTimers();

    final decision = _policy.onFailure(
      kind,
      withinWarmup: _withinWarmup,
      networkAvailable: _networkAvailable,
    );

    switch (decision.action) {
      case RecoveryAction.waitForNetwork:
        _resumeWhenNetworkReturns = true;
        unawaited(_releaseStream());
        _emit(
          state.value.copyWith(
            isBuffering: true,
            isReconnecting: false,
            waitingForNetwork: true,
            clearFatalError: true,
          ),
        );

      case RecoveryAction.giveUp:
        unawaited(_releaseStream());
        _emit(
          state.value.copyWith(
            isBuffering: false,
            isReconnecting: false,
            waitingForNetwork: false,
            fatalError: decision.kind,
          ),
        );

      case RecoveryAction.silentRetry:
      case RecoveryAction.backoffRetry:
        final silent = decision.action == RecoveryAction.silentRetry;
        _emit(
          state.value.copyWith(
            isBuffering: true,
            // A silent retry is presented as continued loading, never as a
            // reconnect — the user should not see a counter for a glitch that
            // resolves in 400 ms.
            isReconnecting: !silent,
            attempt: silent ? state.value.attempt : decision.attempt,
            maxAttempts: silent
                ? state.value.maxAttempts
                : decision.maxAttempts,
            waitingForNetwork: false,
            clearFatalError: true,
          ),
        );
        _reconnectTimer = Timer(decision.delay, () {
          _reconnectTimer = null;
          unawaited(
            _open(
              sessionId,
              useAlternateFormat: decision.useAlternateFormat,
              useSoftware: decision.useSoftwareDecoder,
            ),
          );
        });
    }
  }

  // ── Watchdogs ─────────────────────────────────────────────────────────

  /// Ticks once a second for the lifetime of an attempt, covering two stall
  /// classes mpv's own buffering/error/completed events miss:
  ///
  ///  1. Repeated short rebuffers. mpv's buffering flag flaps on a degraded
  ///     link, so a one-shot timer reset on every onset would never fire.
  ///     The budget below accumulates instead, and decays while playing.
  ///  2. A silently frozen decoder: playing and not buffering, but the
  ///     position stops advancing with no error event at all.
  void _startWatchdog(int sessionId, int attemptId) {
    _watchdogTicker?.cancel();
    _bufferedSeconds = 0;
    _stalledPositionSeconds = 0;
    _lastKnownPosition = _player.state.position;
    // Without mpv's own network-timeout applied, fail over sooner rather than
    // trusting defaults that may never give up.
    final budgetSeconds = _mpvConfigApplied ? 35 : 20;

    _watchdogTicker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_disposed || sessionId != _sessionId || attemptId != _attemptId) {
        timer.cancel();
        return;
      }
      // Recovery is suspended while offline; the connectivity listener owns
      // the resume, so the watchdog must not also declare a failure.
      if (state.value.waitingForNetwork) return;

      if (state.value.isBuffering) {
        _bufferedSeconds++;
        if (_bufferedSeconds >= budgetSeconds) {
          timer.cancel();
          _handleFailure(sessionId, attemptId, _stallKind());
        }
        return;
      }

      // Let the penalty decay rather than only clearing it on a full
      // stability signal. A stream with a tolerable stutter — buffer a few
      // seconds, play a few, repeat — never holds 12 clean seconds, so
      // without decay the budget climbs across cycles and forces a needless
      // reconnect on a stream that is still delivering video.
      if (_bufferedSeconds > 0) _bufferedSeconds--;

      if (_player.state.playing && !_player.state.completed) {
        final position = _player.state.position;
        if (position > _lastKnownPosition) {
          _lastKnownPosition = position;
          _stalledPositionSeconds = 0;
        } else {
          _stalledPositionSeconds++;
          if (_stalledPositionSeconds >= 10) {
            timer.cancel();
            // A frozen picture with no mpv error is a decoder problem far
            // more often than a network one, so it is worth a software
            // decoding attempt.
            _handleFailure(sessionId, attemptId, StreamFailureKind.playback);
          }
        }
      } else {
        _stalledPositionSeconds = 0;
      }
    });
  }

  /// A stall that exhausted the buffering budget carries no message of its
  /// own, so reuse whatever mpv last reported for this attempt.
  StreamFailureKind _stallKind() =>
      _lastReportedKind == StreamFailureKind.unknown
      ? StreamFailureKind.unreachable
      : _lastReportedKind;

  void _scheduleStabilityCheck(int sessionId, int attemptId) {
    if (attemptId == 0) return;
    _stabilityTimer?.cancel();
    final startPosition = _player.state.position;

    _stabilityTimer = Timer(_stabilityWindow, () {
      if (_disposed || sessionId != _sessionId || attemptId != _attemptId) {
        return;
      }
      final progressed =
          _player.state.position - startPosition >= _stabilityProgress;
      // A single buffering=false event does not prove recovery; only
      // continuous playback with real position progress does.
      if (state.value.isBuffering ||
          !_player.state.playing ||
          _player.state.completed ||
          !progressed) {
        return;
      }

      _policy.markStable(onAlternateFormat: _currentAttemptUsesAlternateFormat);
      _lastReportedKind = StreamFailureKind.unknown;
      _handledFailureAttemptId = null;
      _emit(
        state.value.copyWith(
          isReconnecting: false,
          attempt: 0,
          maxAttempts: 0,
          clearFatalError: true,
        ),
      );
      _rememberWorkingFormat();
    });
  }

  /// Records the container format that just proved itself, so every other
  /// channel on this server opens with it directly instead of paying for the
  /// same discovery again.
  void _rememberWorkingFormat() {
    final channel = _channel;
    if (channel == null) return;
    final url = _currentAttemptUsesAlternateFormat
        ? alternateLiveStreamUrl(channel.url)
        : channel.url;
    final format = liveStreamFormat(url);
    if (format == null) return;
    unawaited(PlaybackPreferences.rememberFormat(AppConfig.baseUrl, format));
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────

  /// Whether the controller suspended a stream when the app went away, and so
  /// owes the user a reopen on return.
  ///
  /// Deliberately not sampled from `_player.state.playing`: media_kit reports
  /// playing:false from stop(), so backgrounding during a rebuffer or just
  /// after a release used to record false and leave the player permanently
  /// paused on return — no spinner, no error, nothing.
  bool _suspendedForBackground = false;

  void onAppBackgrounded() {
    if (_disposed || _channel == null) return;
    // Pausing alone leaves mpv's socket open, so the Xtream connection slot
    // stays occupied for as long as the app is backgrounded — on a TV box,
    // potentially hours during which nobody is watching. On an account whose
    // real ceiling is far below what the panel advertises, a couple of users
    // who pressed HOME instead of BACK is enough to push everyone else into
    // the 403 path.
    _suspendedForBackground = true;
    _cancelRecoveryTimers();
    unawaited(_releaseStream());
    _emit(state.value.copyWith(isBuffering: true, isReconnecting: false));
  }

  void onAppResumed() {
    if (_disposed || !_suspendedForBackground) return;
    _suspendedForBackground = false;
    final channel = _channel;
    if (channel == null || state.value.hasFatalError) return;
    // Reopening rather than resuming: a live stream's edge has moved on, and
    // the old socket is usually dead. Calling play() on it strands the user on
    // a frozen picture until the completed listener or the watchdog notices.
    unawaited(play(channel));
  }

  void togglePlayPause() {
    _player.state.playing ? _player.pause() : _player.play();
  }

  void _cancelRecoveryTimers() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stabilityTimer?.cancel();
    _completedTimer?.cancel();
    _watchdogTicker?.cancel();
  }

  void _emit(PlaybackUiState next) {
    if (_disposed) return;
    state.value = next;
  }

  Future<void> dispose() async {
    _disposed = true;
    // Invalidate every delayed callback before tearing down the native player.
    _sessionId++;
    _attemptId++;
    _cancelRecoveryTimers();
    await _bufferingSub?.cancel();
    await _logSub?.cancel();
    await _errorSub?.cancel();
    await _completedSub?.cancel();
    await _playingSub?.cancel();
    await _connectivitySub?.cancel();
    await _player.dispose();
    state.dispose();
  }
}
