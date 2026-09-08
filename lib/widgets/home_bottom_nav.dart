import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import 'home_destination.dart';

/// Bottom navigation bar for narrow (phone) screens — the mobile-native
/// equivalent of [NavRail], which doesn't fit a narrow viewport.
class HomeBottomNav extends StatelessWidget {
  /// Which page the shell is showing, so the bar marks the right destination
  /// instead of always claiming to be on the home page.
  final HomeDestination active;

  final bool searchEnabled;
  final VoidCallback onSearchTap;
  final VoidCallback onSettingsTap;

  /// Null hides the destination entirely. The fixtures feature is served by
  /// the home server, so off that network there is nothing behind it — an
  /// always-visible tab that only ever errors is worse than no tab.
  final VoidCallback? onFixturesTap;

  /// Returns to the home page from another destination.
  final VoidCallback? onHomeTap;

  const HomeBottomNav({
    super.key,
    this.active = HomeDestination.home,
    required this.searchEnabled,
    required this.onSearchTap,
    required this.onSettingsTap,
    this.onFixturesTap,
    this.onHomeTap,
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
        // The bar is a fixed 62dp tall and its items share one row, so
        // neither axis can grow to absorb a large system text scale. Clamp the
        // scale and let each item flex, rather than letting an accessibility
        // setting paint an overflow stripe across the navigation.
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.3,
          child: Row(
            children: [
              Expanded(
                child: _BottomNavItem(
                  icon: Icons.home_rounded,
                  label: 'الرئيسية',
                  active: active == HomeDestination.home,
                  onTap: onHomeTap,
                ),
              ),
              Expanded(
                child: _BottomNavItem(
                  icon: Icons.search_rounded,
                  label: 'بحث',
                  onTap: searchEnabled ? onSearchTap : null,
                ),
              ),
              // Same position as in [NavRail], so a user who moves between a
              // phone and the TV finds the section in the same place.
              if (onFixturesTap != null)
                Expanded(
                  child: _BottomNavItem(
                    icon: Icons.sports_soccer_rounded,
                    label: 'المباريات',
                    active: active == HomeDestination.fixtures,
                    onTap: onFixturesTap,
                  ),
                ),
              Expanded(
                child: _BottomNavItem(
                  icon: Icons.settings_rounded,
                  label: 'الإعدادات',
                  onTap: onSettingsTap,
                ),
              ),
            ],
          ),
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
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
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
