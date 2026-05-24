import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/channel.dart';
import '../theme/app_theme.dart';

class ChannelCard extends StatefulWidget {
  final Channel channel;
  final VoidCallback onTap;
  final bool autofocus;

  const ChannelCard({
    super.key,
    required this.channel,
    required this.onTap,
    this.autofocus = false,
  });

  @override
  State<ChannelCard> createState() => _ChannelCardState();
}

class _ChannelCardState extends State<ChannelCard>
    with SingleTickerProviderStateMixin {
  bool _isPressed = false;
  bool _isFocused = false;
  final FocusNode _focusNode = FocusNode();
  late AnimationController _glowController;
  late Animation<double> _glowAnimation;

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _glowAnimation = Tween<double>(begin: 0.3, end: 0.7).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _glowController.dispose();
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
      _glowController.repeat(reverse: true);
      if (mounted) {
        // Auto-scroll all ancestor scrollables to make this card visible
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            Scrollable.ensureVisible(
              context,
              alignment: 0.3,
              duration: const Duration(milliseconds: 100),
              curve: Curves.easeOut,
            );
          }
        });
      }
    } else {
      _glowController.stop();
      _glowController.reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      onFocusChange: _onFocusChange,
      onKeyEvent: _handleKeyEvent,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) => setState(() => _isPressed = false),
        onTapCancel: () => setState(() => _isPressed = false),
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _glowAnimation,
          builder: (context, child) {
            final glowAlpha = _isFocused ? _glowAnimation.value : 0.0;
            return AnimatedScale(
              scale: _isPressed ? 0.94 : (_isFocused ? 1.1 : 1.0),
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 120,
                margin: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  color: const Color(0xFF111D2E),
                  border: Border.all(
                    color: _isFocused
                        ? AppColors.accentRed
                        : Colors.white.withValues(alpha: 0.06),
                    width: _isFocused ? 3 : 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: _isFocused
                          ? AppColors.accentRed.withValues(alpha: 0.5)
                          : Colors.black.withValues(alpha: 0.35),
                      blurRadius: _isFocused ? 24 : 12,
                      offset: const Offset(0, 4),
                    ),
                    if (_isFocused) ...[
                      // Pulsing outer glow
                      BoxShadow(
                        color: AppColors.accentRed
                            .withValues(alpha: glowAlpha * 0.5),
                        blurRadius: 35,
                        spreadRadius: 4,
                      ),
                      // Inner bright glow
                      BoxShadow(
                        color: AppColors.accentRed
                            .withValues(alpha: 0.25),
                        blurRadius: 12,
                        spreadRadius: 1,
                      ),
                    ],
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(15),
                  child: Stack(
                    children: [
                      // Full card content
                      Column(
                        children: [
                          // Logo area
                          Expanded(
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    _isFocused
                                        ? const Color(0xFF1E3A58)
                                        : const Color(0xFF182840),
                                    const Color(0xFF0E1B2D)
                                        .withValues(alpha: 0.5),
                                  ],
                                ),
                              ),
                              child: _buildLogo(),
                            ),
                          ),
                          // Bottom: Name bar
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 10),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  _isFocused
                                      ? AppColors.accentRed
                                          .withValues(alpha: 0.35)
                                      : const Color(0xFF0C1825),
                                  _isFocused
                                      ? const Color(0xFF1A0A10)
                                      : const Color(0xFF091320),
                                ],
                              ),
                            ),
                            child: Text(
                              widget.channel.name,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppFonts.cairo(
                                color: Colors.white,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),

                      // "مباشر" badge
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [
                                Color(0xFFD32F2F),
                                Color(0xFFEF5350)
                              ],
                            ),
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.red.withValues(alpha: 0.4),
                                blurRadius: 6,
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 4,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.white
                                          .withValues(alpha: 0.7),
                                      blurRadius: 3,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 3),
                              Text(
                                'مباشر',
                                style: AppFonts.cairo(
                                  color: Colors.white,
                                  fontSize: 8,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Focus top highlight line
                      if (_isFocused)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: Container(
                            height: 3,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  AppColors.accentRed.withValues(alpha: 0.0),
                                  AppColors.accentRed,
                                  AppColors.accentRed.withValues(alpha: 0.0),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildLogo() {
    if (widget.channel.logoUrl.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: widget.channel.logoUrl,
        fit: BoxFit.contain,
        placeholder: (context, url) => _buildShimmerPlaceholder(),
        errorWidget: (context, url, error) => _buildAppLogo(),
      );
    }
    return _buildAppLogo();
  }

  Widget _buildShimmerPlaceholder() {
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

  Widget _buildAppLogo() {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Image.asset(
        'assets/images/logo.png',
        fit: BoxFit.contain,
      ),
    );
  }
}
