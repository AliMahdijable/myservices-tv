import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/channel.dart';
import '../player/live_playback_controller.dart';
import '../player/playback_preferences.dart';
import '../player/stream_failure.dart';
import '../widgets/player_settings_panel.dart';
import '../theme/app_theme.dart';
import '../utils/category_helpers.dart';
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

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  final LivePlaybackController _playback = LivePlaybackController();
  late Channel _currentChannel;
  late List<ChannelCategory> _playbackCategories;
  late List<Channel> _allChannels;
  int _currentIndex = 0;

  /// Set by the first real key press. Distinguishes a device someone is
  /// driving with a remote from one they are touching.
  bool _sawKeyEvent = false;

  bool _showControls = true;
  bool _showChannelList = false;
  bool _showSettings = false;
  int _focusedSettingRow = 0;
  bool _osdInteractive = true;

  /// Mirrors [LivePlaybackController.state] so build methods read plain
  /// fields. The controller owns every rule behind these values.
  PlaybackUiState _playbackState = const PlaybackUiState();

  bool get _isBuffering => _playbackState.isBuffering;
  bool get _hasError => _playbackState.hasFatalError;

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
  Timer? _settingApplyDebounce;

  Set<String> _favoriteKeys = {};
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

    _playback.state.addListener(_onPlaybackStateChanged);

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

  void _onPlaybackStateChanged() {
    if (!mounted) return;
    final next = _playback.state.value;
    final becameFatal = next.hasFatalError && !_playbackState.hasFatalError;
    setState(() => _playbackState = next);

    if (becameFatal) {
      // The terminal error owns the screen: hide the OSD and the guide so the
      // retry button is what the remote lands on.
      _hideTimer?.cancel();
      setState(() {
        _showControls = false;
        _showChannelList = false;
        // Left set, this kept PopScope.canPop false and cost two extra silent
        // Back presses to leave an error screen whose OSD is already invisible.
        _showSettings = false;
      });
      _focusErrorRetry();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _playback.onAppBackgrounded();
        break;
      case AppLifecycleState.resumed:
        _playback.onAppResumed();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _initializePlayback() async {
    // Native properties must be applied before the first stream opens.
    await _playback.initialize();
    if (!mounted) return;
    await _playChannel(_currentChannel);
  }

  Future<void> _loadFavorites() async {
    final keys = await FavoritesService.getFavoriteKeys();
    if (mounted) setState(() => _favoriteKeys = keys);
  }

  void _showChannelInfoBriefly() {
    setState(() => _showChannelInfo = true);
    _channelInfoTimer?.cancel();
    _channelInfoTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showChannelInfo = false);
    });
  }

  bool get _isCurrentFavorite =>
      FavoritesService.isFavorite(_currentChannel, _favoriteKeys);

  Future<void> _toggleFavorite() async {
    await FavoritesService.toggleFavorite(_currentChannel);
    // Re-read rather than patching the set locally: toggling also clears any
    // legacy URL duplicate, so the stored list is the only source of truth.
    if (mounted) await _loadFavorites();
  }

  Future<void> _playChannel(Channel channel) async {
    _channelSwitchDebounce?.cancel();
    setState(() => _currentChannel = channel);

    unawaited(RecentlyWatchedService.addChannel(channel));

    await _playback.play(channel);
  }

  void _retryManually() {
    unawaited(_playback.retry());
    _requestScreenFocus();
  }

  void _playChannelDebounced(Channel channel) {
    _channelSwitchDebounce?.cancel();
    // Invalidate callbacks from the old stream straight away, so a failure it
    // reports while D-pad input is still being debounced cannot reconnect the
    // channel the user has already moved past.
    _playback.beginPendingSwitch(channel);
    setState(() => _currentChannel = channel);
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
      _showSettings = false;
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
      _showSettings = false;
      _osdInteractive = false;
    });
    _requestScreenFocus();
  }

  void _openSettings() {
    _hideTimer?.cancel();
    setState(() {
      _showControls = true;
      _showChannelList = false;
      _showSettings = true;
      _osdInteractive = false;
      _focusedSettingRow = 0;
    });
    _requestScreenFocus();
  }

  void _closeSettings() {
    setState(() => _showSettings = false);
    _showInteractiveControls();
  }

  void _moveSettingsFocus(int delta) {
    final rowCount = PlayerSettingsPanel.rowsFor(
      aspectMode: _aspectMode,
    ).length;
    setState(() {
      _focusedSettingRow = (_focusedSettingRow + delta).clamp(0, rowCount - 1);
    });
  }

  /// Steps the focused setting by [delta], wrapping around its options.
  ///
  /// The new value is shown immediately, but reopening the stream is deferred:
  /// arrow keys auto-repeat on a TV remote, and applying on every repeat would
  /// fire a stop()+open() per tick — a burst of opens against one account,
  /// which is the most reliable way to self-inflict the 403 the recovery
  /// policy exists to avoid. Channel switching is debounced for the same
  /// reason; this path is strictly more expensive per keypress.
  Future<void> _adjustSetting(int delta) async {
    final current = switch (_focusedSettingRow) {
      0 => PlaybackPreferences.decoderMode.index,
      1 => PlaybackPreferences.bufferProfile.index,
      _ => _aspectMode,
    };
    final length = switch (_focusedSettingRow) {
      0 => DecoderMode.values.length,
      1 => BufferProfile.values.length,
      _ => _aspectLabels.length,
    };
    await _applySetting(_focusedSettingRow, _cycle(current, delta, length));
  }

  /// Selects an exact option. Both the D-pad (via [_adjustSetting]) and a
  /// direct tap on a chip land here, so the two input paths cannot drift.
  Future<void> _applySetting(int rowIndex, int optionIndex) async {
    switch (rowIndex) {
      case 0:
        await PlaybackPreferences.setDecoderMode(
          DecoderMode.values[optionIndex],
        );
        if (!mounted) return;
        setState(() {});
        _scheduleSettingApply();

      case 1:
        await PlaybackPreferences.setBufferProfile(
          BufferProfile.values[optionIndex],
        );
        if (!mounted) return;
        setState(() {});
        _scheduleSettingApply();

      case 2:
        // Aspect is a pure render change — no reopen, so no debounce needed.
        setState(() => _aspectMode = optionIndex);
        unawaited(_persistAspectMode());
    }
  }

  /// Keeps the D-pad's row highlight in step with a chip the user tapped.
  void _onSettingTapped(int rowIndex, int optionIndex) {
    setState(() => _focusedSettingRow = rowIndex);
    _hideTimer?.cancel();
    unawaited(_applySetting(rowIndex, optionIndex));
  }

  void _scheduleSettingApply() {
    _settingApplyDebounce?.cancel();
    _settingApplyDebounce = Timer(const Duration(milliseconds: 600), () {
      if (mounted) unawaited(_playback.applyPreferenceChanges());
    });
  }

  static int _cycle(int current, int delta, int length) =>
      (current + delta + length) % length;

  void _openChannelList() {
    if (_allChannels.isEmpty) return;
    _hideTimer?.cancel();
    setState(() {
      _showControls = true;
      _showChannelList = true;
      _showSettings = false;
      _osdInteractive = false;
      _focusedChannelIndex = _currentIndex.clamp(0, _allChannels.length - 1);
    });
    _requestScreenFocus();
    _scrollToFocusedChannel();
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && !_showChannelList && !_showSettings && !_hasError) {
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
          !_showSettings &&
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
    _hideTimer?.cancel();
    _channelSwitchDebounce?.cancel();
    _settingApplyDebounce?.cancel();
    _channelInfoTimer?.cancel();
    // The controller invalidates its own delayed work before tearing down the
    // native player, so it must stop being observed first.
    _playback.state.removeListener(_onPlaybackStateChanged);
    unawaited(_playback.dispose());
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
    if (!_sawKeyEvent) {
      // Deferred: this runs during key dispatch, where setState is unsafe.
      _sawKeyEvent = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
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
      _playback.togglePlayPause();
      _refreshControlsAfterAction();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.mediaStop) {
      // Mirror escape/goBack's staged close instead of exiting straight to
      // Home while the guide/OSD is still open.
      if (_showSettings) {
        _closeSettings();
      } else if (_showChannelList) {
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

    if (_showSettings) {
      if (key == LogicalKeyboardKey.arrowUp) {
        _moveSettingsFocus(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        _moveSettingsFocus(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight ||
          key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.gameButtonA) {
        unawaited(_adjustSetting(1));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        unawaited(_adjustSetting(-1));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.goBack) {
        _closeSettings();
        return KeyEventResult.handled;
      }
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
      canPop:
          !_showChannelList &&
          !_showSettings &&
          !(_showControls && _osdInteractive),
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_showSettings) {
          _closeSettings();
        } else if (_showChannelList) {
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
                !_showSettings &&
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
                          _loadingMessage,
                          style: AppFonts.cairo(
                            color: Colors.white70,
                            fontSize: 15,
                          ),
                          textAlign: TextAlign.center,
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
                      _showSettings ||
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
                                // Hints sit inside the same column as the
                                // controls instead of floating at a fixed
                                // offset. Pinned at bottom:80 they landed on
                                // top of the control cluster on a landscape
                                // phone, whose usable height is only ~390px.
                                _buildRemoteHints(),
                                _buildBottomBar(),
                              ],
                            ),
                          ),
                        ),
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

                // Playback settings overlay
                if (_showSettings)
                  PlayerSettingsPanel(
                    rows: PlayerSettingsPanel.rowsFor(aspectMode: _aspectMode),
                    focusedRow: _focusedSettingRow,
                    onSelect: _onSettingTapped,
                  ),

                // Keep the terminal error above every interactive overlay.
                if (_hasError) _buildErrorOverlay(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// What the loading spinner says, so a silent retry reads as plain loading
  /// while a real reconnect shows its progress and a network drop says so.
  String get _loadingMessage {
    if (_playbackState.waitingForNetwork) {
      return 'في انتظار عودة الاتصال…';
    }
    if (_playbackState.isReconnecting && _playbackState.maxAttempts > 0) {
      return 'إعادة الاتصال… '
          '(${_playbackState.attempt}/${_playbackState.maxAttempts})';
    }
    return 'جاري التحميل...';
  }

  Widget _buildVideoLayer() {
    return SizedBox.expand(
      child: Video(
        controller: _playback.videoController,
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

  StreamFailureKind get _errorKind =>
      _playbackState.fatalError ?? StreamFailureKind.unknown;

  IconData get _errorIcon => switch (_errorKind) {
    StreamFailureKind.offline => Icons.wifi_off_rounded,
    StreamFailureKind.serverBusy => Icons.groups_rounded,
    StreamFailureKind.unauthorized => Icons.key_off_rounded,
    StreamFailureKind.notFound => Icons.tv_off_rounded,
    StreamFailureKind.serverError => Icons.dns_rounded,
    StreamFailureKind.unreachable => Icons.cloud_off_rounded,
    StreamFailureKind.playback => Icons.broken_image_rounded,
    StreamFailureKind.unknown => Icons.signal_wifi_bad,
  };

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
              Icon(_errorIcon, color: AppColors.accentRed, size: 52),
              const SizedBox(height: 14),
              Text(
                _errorKind.title,
                style: AppFonts.cairo(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              // Saying *why* the stream stopped is the difference between a
              // user retrying pointlessly and one who closes another device or
              // fixes their credentials.
              Text(
                _errorKind.guidance,
                style: AppFonts.cairo(
                  color: Colors.white70,
                  fontSize: 13,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                _currentChannel.name,
                style: AppFonts.cairo(color: Colors.white38, fontSize: 12),
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
                _errorKind.isRetryable
                    ? 'اضغط OK للمحاولة مجدداً'
                    : 'جرّب قناة أخرى أو راجع الإعدادات',
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

  /// Whether this device is driven by a remote rather than a finger.
  ///
  /// The hints explain D-pad keys, which is pure noise on a touch phone where
  /// there are no arrows to press — and on a landscape phone they also had
  /// nowhere to go without colliding with the controls.
  ///
  /// Two signals, either of which is sufficient: a TV-sized screen (the same
  /// 600px shortest-side threshold the setup screen already uses to choose
  /// between the on-screen keyboard and the system one), or an actual key
  /// event, which a finger never produces but any paired remote does.
  bool get _isRemoteDriven {
    if (_sawKeyEvent) return true;
    final size = MediaQuery.sizeOf(context);
    return size.shortestSide >= 600 && size.height >= 420;
  }

  Widget _buildRemoteHints() {
    if (!_isRemoteDriven || _showChannelList || _showSettings || _hasError) {
      return const SizedBox.shrink();
    }
    final hints = _osdInteractive
        ? const [
            (Icons.open_with_rounded, 'الأسهم للتنقّل'),
            (Icons.radio_button_checked, 'OK للاختيار'),
            (Icons.keyboard_return, 'رجوع للإخفاء'),
          ]
        : const [
            (Icons.arrow_upward, 'السابقة'),
            (Icons.arrow_downward, 'التالية'),
            (Icons.arrow_forward, 'القائمة'),
          ];
    return IgnorePointer(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 10,
          runSpacing: 6,
          children: [
            for (final (icon, label) in hints) _buildHintChip(icon, label),
          ],
        ),
      ),
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
            icon: _isCurrentFavorite
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            onTap: () => _toggleFavorite(),
            highlighted: _isCurrentFavorite,
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
      // The control cluster is sized for a TV. On a phone held in landscape
      // the same buttons exceed the width, so shrink them to fit rather than
      // clipping the outermost control off the screen.
      child: FittedBox(
        fit: BoxFit.scaleDown,
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
              icon: Icons.tune_rounded,
              onTap: _openSettings,
              size: 28,
              highlighted: _showSettings,
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
