import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';

/// Side navigation rail for wide (tablet/TV) screens. Replaces the search
/// and settings icon buttons that used to sit in the home app bar, freeing
/// that bar down to just the logo/tagline/refresh.
class NavRail extends StatelessWidget {
  final bool searchEnabled;
  final VoidCallback onSearchTap;
  final VoidCallback onSettingsTap;

  const NavRail({
    super.key,
    required this.searchEnabled,
    required this.onSearchTap,
    required this.onSettingsTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 84,
      padding: const EdgeInsets.symmetric(vertical: 20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.02),
        border: Border(
          left: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      child: Column(
        children: [
          _RailItem(icon: Icons.home_rounded, label: 'الرئيسية', active: true),
          const SizedBox(height: 18),
          _RailItem(
            icon: Icons.search_rounded,
            label: 'بحث',
            onTap: searchEnabled ? onSearchTap : null,
          ),
          const Spacer(),
          _RailItem(
            icon: Icons.settings_rounded,
            label: 'الإعدادات',
            onTap: onSettingsTap,
          ),
        ],
      ),
    );
  }
}

class _RailItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;

  const _RailItem({
    required this.icon,
    required this.label,
    this.active = false,
    this.onTap,
  });

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final highlighted = widget.active || _isFocused;
    final color = highlighted ? AppColors.accentRedLight : AppColors.textMuted;

    return Semantics(
      button: true,
      enabled: enabled,
      selected: widget.active,
      label: widget.label,
      child: Focus(
        canRequestFocus: enabled,
        skipTraversal: !enabled,
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
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 60,
            height: 56,
            decoration: BoxDecoration(
              color: widget.active
                  ? AppColors.accentRed.withValues(alpha: 0.16)
                  : _isFocused
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(15),
              border: widget.active
                  ? Border.all(
                      color: AppColors.accentRed.withValues(alpha: 0.4),
                    )
                  : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(widget.icon, color: color, size: 21),
                const SizedBox(height: 4),
                Text(
                  widget.label,
                  style: AppFonts.cairo(
                    color: color,
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
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
