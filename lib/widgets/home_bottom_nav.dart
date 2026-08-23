import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';

/// Bottom navigation bar for narrow (phone) screens — the mobile-native
/// equivalent of [NavRail], which doesn't fit a narrow viewport.
class HomeBottomNav extends StatelessWidget {
  final bool searchEnabled;
  final VoidCallback onSearchTap;
  final VoidCallback onSettingsTap;

  const HomeBottomNav({
    super.key,
    required this.searchEnabled,
    required this.onSearchTap,
    required this.onSettingsTap,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        height: 62,
        decoration: BoxDecoration(
          color: AppColors.primaryDark.withValues(alpha: 0.96),
          border: Border(
            top: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _BottomNavItem(
              icon: Icons.home_rounded,
              label: 'الرئيسية',
              active: true,
            ),
            _BottomNavItem(
              icon: Icons.search_rounded,
              label: 'بحث',
              onTap: searchEnabled ? onSearchTap : null,
            ),
            _BottomNavItem(
              icon: Icons.settings_rounded,
              label: 'الإعدادات',
              onTap: onSettingsTap,
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomNavItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;

  const _BottomNavItem({
    required this.icon,
    required this.label,
    this.active = false,
    this.onTap,
  });

  @override
  State<_BottomNavItem> createState() => _BottomNavItemState();
}

class _BottomNavItemState extends State<_BottomNavItem> {
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
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.active)
                Container(
                  width: 4,
                  height: 3,
                  margin: const EdgeInsets.only(bottom: 4),
                  decoration: BoxDecoration(
                    color: AppColors.accentRedLight,
                    borderRadius: BorderRadius.circular(2),
                  ),
                )
              else
                const SizedBox(height: 7),
              Icon(widget.icon, color: color, size: 20),
              const SizedBox(height: 3),
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
    );
  }
}
