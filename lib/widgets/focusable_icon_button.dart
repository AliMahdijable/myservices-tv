import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';

/// Shared square, D-pad-focusable icon button (back/search/refresh/settings
/// style). Consolidates a pattern that had drifted into several
/// near-identical copies across screens.
class FocusableIconButton extends StatefulWidget {
  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onTap;
  final bool isLoading;
  final bool autofocus;
  final double size;
  final double iconSize;

  const FocusableIconButton({
    super.key,
    required this.icon,
    required this.semanticLabel,
    this.onTap,
    this.isLoading = false,
    this.autofocus = false,
    this.size = 46,
    this.iconSize = 24,
  });

  @override
  State<FocusableIconButton> createState() => _FocusableIconButtonState();
}

class _FocusableIconButtonState extends State<FocusableIconButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null && !widget.isLoading;

    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      value: widget.isLoading ? 'جارٍ التحديث' : null,
      child: Focus(
        canRequestFocus: enabled,
        skipTraversal: !enabled,
        autofocus: widget.autofocus,
        onFocusChange: (focused) {
          if (_isFocused != focused) setState(() => _isFocused = focused);
        },
        onKeyEvent: (node, event) {
          if (enabled &&
              event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.select ||
                  event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
            widget.onTap!.call();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          onTap: enabled ? widget.onTap : null,
          child: AnimatedOpacity(
            opacity: enabled || widget.isLoading ? 1 : 0.42,
            duration: const Duration(milliseconds: 150),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                color: _isFocused ? AppColors.accentRed : AppColors.surfaceDark,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _isFocused
                      ? AppColors.accentRedLight
                      : Colors.white.withValues(alpha: 0.06),
                  width: _isFocused ? 2 : 1,
                ),
                boxShadow: _isFocused
                    ? [
                        BoxShadow(
                          color: AppColors.accentRed.withValues(alpha: 0.4),
                          blurRadius: 12,
                        ),
                      ]
                    : [],
              ),
              child: widget.isLoading
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      widget.icon,
                      color: enabled
                          ? (_isFocused
                                ? Colors.white
                                : AppColors.textSecondary)
                          : Colors.white30,
                      size: widget.iconSize,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
