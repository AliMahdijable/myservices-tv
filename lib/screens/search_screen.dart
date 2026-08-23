import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../models/channel.dart';
import '../theme/app_theme.dart';
import '../utils/search_helpers.dart';
import '../widgets/tv_keyboard.dart';
import 'player_screen.dart';

class SearchScreen extends StatefulWidget {
  final List<ChannelCategory> categories;

  const SearchScreen({super.key, required this.categories});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _fieldFocus = FocusNode(debugLabel: 'search field');
  late final ChannelSearchIndex _searchIndex;

  List<Channel> _results = const [];
  int _totalResults = 0;
  bool _fieldFocused = false;
  bool _keyboardOpen = false;
  bool _openingPlayer = false;

  @override
  void initState() {
    super.initState();
    _searchIndex = ChannelSearchIndex(
      widget.categories.expand((category) => category.channels),
    );
    _controller.addListener(_onChanged);
    _fieldFocus.onKeyEvent = (_, event) {
      if (event is KeyDownEvent) {
        if (_isActivationKey(event.logicalKey)) {
          _openSearch();
          return KeyEventResult.handled;
        }

        final direction = _directionForKey(event.logicalKey);
        if (direction != null) {
          FocusScope.of(context).focusInDirection(direction);
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fieldFocus.requestFocus();
    });
  }

  Future<void> _openSearch() async {
    if (_keyboardOpen) return;
    _keyboardOpen = true;
    try {
      final result = await TvKeyboard.show(
        context,
        fieldLabel: 'ابحث عن قناة',
        initialText: _controller.text,
        initialLanguage: TvKeyboardLanguage.arabic,
      );
      if (result != null && mounted) _controller.text = result;
    } finally {
      _keyboardOpen = false;
      if (mounted) _fieldFocus.requestFocus();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  void _onChanged() {
    final result = _searchIndex.search(_controller.text);
    setState(() {
      _results = result.channels;
      _totalResults = result.total;
    });
  }

  void _play(Channel channel) {
    // Guards against a double tap/double OK-press pushing two PlayerScreen
    // routes (and two live native players) before the first push lands.
    if (_openingPlayer) return;
    _openingPlayer = true;
    Navigator.of(context)
        .push(
          PageRouteBuilder(
            pageBuilder: (_, __, ___) =>
                PlayerScreen(channel: channel, categories: widget.categories),
            transitionsBuilder: (_, animation, __, child) =>
                FadeTransition(opacity: animation, child: child),
            transitionDuration: const Duration(milliseconds: 200),
          ),
        )
        .then((_) => _openingPlayer = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primaryDark,
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.backgroundGradient),
        child: SafeArea(
          minimum: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            children: [
              _buildBar(),
              Expanded(child: _results.isEmpty ? _buildEmpty() : _buildGrid()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          _BackButton(onTap: () => Navigator.of(context).pop()),
          const SizedBox(width: 12),
          Expanded(
            child: Focus(
              canRequestFocus: false,
              onFocusChange: (focused) {
                if (_fieldFocused != focused) {
                  setState(() => _fieldFocused = focused);
                }
              },
              child: Semantics(
                label: 'البحث عن قناة، اضغط زر الاختيار للكتابة',
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceDark,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _fieldFocused
                          ? AppColors.accentRedLight
                          : Colors.white.withValues(alpha: 0.1),
                      width: _fieldFocused ? 2 : 1,
                    ),
                    boxShadow: _fieldFocused
                        ? [
                            BoxShadow(
                              color: AppColors.accentRed.withValues(
                                alpha: 0.28,
                              ),
                              blurRadius: 16,
                            ),
                          ]
                        : const [],
                  ),
                  child: TextField(
                    controller: _controller,
                    focusNode: _fieldFocus,
                    readOnly: true,
                    showCursor: false,
                    enableInteractiveSelection: false,
                    textDirection: TextDirection.rtl,
                    style: AppFonts.cairo(color: Colors.white, fontSize: 16),
                    onTap: _openSearch,
                    decoration: InputDecoration(
                      hintText: 'ابحث عن قناة...',
                      hintStyle: AppFonts.cairo(
                        color: Colors.white38,
                        fontSize: 16,
                      ),
                      prefixIcon: const Icon(
                        Icons.search,
                        color: Colors.white38,
                      ),
                      suffixIcon: _controller.text.isNotEmpty
                          ? IconButton(
                              tooltip: 'مسح البحث',
                              icon: const Icon(
                                Icons.clear,
                                color: Colors.white54,
                              ),
                              onPressed: () {
                                _controller.clear();
                                _fieldFocus.requestFocus();
                              },
                            )
                          : null,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    final queryIsEmpty = normalizeSearchText(_controller.text).isEmpty;
    return Center(
      child: Semantics(
        liveRegion: true,
        label: queryIsEmpty ? 'ابدأ البحث عن قناة' : 'لا توجد نتائج للبحث',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              queryIsEmpty ? Icons.search : Icons.search_off,
              color: Colors.white24,
              size: 64,
            ),
            const SizedBox(height: 16),
            Text(
              queryIsEmpty ? 'ابحث عن أي قناة' : 'لا توجد نتائج',
              style: AppFonts.cairo(color: Colors.white38, fontSize: 18),
            ),
            if (queryIsEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '${_searchIndex.length} قناة متاحة',
                style: AppFonts.cairo(color: Colors.white24, fontSize: 14),
                textDirection: TextDirection.rtl,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGrid() {
    final resultLabel = _totalResults > _results.length
        ? 'عرض أول ${_results.length} من إجمالي $_totalResults نتيجة'
        : '$_totalResults نتيجة';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Semantics(
            liveRegion: true,
            child: Text(
              resultLabel,
              style: AppFonts.cairo(color: AppColors.textMuted, fontSize: 13),
              textDirection: TextDirection.rtl,
            ),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              const targetCardWidth = 168.0;
              final availableWidth = constraints.maxWidth - 32;
              final columnCount = (availableWidth / targetCardWidth)
                  .floor()
                  .clamp(3, 8)
                  .toInt();

              return GridView.builder(
                padding: const EdgeInsets.all(16),
                physics: const ClampingScrollPhysics(),
                scrollCacheExtent: const ScrollCacheExtent.pixels(520),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columnCount,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.16,
                ),
                itemCount: _results.length,
                findChildIndexCallback: (key) {
                  if (key is! ValueKey<String>) return null;
                  final index = _results.indexWhere(
                    (channel) => _searchResultKey(channel) == key.value,
                  );
                  return index < 0 ? null : index;
                },
                itemBuilder: (_, index) {
                  final channel = _results[index];
                  return _SearchCard(
                    key: ValueKey<String>(_searchResultKey(channel)),
                    channel: channel,
                    onTap: () => _play(channel),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

String _searchResultKey(Channel channel) =>
    '${channel.url}\u0000${channel.streamId}\u0000${channel.tvgId}\u0000'
    '${channel.name}\u0000${channel.group}';

bool _isActivationKey(LogicalKeyboardKey key) {
  return key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.gameButtonA;
}

TraversalDirection? _directionForKey(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.arrowUp) return TraversalDirection.up;
  if (key == LogicalKeyboardKey.arrowDown) return TraversalDirection.down;
  if (key == LogicalKeyboardKey.arrowLeft) return TraversalDirection.left;
  if (key == LogicalKeyboardKey.arrowRight) return TraversalDirection.right;
  return null;
}

class _BackButton extends StatefulWidget {
  final VoidCallback onTap;

  const _BackButton({required this.onTap});

  @override
  State<_BackButton> createState() => _BackButtonState();
}

class _BackButtonState extends State<_BackButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'رجوع',
      onTap: widget.onTap,
      excludeSemantics: true,
      child: Focus(
        onFocusChange: (focused) => setState(() => _focused = focused),
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent && _isActivationKey(event.logicalKey)) {
            widget.onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: _focused ? AppColors.accentRed : AppColors.surfaceDark,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _focused
                    ? AppColors.accentRedLight
                    : Colors.white.withValues(alpha: 0.06),
              ),
            ),
            child: const Icon(
              Icons.arrow_back_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchCard extends StatefulWidget {
  final Channel channel;
  final VoidCallback onTap;

  const _SearchCard({super.key, required this.channel, required this.onTap});

  @override
  State<_SearchCard> createState() => _SearchCardState();
}

class _SearchCardState extends State<_SearchCard> {
  bool _focused = false;

  void _onFocusChange(bool focused) {
    setState(() => _focused = focused);
    if (!focused) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.28,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final channel = widget.channel;
    final semanticLabel = channel.group.isEmpty
        ? 'تشغيل قناة ${channel.name}'
        : 'تشغيل قناة ${channel.name}، ${channel.group}';

    return Semantics(
      button: true,
      label: semanticLabel,
      onTap: widget.onTap,
      excludeSemantics: true,
      child: Focus(
        onFocusChange: _onFocusChange,
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent && _isActivationKey(event.logicalKey)) {
            widget.onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedScale(
            duration: const Duration(milliseconds: 120),
            scale: _focused ? 1.045 : 1,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              decoration: BoxDecoration(
                color: _focused
                    ? AppColors.accentRed.withValues(alpha: 0.2)
                    : AppColors.surfaceDark,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _focused
                      ? AppColors.accentRedLight
                      : Colors.white.withValues(alpha: 0.06),
                  width: _focused ? 2 : 1,
                ),
                boxShadow: _focused
                    ? [
                        BoxShadow(
                          color: AppColors.accentRed.withValues(alpha: 0.38),
                          blurRadius: 16,
                        ),
                      ]
                    : const [],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Column(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: channel.logoUrl.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: channel.logoUrl,
                                fit: BoxFit.contain,
                                memCacheWidth: 240,
                                memCacheHeight: 160,
                                errorWidget: (_, __, ___) => const Icon(
                                  Icons.tv,
                                  color: Colors.white38,
                                  size: 30,
                                ),
                              )
                            : const Icon(
                                Icons.tv,
                                color: Colors.white38,
                                size: 30,
                              ),
                      ),
                    ),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 7,
                      ),
                      color: _focused
                          ? AppColors.accentRed.withValues(alpha: 0.32)
                          : Colors.black.withValues(alpha: 0.3),
                      child: Column(
                        children: [
                          Text(
                            channel.name,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppFonts.cairo(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (channel.group.isNotEmpty)
                            Text(
                              channel.group,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppFonts.cairo(
                                color: Colors.white54,
                                fontSize: 9,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
