import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../config/app_config.dart';
import '../models/channel.dart';
import '../theme/app_theme.dart';
import '../utils/category_helpers.dart';
import '../utils/stream_url_helpers.dart';
import '../services/favorites_service.dart';
import '../services/recently_watched_service.dart';

class PlayerScreen extends StatefulWidget {
  final Channel channel;
  final List<ChannelCategory> categories;

  const PlayerScreen({
    super.key,
    required this.channel,
    required this.categories,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController _videoController;
  late Channel _currentChannel;
  late List<ChannelCategory> _playbackCategories;
  late List<Channel> _allChannels;
  int _currentIndex = 0;

  bool _showControls = true;
  bool _showChannelList = false;
  bool _osdInteractive = true;
  bool _isBuffering = true;
  bool _hasError = false;
  int _retryCount = 0;
  static const int _maxRetries = 5;
  static const String _lastChannelKey = 'last_channel_index';

  // 0 = letterbox (BoxFit.contain), 1 = zoom/fill (BoxFit.cover) — applied
  // declaratively via _buildVideoLayer()'s `fit:` on every build.
  int _aspectMode = 0;
  static const String _aspectModeKey = 'player_aspect_mode';
  static const List<IconData> _aspectIcons = [
    Icons.fit_screen_rounded,
    Icons.crop_free_rounded,
  ];
  static const List<String> _aspectLabels = ['ملاءمة', 'ملء'];

  Timer? _hideTimer;
  Timer? _channelSwitchDebounce;
  Timer? _reconnectTimer;
  Timer? _stablePlaybackTimer;
  Timer? _completedTimer;

  // Ticks every second for the life of an attempt. Tracks two independent
  // stall classes mpv's own buffering/error/completed events can miss:
  // repeated short rebuffers (cumulative _bufferedSeconds never resets just
  // because a stall briefly clears) and a decoder-level freeze (playing and
  // not buffering, but position stops advancing).
  Timer? _bufferWatchdogTicker;
  int _bufferedSeconds = 0;
  Duration _lastKnownPosition = Duration.zero;
  int _stalledPositionSeconds = 0;
  bool _mpvConfigApplied = true;
  bool _wasPlayingBeforeBackground = true;

  // A freshly opened stream can misbehave during startup in ways that
  // self-correct almost immediately: mpv/HLS can report a spurious
  // "completed" while the manifest is still warming up, and a hardware
  // decoder can glitch (e.g. a brief green/garbage frame) and report an
  // error on the first frame or two. Give each attempt a warm-up window
  // where this is expected and recoverable rather than a real failure.
  DateTime? _attemptStartedAt;
  static const Duration _attemptWarmupPeriod = Duration(seconds: 5);
  // One free, silent retry per channel open for anything that fails during
  // the warm-up window — shown to the user as continued loading, not a
  // "reconnecting" state. A second failure (warmup or not) is real.
  int _silentRetriesRemaining = 0;

  // Every channel change creates a new session. Delayed callbacks from an old
  // stream are ignored instead of reconnecting the newly selected channel.
  int _playbackSessionId = 0;
  int _currentAttemptId = 0;
  int? _handledFailureAttemptId;
  bool _preferAlternateUrl = false;
  bool _currentAttemptUsesAlternateUrl = false;

  Set<String> _favoriteUrls = {};
  bool _showChannelInfo = false;
  Timer? _channelInfoTimer;

  final FocusNode _screenFocusNode = FocusNode();
  final FocusScopeNode _osdFocusScopeNode = FocusScopeNode();
  final FocusNode _osdDefaultFocusNode = FocusNode();
  final FocusScopeNode _errorFocusScopeNode = FocusScopeNode();
  final FocusNode _errorRetryFocusNode = FocusNode();
  int _focusedChannelIndex = 0;
  final ScrollController _channelListScrollController = ScrollController();

  // Pre-built flat list for the channel sidebar (headers + channels mixed).
  late List<_SidebarItem> _sidebarItems;
  // Maps global channel index → position in _sidebarItems for O(1) scrolling.
  late Map<int, int> _channelToItemIndex;
  // Pre-computed cumulative scroll offsets per item.
  late List<double> _sidebarOffsets;

  StreamSubscription? _bufferingSub;
  StreamSubscription? _errorSub;
  StreamSubscription? _completedSub;
  StreamSubscription? _playingSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentChannel = widget.channel;

    _playbackCategories = widget.categories
        .where((category) => category.channels.isNotEmpty)
        .toList();
    _allChannels = _playbackCategories.expand((c) => c.channels).toList();
    // Match by URL so recently-watched JSON-deserialized channels resolve correctly
    _currentIndex = _allChannels.indexWhere((c) => c.url == widget.channel.url);
    if (_currentIndex < 0) {
      final fallbackCategory = ChannelCategory(
        name: widget.channel.group.isEmpty ? 'current' : widget.channel.group,
        displayName: widget.channel.group.isEmpty
            ? 'القناة الحالية'
            : widget.channel.group,
        channels: [widget.channel],
        sortOrder: -1,
      );
      _playbackCategories = [fallbackCategory, ..._playbackCategories];
      _allChannels = [widget.channel, ..._allChannels];
      _currentIndex = 0;
    }
    _focusedChannelIndex = _currentIndex;
    _buildSidebarData();

    _player = Player(
      configuration: const PlayerConfiguration(bufferSize: 32 * 1024 * 1024),
    );
    _videoController = VideoController(_player);

    _setupPlayerListeners();

    WakelockPlus.enable();

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    unawaited(_initializePlayback());
    _startHideTimer();
    _loadFavorites();
    _loadAspectMode();

    WidgetsBinding.instance.addPostFrameCallback((_) => _focusOsdDefault());
  }

  Future<void> _loadAspectMode() async {
    final preferences = await SharedPreferences.getInstance();
    final saved = preferences.getInt(_aspectModeKey);
    if (mounted && saved != null && saved != _aspectMode) {
      setState(() => _aspectMode = saved % _aspectLabels.length);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _wasPlayingBeforeBackground = _player.state.playing;
        _player.pause();
        break;
      case AppLifecycleState.resumed:
        if (_wasPlayingBeforeBackground && !_hasError) {
          _player.play();
        }
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _initializePlayback() async {
    // All native properties must be applied before opening the first stream.
    await _configureMpv();
    if (!mounted) return;
    await _playChannel(_currentChannel);
  }

  Future<void> _configureMpv() async {
    try {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        // VideoController already selects Android's safe hardware decoder
        // profile. Do not override hwdec, video-sync, framedrop or libavformat
        // options here: media_kit supplies device-safe defaults and essential
        // HLS options such as segment retries.
        const properties = <String, String>{
          'network-timeout': '20',
          'cache': 'yes',
          'cache-on-disk': 'no',
          'cache-pause': 'yes',
          'cache-pause-initial': 'yes',
          'cache-pause-wait': '2',
          'cache-secs': '15',
          // PlayerConfiguration provides a 32 MiB forward cache. Live TV does
          // not need a large backwards cache, so keep its memory cost small.
          'demuxer-max-back-bytes': '2MiB',
        };
        for (final property in properties.entries) {
          await platform.setProperty(property.key, property.value);
        }
      }
    } catch (error) {
      // mpv's own network-timeout/cache tuning didn't apply — fall back to a
      // shorter Dart-side watchdog budget instead of trusting mpv defaults.
      _mpvConfigApplied = false;
      debugPrint('[Player] mpv configuration failed: ${_redactLog(error)}');
    }
  }

  void _setupPlayerListeners() {
    _bufferingSub = _player.stream.buffering.listen((buffering) {
      if (!mounted) return;
      final sessionId = _playbackSessionId;
      setState(() => _isBuffering = buffering);
      if (buffering) {
        _stablePlaybackTimer?.cancel();
      } else {
        _scheduleStablePlaybackReset(sessionId, _currentAttemptId);
      }
    });

    _errorSub = _player.stream.error.listen((message) {
      debugPrint('[Player] stream error: ${_redactLog(message)}');
      if (mounted) {
        _handleStreamError(_playbackSessionId, _currentAttemptId);
      }
    });

    // A live endpoint may temporarily report completion during a disconnect.
    // Debounce it and bind the callback to the active playback session.
    _completedSub = _player.stream.completed.listen((completed) {
      if (!mounted) return;
      if (!completed) {
        _completedTimer?.cancel();
        return;
      }
      final startedAt = _attemptStartedAt;
      if (startedAt != null &&
          DateTime.now().difference(startedAt) < _attemptWarmupPeriod) {
        return;
      }
      final sessionId = _playbackSessionId;
      final attemptId = _currentAttemptId;
      _completedTimer?.cancel();
      if (!_isBuffering && !_hasError) {
        setState(() => _isBuffering = true);
      }
      _completedTimer = Timer(const Duration(seconds: 3), () {
        if (mounted &&
            sessionId == _playbackSessionId &&
            attemptId == _currentAttemptId &&
            _player.state.completed) {
          _handleStreamError(sessionId, attemptId);
        }
      });
    });

    _playingSub = _player.stream.playing.listen((playing) {
      if (!mounted) return;
      if (playing && !_isBuffering) {
        _scheduleStablePlaybackReset(_playbackSessionId, _currentAttemptId);
      }
    });
  }

  void _scheduleStablePlaybackReset(int sessionId, int attemptId) {
    if (attemptId == 0) return;
    _stablePlaybackTimer?.cancel();
    final startPosition = _player.state.position;
    _stablePlaybackTimer = Timer(const Duration(seconds: 12), () {
      if (!mounted ||
          sessionId != _playbackSessionId ||
          attemptId != _currentAttemptId) {
        return;
      }
      final progressed =
          _player.state.position - startPosition >= const Duration(seconds: 8);
      if (!_isBuffering &&
          _player.state.playing &&
          !_player.state.completed &&
          progressed) {
        // A single buffering=false event is not enough to prove recovery.
        // Reset only after continuous playback with real position progress.
        _retryCount = 0;
        _bufferedSeconds = 0;
        _handledFailureAttemptId = null;
        // If only the provider's alternate endpoint became stable, keep using
        // it for later reconnects in this channel session.
        _preferAlternateUrl = _currentAttemptUsesAlternateUrl;
      }
    });
  }

  Future<void> _loadFavorites() async {
    final urls = await FavoritesService.getFavoriteUrls();
    if (mounted) setState(() => _favoriteUrls = urls);
  }

  void _showChannelInfoBriefly() {
    setState(() => _showChannelInfo = true);
    _channelInfoTimer?.cancel();
    _channelInfoTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showChannelInfo = false);
    });
  }

  Future<void> _toggleFavorite() async {
    final isNowFav = await FavoritesService.toggleFavorite(_currentChannel);
    if (mounted) {
      setState(() {
        if (isNowFav) {
          _favoriteUrls.add(_currentChannel.url);
        } else {
          _favoriteUrls.remove(_currentChannel.url);
        }
      });
    }
  }

  // Ticks once per second for the lifetime of an attempt and closes two
  // recovery gaps mpv's own buffering/error/completed events can miss:
  //  1) mpv's buffering flag can flap true/false rapidly on a degraded link
  //     (short stalls, brief recoveries). A one-shot timer reset on every
  //     onset would never accumulate enough continuous time to fire, so the
  //     budget below only resets on a *proven* stable-playback signal (see
  //     _scheduleStablePlaybackReset), not on every buffering=false blip.
  //  2) mpv can report playing=true/buffering=false while the decoder is
  //     silently frozen with no error/completed event. Position progress is
  //     tracked independently and a stall is treated as a failure too.
  void _startBufferWatchdog(int sessionId, int attemptId) {
    if (attemptId == 0) return;
    _bufferWatchdogTicker?.cancel();
    _bufferedSeconds = 0;
    _stalledPositionSeconds = 0;
    _lastKnownPosition = _player.state.position;
    // mpv's own network-timeout may not have applied; use a shorter budget.
    final budgetSeconds = _mpvConfigApplied ? 35 : 20;
    _bufferWatchdogTicker = Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) {
      if (!mounted ||
          sessionId != _playbackSessionId ||
          attemptId != _currentAttemptId) {
        timer.cancel();
        return;
      }

      if (_isBuffering) {
        _bufferedSeconds++;
        if (_bufferedSeconds >= budgetSeconds) {
          timer.cancel();
          _handleStreamError(sessionId, attemptId);
        }
        return;
      }

      // Not buffering this tick: let the penalty decay instead of only
      // clearing it on a full 12s-stability signal. A stream with a
      // persistent-but-tolerable stutter (buffer a few seconds, play a
      // few, repeat) never holds 12 clean seconds, so without decay this
      // budget climbs across cycles and forces a needless reconnect on a
      // stream that is actually still delivering video.
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
            _handleStreamError(sessionId, attemptId);
          }
        }
      } else {
        _stalledPositionSeconds = 0;
      }
    });
  }

  void _handleStreamError(int sessionId, int attemptId) {
    if (!mounted ||
        sessionId != _playbackSessionId ||
        attemptId == 0 ||
        attemptId != _currentAttemptId) {
      return;
    }
    if (_channelSwitchDebounce?.isActive ?? false) return;

    // mpv can emit several log errors plus completed for one failed open.
    // Count and recover from that attempt exactly once.
    if (_handledFailureAttemptId == attemptId) return;
    _handledFailureAttemptId = attemptId;

    _bufferWatchdogTicker?.cancel();
    _stablePlaybackTimer?.cancel();
    _completedTimer?.cancel();

    // Coalesce duplicate mpv error/completed events into one reconnect.
    if (_reconnectTimer?.isActive ?? false) return;

    if (_silentRetriesRemaining > 0 &&
        _attemptStartedAt != null &&
        DateTime.now().difference(_attemptStartedAt!) < _attemptWarmupPeriod) {
      _silentRetriesRemaining--;
      setState(() => _isBuffering = true);
      _reconnectTimer = Timer(const Duration(milliseconds: 400), () {
        _reconnectTimer = null;
        if (mounted && sessionId == _playbackSessionId) {
          unawaited(_doPlayChannel(_currentChannel, sessionId));
        }
      });
      return;
    }

    if (_retryCount >= _maxRetries) {
      setState(() {
        _hasError = true;
        _isBuffering = false;
        _showControls = false;
        _showChannelList = false;
      });
      _hideTimer?.cancel();
      _focusErrorRetry();
      return;
    }

    _retryCount++;
    // Exponential backoff: 2s, 4s, 8s, 8s, 8s (capped).
    final delay = Duration(seconds: min(1 << _retryCount, 8));

    setState(() {
      _isBuffering = true;
      _hasError = false;
    });

    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (mounted && sessionId == _playbackSessionId) {
        unawaited(_doPlayChannel(_currentChannel, sessionId));
      }
    });
  }

  Future<void> _playChannel(Channel channel) async {
    _channelSwitchDebounce?.cancel();
    _bufferWatchdogTicker?.cancel();
    _reconnectTimer?.cancel();
    _stablePlaybackTimer?.cancel();
    _completedTimer?.cancel();
    _retryCount = 0;
    _silentRetriesRemaining = 1;
    _handledFailureAttemptId = null;
    _preferAlternateUrl = false;
    _currentAttemptUsesAlternateUrl = false;
    final sessionId = ++_playbackSessionId;

    setState(() {
      _currentChannel = channel;
      _isBuffering = true;
      _hasError = false;
    });

    unawaited(RecentlyWatchedService.addChannel(channel));

    // Persist last played channel for next session
    unawaited(_persistLastChannelIndex());

    await _doPlayChannel(channel, sessionId);
  }

  Future<void> _persistLastChannelIndex() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(_lastChannelKey, _currentIndex);
  }

  Future<void> _doPlayChannel(Channel channel, int sessionId) async {
    if (!mounted || sessionId != _playbackSessionId) return;
    final attemptId = ++_currentAttemptId;
    _handledFailureAttemptId = null;
    _attemptStartedAt = DateTime.now();
    _startBufferWatchdog(sessionId, attemptId);

    // After 2 consecutive failures, try alternate format (.m3u8 ↔ .ts).
    // Once that endpoint proves stable, retain it for this channel session.
    _currentAttemptUsesAlternateUrl = _preferAlternateUrl || _retryCount >= 2;
    final url = _currentAttemptUsesAlternateUrl
        ? alternateLiveStreamUrl(channel.url)
        : channel.url;
    final headers = <String, String>{
      'User-Agent': AppConfig.userAgent,
      ...channel.httpHeaders,
    };
    try {
      await _player.open(Media(url, httpHeaders: headers));
    } catch (error) {
      debugPrint('[Player] open failed: ${_redactLog(error)}');
      if (mounted) _handleStreamError(sessionId, attemptId);
    }
  }

  String _redactLog(Object value) {
    return value.toString().replaceAll(
      RegExp(r'https?://[^\s]+'),
      '[stream-url]',
    );
  }

  void _retryManually() {
    unawaited(_playChannel(_currentChannel));
    _requestScreenFocus();
  }

  void _playChannelDebounced(Channel channel) {
    _channelSwitchDebounce?.cancel();
    // Invalidate callbacks from the old stream immediately while D-pad input
    // is being debounced.
    _playbackSessionId++;
    _bufferWatchdogTicker?.cancel();
    _reconnectTimer?.cancel();
    _stablePlaybackTimer?.cancel();
    _completedTimer?.cancel();
    _preferAlternateUrl = false;
    _currentAttemptUsesAlternateUrl = false;
    setState(() {
      _currentChannel = channel;
      _isBuffering = true;
      _hasError = false;
    });
    _channelSwitchDebounce = Timer(const Duration(milliseconds: 300), () {
      unawaited(_playChannel(channel));
    });
  }

  void _nextChannel() {
    if (_currentIndex < _allChannels.length - 1) {
      _currentIndex++;
      _focusedChannelIndex = _currentIndex;
      _playChannelDebounced(_allChannels[_currentIndex]);
      _showChannelInfoBriefly();
      _resetHideTimer();
    }
  }

  void _previousChannel() {
    if (_currentIndex > 0) {
      _currentIndex--;
      _focusedChannelIndex = _currentIndex;
      _playChannelDebounced(_allChannels[_currentIndex]);
      _showChannelInfoBriefly();
      _resetHideTimer();
    }
  }

  void _switchToChannel(int globalIndex) {
    if (globalIndex < 0 || globalIndex >= _allChannels.length) return;
    // Reselecting the channel that's already playing needs no reconnect —
    // just close the guide.
    if (globalIndex != _currentIndex) {
      _currentIndex = globalIndex;
      // Route through the same debounce as channel-up/down so a fast
      // double-pick on the list doesn't fully open a discarded channel
      // before opening the intended one.
      _playChannelDebounced(_allChannels[globalIndex]);
    }
    _focusedChannelIndex = globalIndex;
    setState(() {
      _showChannelList = false;
      _osdInteractive = false;
    });
    _requestScreenFocus();
    _resetHideTimer();
  }

  void _toggleControls() {
    if (_showControls && _osdInteractive) {
      _hideControls();
      return;
    }
    _showInteractiveControls();
  }

  void _showInteractiveControls() {
    if (!mounted) return;
    setState(() {
      _showControls = true;
      _showChannelList = false;
      _osdInteractive = true;
    });
    _startHideTimer();
    _focusOsdDefault();
  }

  void _hideControls() {
    if (!mounted) return;
    _hideTimer?.cancel();
    setState(() {
      _showControls = false;
      _showChannelList = false;
      _osdInteractive = false;
    });
    _requestScreenFocus();
  }

  void _openChannelList() {
    if (_allChannels.isEmpty) return;
    _hideTimer?.cancel();
    setState(() {
      _showControls = true;
      _showChannelList = true;
      _osdInteractive = false;
      _focusedChannelIndex = _currentIndex.clamp(0, _allChannels.length - 1);
    });
    _requestScreenFocus();
    _scrollToFocusedChannel();
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && !_showChannelList && !_hasError) {
        _hideControls();
      }
    });
  }

  void _resetHideTimer() {
    if (!mounted) return;
    setState(() {
      _showControls = true;
      _osdInteractive = false;
    });
    _startHideTimer();
    _requestScreenFocus();
  }

  void _refreshControlsAfterAction() {
    if (_showControls && _osdInteractive) {
      _startHideTimer();
    } else {
      _resetHideTimer();
    }
  }

  void _closeChannelList() {
    _showInteractiveControls();
  }

  void _requestScreenFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _screenFocusNode.canRequestFocus) {
        _screenFocusNode.requestFocus();
      }
    });
  }

  void _focusOsdDefault() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _showControls &&
          _osdInteractive &&
          !_showChannelList &&
          !_hasError &&
          _osdDefaultFocusNode.canRequestFocus) {
        _osdDefaultFocusNode.requestFocus();
      }
    });
  }

  void _focusErrorRetry() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _hasError && _errorRetryFocusNode.canRequestFocus) {
        _errorRetryFocusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Invalidate all delayed work before disposing the native player.
    _playbackSessionId++;
    _currentAttemptId++;
    _hideTimer?.cancel();
    _channelSwitchDebounce?.cancel();
    _bufferWatchdogTicker?.cancel();
    _reconnectTimer?.cancel();
    _stablePlaybackTimer?.cancel();
    _completedTimer?.cancel();
    _channelInfoTimer?.cancel();
    _bufferingSub?.cancel();
    _errorSub?.cancel();
    _completedSub?.cancel();
    _playingSub?.cancel();
    _player.dispose();
    _screenFocusNode.dispose();
    _osdFocusScopeNode.dispose();
    _osdDefaultFocusNode.dispose();
    _errorFocusScopeNode.dispose();
    _errorRetryFocusNode.dispose();
    _channelListScrollController.dispose();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    final isRepeat = event is KeyRepeatEvent;
    final repeatable =
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.channelUp ||
        key == LogicalKeyboardKey.channelDown ||
        key == LogicalKeyboardKey.mediaTrackNext ||
        key == LogicalKeyboardKey.mediaTrackPrevious;

    // A held OK/media key must never trigger the same action repeatedly.
    if (isRepeat && !repeatable) return KeyEventResult.handled;

    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      _player.state.playing ? _player.pause() : _player.play();
      _refreshControlsAfterAction();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.mediaStop) {
      // Mirror escape/goBack's staged close instead of exiting straight to
      // Home while the guide/OSD is still open.
      if (_showChannelList) {
        _closeChannelList();
      } else if (_showControls && _osdInteractive) {
        _hideControls();
      } else {
        Navigator.of(context).pop();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.channelUp ||
        key == LogicalKeyboardKey.mediaTrackNext) {
      _nextChannel();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.channelDown ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      _previousChannel();
      return KeyEventResult.handled;
    }

    if (_hasError) {
      if (_screenFocusNode.hasPrimaryFocus &&
          (key == LogicalKeyboardKey.select ||
              key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.gameButtonA)) {
        _retryManually();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.goBack) {
        return KeyEventResult.ignored;
      }
      // Retry/back are true focusable actions; let traversal reach both.
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.info ||
        key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.f4 ||
        key == LogicalKeyboardKey.keyE) {
      _cycleAspect();
      return KeyEventResult.handled;
    }

    if (_showChannelList) {
      if (key == LogicalKeyboardKey.arrowUp) {
        _moveChannelListFocus(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        _moveChannelListFocus(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.gameButtonA) {
        _switchToChannel(_focusedChannelIndex);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight ||
          key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.goBack) {
        _closeChannelList();
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    if (_showControls && _osdInteractive) {
      _startHideTimer();
      if (_screenFocusNode.hasPrimaryFocus &&
          (key == LogicalKeyboardKey.select ||
              key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.gameButtonA)) {
        _focusOsdDefault();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.goBack) {
        _hideControls();
        return KeyEventResult.handled;
      }
      // FocusTraversal handles the visible OSD's directional keys.
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA) {
      _showInteractiveControls();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      _previousChannel();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowDown) {
      _nextChannel();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowRight) {
      _openChannelList();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft) {
      _showInteractiveControls();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      return KeyEventResult.ignored;
    }

    return KeyEventResult.ignored;
  }

  void _moveChannelListFocus(int delta) {
    setState(() {
      _focusedChannelIndex = (_focusedChannelIndex + delta).clamp(
        0,
        _allChannels.length - 1,
      );
    });
    _scrollToFocusedChannel();
  }

  // ── Sidebar data builders ───────────────────────────────────────────────

  void _buildSidebarData() {
    _sidebarItems = [];
    _channelToItemIndex = {};
    int globalIndex = 0;

    for (final cat in _playbackCategories) {
      _sidebarItems.add(_SidebarItem.header(cat));
      for (final ch in cat.channels) {
        _channelToItemIndex[globalIndex] = _sidebarItems.length;
        _sidebarItems.add(_SidebarItem.channel(ch, globalIndex));
        globalIndex++;
      }
    }

    // Pre-compute cumulative offsets: header = 44 px, channel row = 62 px.
    _sidebarOffsets = List.filled(_sidebarItems.length + 1, 0.0);
    for (int i = 0; i < _sidebarItems.length; i++) {
      _sidebarOffsets[i + 1] =
          _sidebarOffsets[i] + (_sidebarItems[i].isHeader ? 44.0 : 62.0);
    }
  }

  void _scrollToFocusedChannel() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_channelListScrollController.hasClients) return;
      final itemIdx = _channelToItemIndex[_focusedChannelIndex];
      if (itemIdx == null) return;
      final viewportH = _channelListScrollController.position.viewportDimension;
      final target = (_sidebarOffsets[itemIdx] - viewportH / 2 + 31.0).clamp(
        0.0,
        _channelListScrollController.position.maxScrollExtent,
      );
      _channelListScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    });
  }

  Widget _buildSidebarHeader(ChannelCategory cat) {
    return SizedBox(
      height: 44,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                gradient: AppColors.redGradient,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(
                getCategoryIcon(cat.name),
                color: Colors.white,
                size: 14,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                cat.displayName,
                style: AppFonts.cairo(
                  color: AppColors.accentRedLight,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              '${cat.channels.length}',
              style: AppFonts.cairo(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebarChannel(Channel channel, int idx) {
    final isActive = idx == _currentIndex;
    final isFocused = idx == _focusedChannelIndex;
    return Semantics(
      button: true,
      selected: isActive,
      focused: isFocused,
      label: '${idx + 1}. ${channel.name}',
      child: SizedBox(
        height: 62,
        child: GestureDetector(
          onTap: () => _switchToChannel(idx),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: isFocused
                  ? AppColors.accentRed.withValues(alpha: 0.25)
                  : isActive
                  ? AppColors.accentRed.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: isFocused
                  ? Border.all(color: AppColors.accentRed, width: 1.5)
                  : isActive
                  ? Border.all(
                      color: AppColors.accentRed.withValues(alpha: 0.3),
                      width: 1,
                    )
                  : null,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: Text(
                    '${idx + 1}',
                    style: AppFonts.cairo(
                      color: isFocused ? Colors.white : Colors.white38,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: channel.logoUrl.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: channel.logoUrl,
                            fit: BoxFit.contain,
                            memCacheWidth: 72,
                            memCacheHeight: 72,
                            fadeInDuration: const Duration(milliseconds: 100),
                            errorWidget: (_, __, ___) => const Icon(
                              Icons.tv,
                              color: Colors.white38,
                              size: 16,
                            ),
                          )
                        : const Icon(Icons.tv, color: Colors.white38, size: 16),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    channel.name,
                    style: AppFonts.cairo(
                      color: isFocused || isActive
                          ? Colors.white
                          : Colors.white70,
                      fontSize: 13,
                      fontWeight: isFocused || isActive
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isActive)
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: AppColors.accentRed,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.accentRed.withValues(alpha: 0.5),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_showChannelList && !(_showControls && _osdInteractive),
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_showChannelList) {
          _closeChannelList();
        } else {
          _hideControls();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _screenFocusNode,
          autofocus: true,
          onKeyEvent: _handleKeyEvent,
          onFocusChange: (focused) {
            if (!focused &&
                mounted &&
                !_showChannelList &&
                !_hasError &&
                !(_showControls && _osdInteractive)) {
              _requestScreenFocus();
            }
          },
          child: GestureDetector(
            onTap: _hasError ? _retryManually : _toggleControls,
            child: Stack(
              children: [
                // Video player
                _buildVideoLayer(),

                // Buffering indicator
                if (_isBuffering && !_hasError)
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 50,
                          height: 50,
                          child: CircularProgressIndicator(
                            color: AppColors.accentRed,
                            strokeWidth: 3,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _retryCount > 0
                              ? 'إعادة الاتصال... ($_retryCount/$_maxRetries)'
                              : 'جاري التحميل...',
                          style: AppFonts.cairo(
                            color: Colors.white70,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                  ),

                // Controls overlay
                ExcludeFocus(
                  excluding:
                      !_showControls ||
                      !_osdInteractive ||
                      _showChannelList ||
                      _hasError,
                  child: AnimatedOpacity(
                    opacity: _showControls && !_hasError ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 150),
                    child: IgnorePointer(
                      ignoring: !_showControls || _hasError,
                      child: FocusScope(
                        node: _osdFocusScopeNode,
                        onFocusChange: (focused) {
                          if (focused && _osdInteractive) _startHideTimer();
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black.withValues(alpha: 0.7),
                                Colors.transparent,
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.8),
                              ],
                              stops: const [0.0, 0.3, 0.7, 1.0],
                            ),
                          ),
                          child: SafeArea(
                            minimum: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 12,
                            ),
                            child: Column(
                              children: [
                                _buildTopBar(),
                                const Spacer(),
                                _buildBottomBar(),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // Remote control hints — Positioned wraps IgnorePointer (not vice versa)
                if (_showControls && !_showChannelList && !_hasError)
                  Positioned(
                    bottom: 80,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _osdInteractive
                                ? _buildHintChip(
                                    Icons.open_with_rounded,
                                    'الأسهم للتنقّل',
                                  )
                                : _buildHintChip(Icons.arrow_upward, 'السابقة'),
                            const SizedBox(width: 10),
                            _osdInteractive
                                ? _buildHintChip(
                                    Icons.radio_button_checked,
                                    'OK للاختيار',
                                  )
                                : _buildHintChip(
                                    Icons.arrow_downward,
                                    'التالية',
                                  ),
                            const SizedBox(width: 10),
                            _osdInteractive
                                ? _buildHintChip(
                                    Icons.keyboard_return,
                                    'رجوع للإخفاء',
                                  )
                                : _buildHintChip(
                                    Icons.arrow_forward,
                                    'القائمة',
                                  ),
                          ],
                        ),
                      ),
                    ),
                  ),

                // Channel info mini-banner (3 sec after D-pad switch, when OSD hidden)
                if (_showChannelInfo && !_hasError)
                  Positioned(
                    bottom: _showControls ? 88 : 24,
                    left: 32,
                    child: _buildChannelInfoBanner(),
                  ),

                // Channel list overlay
                if (_showChannelList) _buildChannelListOverlay(),

                // Keep the terminal error above every interactive overlay.
                if (_hasError) _buildErrorOverlay(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVideoLayer() {
    return SizedBox.expand(
      child: Video(
        controller: _videoController,
        controls: NoVideoControls,
        fit: _aspectMode == 0 ? BoxFit.contain : BoxFit.cover,
      ),
    );
  }

  Widget _buildChannelInfoBanner() {
    return Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.48,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.80),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.accentRed.withValues(alpha: 0.35),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.accentRed,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '${_currentIndex + 1}',
              style: AppFonts.cairo(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 10),
          if (_currentChannel.logoUrl.isNotEmpty)
            Container(
              width: 32,
              height: 32,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(6),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: CachedNetworkImage(
                  imageUrl: _currentChannel.logoUrl,
                  fit: BoxFit.contain,
                  errorWidget: (_, __, ___) => const SizedBox(),
                ),
              ),
            ),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _currentChannel.name,
                  style: AppFonts.cairo(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (_currentChannel.group.isNotEmpty)
                  Text(
                    _currentChannel.group,
                    style: AppFonts.cairo(color: Colors.white60, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorOverlay() {
    return FocusScope(
      node: _errorFocusScopeNode,
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 520),
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: AppColors.accentRed.withValues(alpha: 0.4),
              width: 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.signal_wifi_bad,
                color: AppColors.accentRed,
                size: 52,
              ),
              const SizedBox(height: 14),
              Text(
                'تعذّر تشغيل القناة',
                style: AppFonts.cairo(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _currentChannel.name,
                style: AppFonts.cairo(color: Colors.white54, fontSize: 13),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildActionButton(
                    icon: Icons.refresh,
                    label: 'إعادة المحاولة',
                    onTap: _retryManually,
                    primary: true,
                    focusNode: _errorRetryFocusNode,
                  ),
                  const SizedBox(width: 12),
                  _buildActionButton(
                    icon: Icons.arrow_back,
                    label: 'رجوع',
                    onTap: () => Navigator.of(context).pop(),
                    primary: false,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'اضغط OK للمحاولة مجدداً',
                style: AppFonts.cairo(color: Colors.white30, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required bool primary,
    FocusNode? focusNode,
  }) {
    return _ActionButton(
      icon: icon,
      label: label,
      onTap: onTap,
      primary: primary,
      focusNode: focusNode,
    );
  }

  Widget _buildHintChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white54, size: 14),
          const SizedBox(width: 4),
          Text(
            label,
            style: AppFonts.cairo(color: Colors.white54, fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          _ControlButton(
            icon: Icons.arrow_back_rounded,
            onTap: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 12),
          if (_currentChannel.logoUrl.isNotEmpty)
            Container(
              width: 38,
              height: 38,
              margin: const EdgeInsets.only(right: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: _currentChannel.logoUrl,
                  fit: BoxFit.contain,
                  errorWidget: (_, __, ___) => const SizedBox(),
                ),
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _currentChannel.name,
                  style: AppFonts.cairo(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _currentChannel.group,
                  style: AppFonts.cairo(color: Colors.white60, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          _ControlButton(
            icon: _favoriteUrls.contains(_currentChannel.url)
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            onTap: () => _toggleFavorite(),
            highlighted: _favoriteUrls.contains(_currentChannel.url),
          ),
          const SizedBox(width: 8),
          ExcludeFocus(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                gradient: AppColors.redGradient,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.circle, color: Colors.white, size: 8),
                  const SizedBox(width: 4),
                  Text(
                    'LIVE',
                    style: AppFonts.cairo(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _cycleAspect() {
    setState(() => _aspectMode = (_aspectMode + 1) % _aspectLabels.length);
    unawaited(_persistAspectMode());
    _refreshControlsAfterAction();
  }

  Future<void> _persistAspectMode() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(_aspectModeKey, _aspectMode);
  }

  Widget _buildBottomBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _ControlButton(
            icon: Icons.skip_previous_rounded,
            onTap: _currentIndex > 0 ? _previousChannel : null,
            size: 32,
          ),
          const SizedBox(width: 16),
          _ControlButton(
            icon: Icons.list_rounded,
            focusNode: _osdDefaultFocusNode,
            onTap: _openChannelList,
            size: 28,
            highlighted: _showChannelList,
          ),
          const SizedBox(width: 16),
          // Aspect ratio cycle button
          _AspectButton(
            icon: _aspectIcons[_aspectMode],
            label: _aspectLabels[_aspectMode],
            onTap: _cycleAspect,
          ),
          const SizedBox(width: 16),
          _ControlButton(
            icon: Icons.skip_next_rounded,
            onTap: _currentIndex < _allChannels.length - 1
                ? _nextChannel
                : null,
            size: 32,
          ),
        ],
      ),
    );
  }

  Widget _buildChannelListOverlay() {
    return Positioned(
      right: 24,
      top: 20,
      bottom: 20,
      width: 340,
      child: GestureDetector(
        onTap: () {},
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.primaryDark.withValues(alpha: 0.96),
              border: Border.all(
                color: AppColors.accentRed.withValues(alpha: 0.3),
                width: 1,
              ),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.live_tv,
                        color: AppColors.accentRed,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'القنوات',
                        style: AppFonts.cairo(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${_allChannels.length}',
                          style: AppFonts.cairo(
                            color: AppColors.accentRedLight,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _ControlButton(
                        icon: Icons.close,
                        onTap: _closeChannelList,
                        size: 16,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: _channelListScrollController,
                    physics: const ClampingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    // ignore: deprecated_member_use
                    cacheExtent: 620,
                    itemCount: _sidebarItems.length,
                    itemBuilder: (_, index) {
                      final item = _sidebarItems[index];
                      return item.isHeader
                          ? _buildSidebarHeader(item.category!)
                          : _buildSidebarChannel(
                              item.channel!,
                              item.globalIndex!,
                            );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Sidebar item model ──────────────────────────────────────────────────────

class _SidebarItem {
  final bool isHeader;
  final ChannelCategory? category;
  final Channel? channel;
  final int? globalIndex;

  const _SidebarItem.header(this.category)
    : isHeader = true,
      channel = null,
      globalIndex = null;

  const _SidebarItem.channel(this.channel, this.globalIndex)
    : isHeader = false,
      category = null;
}

class _AspectButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _AspectButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  State<_AspectButton> createState() => _AspectButtonState();
}

class _AspectButtonState extends State<_AspectButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _isFocused = f),
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _isFocused
                ? AppColors.accentRed.withValues(alpha: 0.3)
                : Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _isFocused
                  ? AppColors.accentRed.withValues(alpha: 0.7)
                  : Colors.transparent,
              width: _isFocused ? 2 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.icon,
                color: _isFocused ? Colors.white : Colors.white70,
                size: 18,
              ),
              const SizedBox(width: 5),
              Text(
                widget.label,
                style: AppFonts.cairo(
                  color: _isFocused ? Colors.white : Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ControlButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final bool highlighted;
  final FocusNode? focusNode;

  const _ControlButton({
    required this.icon,
    this.onTap,
    this.size = 24,
    this.highlighted = false,
    this.focusNode,
  });

  @override
  State<_ControlButton> createState() => _ControlButtonState();
}

class _ControlButtonState extends State<_ControlButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final isActive = widget.highlighted || _isFocused;
    return Semantics(
      button: true,
      enabled: widget.onTap != null,
      child: Focus(
        focusNode: widget.focusNode,
        canRequestFocus: widget.onTap != null,
        skipTraversal: widget.onTap == null,
        onFocusChange: (focused) => setState(() => _isFocused = focused),
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.select ||
                  event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
            widget.onTap?.call();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: widget.size + 20,
            height: widget.size + 20,
            decoration: BoxDecoration(
              color: isActive
                  ? AppColors.accentRed.withValues(alpha: 0.3)
                  : Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isActive
                    ? AppColors.accentRed.withValues(alpha: 0.7)
                    : Colors.transparent,
                width: _isFocused ? 2 : 1,
              ),
              boxShadow: _isFocused
                  ? [
                      BoxShadow(
                        color: AppColors.accentRed.withValues(alpha: 0.4),
                        blurRadius: 10,
                      ),
                    ]
                  : [],
            ),
            child: Icon(
              widget.icon,
              color: widget.onTap != null
                  ? (_isFocused ? Colors.white : Colors.white70)
                  : Colors.white30,
              size: widget.size,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Error overlay action button ─────────────────────────────────────────────

class _ActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;
  final FocusNode? focusNode;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.primary,
    this.focusNode,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.label,
      child: Focus(
        focusNode: widget.focusNode,
        onFocusChange: (f) => setState(() => _isFocused = f),
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.select ||
                  event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
            widget.onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              gradient: widget.primary ? AppColors.redGradient : null,
              color: widget.primary
                  ? null
                  : _isFocused
                  ? Colors.white.withValues(alpha: 0.2)
                  : Colors.white.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _isFocused
                    ? AppColors.accentRedLight
                    : widget.primary
                    ? Colors.transparent
                    : Colors.white.withValues(alpha: 0.2),
                width: _isFocused ? 2 : 1,
              ),
              boxShadow: _isFocused
                  ? [
                      BoxShadow(
                        color: AppColors.accentRed.withValues(alpha: 0.5),
                        blurRadius: 14,
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, color: Colors.white, size: 16),
                const SizedBox(width: 6),
                Text(
                  widget.label,
                  style: AppFonts.cairo(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
