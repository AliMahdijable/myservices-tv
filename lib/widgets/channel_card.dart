import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/channel.dart';
import '../theme/app_theme.dart';
import '../theme/layout_metrics.dart';

/// A channel tile: a square logo stage over a name plate.
///
/// The two-zone split is what gives the card presence at size — a logo floating
/// on a flat panel reads as a placeholder, a logo on a lit stage above a solid
/// plate reads as a poster. Focus flips the whole plate to the accent red
/// rather than drawing a thin ring: a lit bar the width of the card is legible
/// from across a room and survives a washed-out TV panel, which a 1px border
/// never does.
class ChannelCard extends StatefulWidget {
  final Channel channel;
  final VoidCallback onTap;
  final bool autofocus;
  final bool isFavorite;

  /// True for the channel currently playing, so the home screen can mark where
  /// the user left off.
  final bool isPlaying;

  const ChannelCard({
    super.key,
    required this.channel,
    required this.onTap,
    this.autofocus = false,
    this.isFavorite = false,
    this.isPlaying = false,
  });

  @override
  State<ChannelCard> createState() => _ChannelCardState();
}

class _ChannelCardState extends State<ChannelCard> {
  bool _isPressed = false;
  bool _isFocused = false;
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.select ||
          event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.gameButtonA) {
        widget.onTap();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _onFocusChange(bool focused) {
    setState(() => _isFocused = focused);
    if (focused) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _isFocused) _keepFocusedCardVisible();
      });
    }
  }

  Future<void> _keepFocusedCardVisible() async {
    await Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 100),
      curve: Curves.easeOut,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    );
    if (!mounted || !_isFocused) return;
    await Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 100),
      curve: Curves.easeOut,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    );
  }

  @override
  Widget build(BuildContext context) {
    final metrics = ChannelCardMetrics.of(context);

    return Semantics(
      button: true,
      focusable: true,
      focused: _isFocused,
      selected: widget.isPlaying,
      label: 'تشغيل قناة ${widget.channel.name}',
      onTap: widget.onTap,
      child: Focus(
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        onFocusChange: _onFocusChange,
        onKeyEvent: _handleKeyEvent,
        child: GestureDetector(
          onTapDown: (_) => setState(() => _isPressed = true),
          onTapUp: (_) => setState(() => _isPressed = false),
          onTapCancel: () => setState(() => _isPressed = false),
          onTap: widget.onTap,
          child: AnimatedSlide(
            // Translating rather than changing the margin: the rail has a fixed
            // itemExtent, so a margin change would fight it and relayout.
            offset: Offset(
              0,
              _isFocused ? -ChannelCardMetrics.focusLift / metrics.height : 0,
            ),
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            child: AnimatedScale(
              scale: _isPressed
                  ? 0.96
                  : (_isFocused ? ChannelCardMetrics.focusScale : 1.0),
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              child: _buildCard(metrics),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCard(ChannelCardMetrics metrics) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: metrics.width,
      height: metrics.height,
      margin: EdgeInsets.symmetric(horizontal: metrics.gutter),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(metrics.radius),
        border: Border.all(
          color: _isFocused
              ? AppColors.accentRedLight
              : Colors.white.withValues(alpha: 0.07),
          width: _isFocused ? 3 : 1,
        ),
        // Only the focused card pays for a shadow. At most one card on screen
        // is focused, so a rail of twenty tiles costs one blur, not twenty.
        boxShadow: _isFocused
            ? [
                BoxShadow(
                  color: AppColors.accentRed.withValues(alpha: 0.34),
                  blurRadius: 26,
                  spreadRadius: -4,
                  offset: const Offset(0, 10),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.55),
                  blurRadius: 22,
                  offset: const Offset(0, 12),
                ),
              ]
            : null,
      ),
      child: Column(
        children: [
          // Expanded, not a fixed height: the focus border is drawn inside the
          // box, so a fixed stage plus a fixed plate leaves a strip of bare
          // card between the plate and the bottom border the moment the border
          // grows from 1px to 3px.
          Expanded(child: _buildStage(metrics)),
          _buildNamePlate(metrics),
        ],
      ),
    );
  }

  /// The square top zone: a lit navy stage with the logo centred on a plate.
  Widget _buildStage(ChannelCardMetrics metrics) {
    final innerRadius = metrics.radius - 2;
    return SizedBox.expand(
      child: Stack(
        children: [
          Positioned.fill(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(innerRadius),
                ),
                gradient: RadialGradient(
                  center: const Alignment(0, -0.18),
                  radius: 0.95,
                  colors: _isFocused
                      ? const [
                          AppColors.cardHover,
                          AppColors.cardDark,
                          AppColors.secondaryDark,
                        ]
                      : const [
                          AppColors.cardDark,
                          AppColors.surfaceDark,
                          AppColors.secondaryDark,
                        ],
                  stops: const [0.0, 0.55, 1.0],
                ),
              ),
              child: Center(
                child: Container(
                  width: metrics.logoPlate,
                  height: metrics.logoPlate,
                  decoration: BoxDecoration(
                    // A ground for logos that are dark-on-transparent. It
                    // barely registers behind a white logo.
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.07),
                    ),
                  ),
                  padding: const EdgeInsets.all(10),
                  child: _buildLogo(),
                ),
              ),
            ),
          ),

          if (widget.isPlaying)
            PositionedDirectional(
              top: 10,
              start: 10,
              child: _buildPlayingChip(metrics),
            ),

          if (widget.isFavorite)
            PositionedDirectional(
              top: 10,
              end: 10,
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.favorite_rounded,
                  color: AppColors.accentRedLight,
                  size: 13,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPlayingChip(ChannelCardMetrics metrics) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.accentRed.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.accentRed.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: const BoxDecoration(
              color: AppColors.accentRedLight,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            'يُعرض',
            style: AppFonts.cairo(
              color: AppColors.accentRedLight,
              fontSize: metrics.badgeSize,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  /// Ceiling on the system text scale inside a card.
  ///
  /// The rail is a lazy list with a fixed itemExtent, so a tile cannot grow to
  /// fit larger text — the name plate's height is fixed and the text simply
  /// overflows it. Measured: the plate overflows at a scale of about 1.93, so
  /// honour the user's preference up to a margin below that rather than
  /// letting an accessibility setting paint an overflow stripe across the card.
  static const double _maxTextScale = 1.6;

  /// The bottom plate. Focus turns it solid accent red — the primary signal.
  Widget _buildNamePlate(ChannelCardMetrics metrics) {
    final innerRadius = metrics.radius - 2;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      height: metrics.plateHeight,
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: metrics.plateHeight > 64 ? 13 : 11,
      ),
      decoration: BoxDecoration(
        // Solid, not a gradient: white sits at 5.9:1 on #C62828, but only
        // 4.2:1 on the lighter #E53935 — a gradient would drop part of the
        // name below the contrast floor.
        color: _isFocused ? AppColors.accentRed : AppColors.primaryDark,
        borderRadius: BorderRadius.vertical(
          bottom: Radius.circular(innerRadius),
        ),
      ),
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: _maxTextScale,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.channel.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.cairo(
                color: Colors.white,
                fontSize: metrics.nameSize,
                fontWeight: _isFocused ? FontWeight.w800 : FontWeight.w700,
                height: 1.25,
              ),
            ),
            if (widget.channel.group.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                widget.channel.group,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.cairo(
                  color: _isFocused
                      ? Colors.white.withValues(alpha: 0.78)
                      : AppColors.textSecondary,
                  fontSize: metrics.groupSize,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLogo() {
    if (widget.channel.logoUrl.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: widget.channel.logoUrl,
        fit: BoxFit.contain,
        memCacheWidth: 256,
        memCacheHeight: 256,
        maxWidthDiskCache: 320,
        maxHeightDiskCache: 320,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (context, url) => _buildLoadingPlaceholder(),
        errorWidget: (context, url, error) => _buildFallbackMark(),
      );
    }
    return _buildFallbackMark();
  }

  Widget _buildLoadingPlaceholder() {
    return Center(
      child: SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 1.5,
          color: AppColors.accentRed.withValues(alpha: 0.6),
        ),
      ),
    );
  }

  /// Shown when a channel has no logo, or its logo fails to load.
  ///
  /// The app mark rather than a generic icon: a rail of tiles with the app's
  /// own mark reads as deliberate, where a row of grey placeholder glyphs
  /// reads as broken.
  Widget _buildFallbackMark() {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Opacity(
        opacity: 0.85,
        child: Image.asset('assets/images/logo.png', fit: BoxFit.contain),
      ),
    );
  }
}
