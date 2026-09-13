import 'package:flutter/material.dart';

import '../models/fixture.dart';
import '../services/match_alerts_service.dart';
import '../theme/app_theme.dart';

/// The bell on a match card.
///
/// Its whole job is to be honest. It is filled when this device is actually
/// subscribed, outlined when it is not, and it refuses to look on while the
/// subscription behind it failed — a bell that lights up and then never rings
/// is worse than one that stayed dark, because the user stops watching for the
/// match themselves.
class MatchAlertBell extends StatefulWidget {
  final Fixture fixture;
  final double size;

  const MatchAlertBell({super.key, required this.fixture, this.size = 20});

  @override
  State<MatchAlertBell> createState() => _MatchAlertBellState();
}

class _MatchAlertBellState extends State<MatchAlertBell> {
  final _alerts = MatchAlertsService.instance;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _alerts.addListener(_onChanged);
  }

  @override
  void dispose() {
    _alerts.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _toggle() async {
    if (_busy) return;
    // A failed state is retried rather than reversed: the wish is still on.
    final coverage = _alerts.coverageOf(widget.fixture);
    if (coverage == AlertCoverage.failed) {
      setState(() => _busy = true);
      await _alerts.retrySync();
      if (mounted) setState(() => _busy = false);
      return;
    }
    final wantOn = coverage == AlertCoverage.off;
    setState(() => _busy = true);
    await _alerts.setBell(widget.fixture, wantOn);
    if (!mounted) return;
    setState(() => _busy = false);

    final state = _alerts.syncState;
    if (state == AlertSyncState.permissionDenied ||
        state == AlertSyncState.failed) {
      final message = _alerts.lastError;
      if (message != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message, textDirection: TextDirection.rtl),
            backgroundColor: AppColors.surfaceDark,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final coverage = _alerts.coverageOf(widget.fixture);
    final viaClub =
        !_alerts.hasBell(widget.fixture.id) &&
        _alerts.isCovered(widget.fixture);

    final label = switch (coverage) {
      AlertCoverage.on =>
        viaClub ? 'إيقاف تنبيه هذه المباراة' : 'إيقاف التنبيه',
      AlertCoverage.pending => 'جارٍ تفعيل التنبيه',
      AlertCoverage.failed => 'تعذّر ضبط التنبيه — اضغط للمحاولة',
      AlertCoverage.off => 'نبّهني قبل المباراة',
    };

    return Semantics(
      button: true,
      toggled: coverage == AlertCoverage.on,
      label: label,
      child: Tooltip(
        message: label,
        child: InkResponse(
          onTap: _busy ? null : _toggle,
          radius: widget.size,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: _busy || coverage == AlertCoverage.pending
                ? SizedBox(
                    width: widget.size,
                    height: widget.size,
                    child: const CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.accentRedLight,
                    ),
                  )
                : Icon(
                    _iconFor(coverage),
                    size: widget.size,
                    color: _colorFor(coverage),
                  ),
          ),
        ),
      ),
    );
  }

  /// The icon says what is true, not what was asked for.
  ///
  /// A wish is recorded the moment it is made, but the subscription behind it
  /// can fail. Showing a filled bell then would tell the user they will be
  /// warned about a match they will go on to miss — so a failure gets its own
  /// mark rather than borrowing the "on" one.
  static IconData _iconFor(AlertCoverage coverage) => switch (coverage) {
    AlertCoverage.on => Icons.notifications_active_rounded,
    AlertCoverage.failed => Icons.notification_important_rounded,
    _ => Icons.notifications_none_rounded,
  };

  static Color _colorFor(AlertCoverage coverage) => switch (coverage) {
    AlertCoverage.on => AppColors.accentRedLight,
    AlertCoverage.failed => AppColors.accentRed,
    _ => AppColors.textMuted,
  };
}
