import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/channel.dart';
import '../theme/app_theme.dart';
import '../utils/category_helpers.dart';

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

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player;
  late final VideoController _videoController;
  late Channel _currentChannel;
  late List<Channel> _allChannels;
  int _currentIndex = 0;

  bool _showControls = true;
  bool _showChannelList = false;
  bool _isBuffering = true;
  bool _hasError = false;
  int _retryCount = 0;
  static const int _maxRetries = 5;
  static const String _lastChannelKey = 'last_channel_index';

  // 0 = letterbox (panscan=0), 1 = zoom/fill (panscan=1)
  int _aspectMode = 0;
  static const List<IconData> _aspectIcons  = [Icons.fit_screen_rounded, Icons.crop_free_rounded];
  static const List<String>   _aspectLabels = ['ملاءمة', 'ملء'];

  Timer? _hideTimer;
  Timer? _channelSwitchDebounce;
  Timer? _bufferTimeoutTimer;
  Timer? _reconnectTimer;

  final FocusNode _screenFocusNode = FocusNode();
  final FocusNode _channelListFocusNode = FocusNode();
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
    _currentChannel = widget.channel;

    _allChannels = widget.categories.expand((c) => c.channels).toList();
    _currentIndex = _allChannels.indexOf(widget.channel);
    if (_currentIndex < 0) _currentIndex = 0;
    _focusedChannelIndex = _currentIndex;
    _buildSidebarData();

    _player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 32 * 1024 * 1024,
      ),
    );
    _videoController = VideoController(_player);

    _setupPlayerListeners();
    _configureMpv();

    WakelockPlus.enable();

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _playChannel(_currentChannel);
    _startHideTimer();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _screenFocusNode.requestFocus();
    });
  }

  Future<void> _configureMpv() async {
    try {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('network-timeout',         '20');
        await platform.setProperty('demuxer-readahead-secs',  '30');
        await platform.setProperty('demuxer-max-bytes',       '50MiB');
        await platform.setProperty('demuxer-max-back-bytes',  '25MiB');
        await platform.setProperty('cache',                   'yes');
        await platform.setProperty('cache-secs',              '60');
        await platform.setProperty('stream-buffer-size',      '1MiB');
        await platform.setProperty('hls-bitrate',             'max');
      }
    } catch (_) {}
  }

  void _setupPlayerListeners() {
    _bufferingSub = _player.stream.buffering.listen((buffering) {
      if (!mounted) return;
      setState(() => _isBuffering = buffering);
      if (buffering) {
        _startBufferTimeoutTimer();
      } else {
        _bufferTimeoutTimer?.cancel();
        // Successful playback — reset retry counter and clear error
        if (_retryCount > 0) _retryCount = 0;
        if (_hasError) setState(() => _hasError = false);
      }
      // Always keep focus so remote control stays responsive
      _screenFocusNode.requestFocus();
    });

    _errorSub = _player.stream.error.listen((_) {
      if (mounted) _handleStreamError();
    });

    // For live IPTV, "completed" can fire on HLS segment boundaries — debounce
    _completedSub = _player.stream.completed.listen((completed) {
      if (!completed || !mounted) return;
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted && _player.state.completed) _handleStreamError();
      });
    });

    _playingSub = _player.stream.playing.listen((_) {
      // Keep focus alive whenever playback state changes
      if (mounted) _screenFocusNode.requestFocus();
    });
  }

  void _startBufferTimeoutTimer() {
    _bufferTimeoutTimer?.cancel();
    _bufferTimeoutTimer = Timer(const Duration(seconds: 35), () {
      if (mounted && _isBuffering) _handleStreamError();
    });
  }

  void _handleStreamError() {
    _bufferTimeoutTimer?.cancel();
    _reconnectTimer?.cancel();

    if (!mounted) return;

    if (_retryCount >= _maxRetries) {
      setState(() {
        _hasError = true;
        _isBuffering = false;
      });
      _screenFocusNode.requestFocus();
      return;
    }

    _retryCount++;
    // Exponential backoff: 2s, 4s, 6s, 8s, 8s (capped)
    final delay = Duration(seconds: min(_retryCount * 2, 8));

    setState(() {
      _isBuffering = true;
      _hasError = false;
    });

    _reconnectTimer = Timer(delay, () {
      if (mounted) _doPlayChannel(_currentChannel);
    });
  }

  Future<void> _playChannel(Channel channel) async {
    _bufferTimeoutTimer?.cancel();
    _reconnectTimer?.cancel();
    _retryCount = 0;

    setState(() {
      _currentChannel = channel;
      _isBuffering = true;
      _hasError = false;
    });

    // Persist last played channel for next session
    SharedPreferences.getInstance().then(
      (p) => p.setInt(_lastChannelKey, _currentIndex),
    );

    await _doPlayChannel(channel);
  }

  Future<void> _doPlayChannel(Channel channel) async {
    // After 2 consecutive failures, try alternate format (.m3u8 ↔ .ts)
    final url = (_retryCount >= 2 && _retryCount < _maxRetries)
        ? _alternateUrl(channel.url)
        : channel.url;
    try {
      await _player.open(
        Media(url, httpHeaders: const {'User-Agent': 'Mozilla/5.0 IPTV Player'}),
      );
      _applyAspectMode();
      if (mounted) _screenFocusNode.requestFocus();
    } catch (_) {
      if (mounted) _handleStreamError();
    }
  }

  String _alternateUrl(String url) {
    if (url.endsWith('.m3u8')) return '${url.substring(0, url.length - 5)}.ts';
    if (url.endsWith('.ts'))   return '${url.substring(0, url.length - 3)}.m3u8';
    return url;
  }

  void _retryManually() {
    _retryCount = 0;
    setState(() {
      _hasError = false;
      _isBuffering = true;
    });
    _doPlayChannel(_currentChannel);
  }

  void _playChannelDebounced(Channel channel) {
    _channelSwitchDebounce?.cancel();
    setState(() {
      _currentChannel = channel;
      _isBuffering = true;
      _hasError = false;
    });
    _channelSwitchDebounce = Timer(const Duration(milliseconds: 300), () {
      _playChannel(channel);
    });
  }

  void _nextChannel() {
    if (_currentIndex < _allChannels.length - 1) {
      _currentIndex++;
      _focusedChannelIndex = _currentIndex;
      _playChannelDebounced(_allChannels[_currentIndex]);
      _resetHideTimer();
    }
  }

  void _previousChannel() {
    if (_currentIndex > 0) {
      _currentIndex--;
      _focusedChannelIndex = _currentIndex;
      _playChannelDebounced(_allChannels[_currentIndex]);
      _resetHideTimer();
    }
  }

  void _switchToChannel(int globalIndex) {
    _currentIndex = globalIndex;
    _focusedChannelIndex = globalIndex;
    _playChannel(_allChannels[globalIndex]);
    setState(() => _showChannelList = false);
    _screenFocusNode.requestFocus();
    _resetHideTimer();
  }

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
      if (!_showControls) _showChannelList = false;
    });
    if (_showControls) {
      _startHideTimer();
    } else {
      _hideTimer?.cancel();
    }
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && !_showChannelList) {
        setState(() => _showControls = false);
      }
    });
  }

  void _resetHideTimer() {
    setState(() => _showControls = true);
    _startHideTimer();
  }

  void _closeChannelList() {
    setState(() => _showChannelList = false);
    _screenFocusNode.requestFocus();
    _resetHideTimer();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _channelSwitchDebounce?.cancel();
    _bufferTimeoutTimer?.cancel();
    _reconnectTimer?.cancel();
    _bufferingSub?.cancel();
    _errorSub?.cancel();
    _completedSub?.cancel();
    _playingSub?.cancel();
    _player.dispose();
    _screenFocusNode.dispose();
    _channelListFocusNode.dispose();
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

    // Any key press on error state retries
    if (_hasError) {
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.gameButtonA) {
        _retryManually();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.goBack) {
        return KeyEventResult.ignored;
      }
      // Arrow keys for channel navigation still work in error state
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
      if (key == LogicalKeyboardKey.arrowLeft) {
        _closeChannelList();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.goBack) {
        _closeChannelList();
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA) {
      _toggleControls();
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
      setState(() {
        _showControls = true;
        _showChannelList = true;
        _focusedChannelIndex = _currentIndex;
      });
      _hideTimer?.cancel();
      _scrollToFocusedChannel();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft) {
      if (_showChannelList) {
        setState(() => _showChannelList = false);
      } else {
        _resetHideTimer();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack) {
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      _player.state.playing ? _player.pause() : _player.play();
      _resetHideTimer();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.mediaStop) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }

    // Aspect ratio toggle — Info/ContextMenu/F4 on remote or keyboard
    if (key == LogicalKeyboardKey.info ||
        key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.f4 ||
        key == LogicalKeyboardKey.keyE) {
      _cycleAspect();
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

    return KeyEventResult.ignored;
  }

  void _moveChannelListFocus(int delta) {
    setState(() {
      _focusedChannelIndex =
          (_focusedChannelIndex + delta).clamp(0, _allChannels.length - 1);
    });
    _scrollToFocusedChannel();
  }

  // ── Sidebar data builders ───────────────────────────────────────────────

  void _buildSidebarData() {
    _sidebarItems       = [];
    _channelToItemIndex = {};
    int globalIndex     = 0;

    for (final cat in widget.categories) {
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
      final viewportH =
          _channelListScrollController.position.viewportDimension;
      final target = (_sidebarOffsets[itemIdx] - viewportH / 2 + 31.0)
          .clamp(0.0, _channelListScrollController.position.maxScrollExtent);
      _channelListScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    });
  }

  Widget _buildSidebarHeader(ChannelCategory cat) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      margin: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              gradient: AppColors.redGradient,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(getCategoryIcon(cat.name),
                color: Colors.white, size: 14),
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
            ),
          ),
          Text('${cat.channels.length}',
              style: AppFonts.cairo(color: Colors.white38, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildSidebarChannel(Channel channel, int idx) {
    final isActive  = idx == _currentIndex;
    final isFocused = idx == _focusedChannelIndex;
    return GestureDetector(
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
                      width: 1)
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
                        errorWidget: (_, __, ___) => const Icon(
                            Icons.tv, color: Colors.white38, size: 16),
                      )
                    : const Icon(Icons.tv, color: Colors.white38, size: 16),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                channel.name,
                style: AppFonts.cairo(
                  color:
                      isFocused || isActive ? Colors.white : Colors.white70,
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
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_showChannelList,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _closeChannelList();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _screenFocusNode,
          autofocus: true,
          onKeyEvent: _handleKeyEvent,
          onFocusChange: (focused) {
            // Re-grab focus if lost while not showing channel list
            if (!focused && mounted && !_showChannelList) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _screenFocusNode.requestFocus();
              });
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

                // Error state — shown when all retries exhausted
                if (_hasError) _buildErrorOverlay(),

                // Controls overlay
                AnimatedOpacity(
                  opacity: _showControls ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 150),
                  child: IgnorePointer(
                    ignoring: !_showControls,
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
                            _buildHintChip(Icons.arrow_upward, 'السابقة'),
                            const SizedBox(width: 10),
                            _buildHintChip(Icons.arrow_downward, 'التالية'),
                            const SizedBox(width: 10),
                            _buildHintChip(Icons.arrow_forward, 'القائمة'),
                          ],
                        ),
                      ),
                    ),
                  ),

                // Channel list overlay
                if (_showChannelList) _buildChannelListOverlay(),
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
        key: ValueKey(_aspectMode),
        controller: _videoController,
        controls: NoVideoControls,
        fit: _aspectMode == 0 ? BoxFit.contain : BoxFit.cover,
      ),
    );
  }

  void _applyAspectMode() {}

  Widget _buildErrorOverlay() {
    return Center(
      child: Container(
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
            const Icon(Icons.signal_wifi_bad,
                color: AppColors.accentRed, size: 52),
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
              style: AppFonts.cairo(
                color: Colors.white54,
                fontSize: 13,
              ),
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
              style: AppFonts.cairo(
                color: Colors.white30,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required bool primary,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          gradient: primary ? AppColors.redGradient : null,
          color: primary ? null : Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: primary
                ? Colors.transparent
                : Colors.white.withValues(alpha: 0.2),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 16),
            const SizedBox(width: 6),
            Text(
              label,
              style: AppFonts.cairo(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
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
                  style: AppFonts.cairo(
                    color: Colors.white60,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          Container(
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
        ],
      ),
    );
  }

  void _cycleAspect() {
    setState(() => _aspectMode = (_aspectMode + 1) % _aspectLabels.length);
    _applyAspectMode();
    _resetHideTimer();
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
            onTap: () {
              setState(() {
                _showChannelList = !_showChannelList;
                _focusedChannelIndex = _currentIndex;
              });
              _hideTimer?.cancel();
              if (_showChannelList) _scrollToFocusedChannel();
            },
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
            onTap:
                _currentIndex < _allChannels.length - 1 ? _nextChannel : null,
            size: 32,
          ),
        ],
      ),
    );
  }

  Widget _buildChannelListOverlay() {
    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      width: 300,
      child: GestureDetector(
        onTap: () {},
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.primaryDark.withValues(alpha: 0.95),
            border: Border(
              left: BorderSide(
                color: AppColors.accentRed.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
          ),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.live_tv,
                        color: AppColors.accentRed, size: 20),
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
                          horizontal: 8, vertical: 2),
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
                    GestureDetector(
                      onTap: () {
                        setState(() => _showChannelList = false);
                        _screenFocusNode.requestFocus();
                      },
                      child: const Icon(Icons.close,
                          color: Colors.white54, size: 20),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: _channelListScrollController,
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: _sidebarItems.length,
                  itemBuilder: (_, index) {
                    final item = _sidebarItems[index];
                    return item.isHeader
                        ? _buildSidebarHeader(item.category!)
                        : _buildSidebarChannel(item.channel!, item.globalIndex!);
                  },
                ),
              ),
            ],
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
                event.logicalKey == LogicalKeyboardKey.enter)) {
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
              Icon(widget.icon,
                  color: _isFocused ? Colors.white : Colors.white70, size: 18),
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

  const _ControlButton({
    required this.icon,
    this.onTap,
    this.size = 24,
    this.highlighted = false,
  });

  @override
  State<_ControlButton> createState() => _ControlButtonState();
}

class _ControlButtonState extends State<_ControlButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final isActive = widget.highlighted || _isFocused;
    return Focus(
      onFocusChange: (focused) => setState(() => _isFocused = focused),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter)) {
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
    );
  }
}
