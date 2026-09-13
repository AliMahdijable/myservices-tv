import 'package:flutter/material.dart';

import '../models/match_alert.dart';
import '../services/match_alerts_service.dart';
import '../theme/app_theme.dart';
import '../widgets/focusable_icon_button.dart';

/// Everything the user can say about being told when matches happen.
///
/// Deliberately one screen. A feature that can wake a phone at ten at night
/// should have a single place that answers "what have I agreed to, and how do
/// I stop it" — not a switch on a card, another in a menu and a third in the
/// system settings.
class AlertSettingsScreen extends StatefulWidget {
  const AlertSettingsScreen({super.key});

  @override
  State<AlertSettingsScreen> createState() => _AlertSettingsScreenState();
}

class _AlertSettingsScreenState extends State<AlertSettingsScreen> {
  final _alerts = MatchAlertsService.instance;

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

  @override
  Widget build(BuildContext context) {
    final enabled = _alerts.enabled;

    // A Scaffold, not a bare Container: this is pushed as its own route, and
    // the switches and ink splashes inside it need a Material ancestor. Without
    // one the screen throws "No Material widget found" the moment it opens.
    return Scaffold(
      backgroundColor: AppColors.primaryDark,
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.backgroundGradient),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(context),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                  children: [
                    _syncBanner(),
                    _card(
                      child: SwitchListTile.adaptive(
                        value: enabled,
                        onChanged: (value) => _alerts.setEnabled(value),
                        activeTrackColor: AppColors.accentRed,
                        title: _title('تنبيهات المباريات'),
                        subtitle: _subtitle(
                          enabled
                              ? 'مفعّلة — تصلك تنبيهات المباريات التي اخترتها'
                              : 'موقوفة — لا يصلك أي تنبيه',
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    _sectionLabel('متى تريد التنبيه؟'),
                    _card(
                      child: Column(
                        children: [
                          for (final type in MatchAlertType.values)
                            SwitchListTile.adaptive(
                              value: _alerts.types.contains(type),
                              onChanged: enabled
                                  ? (value) => _alerts.setType(type, value)
                                  : null,
                              activeTrackColor: AppColors.accentRed,
                              title: _title(type.label),
                              subtitle: _subtitle(_describe(type)),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    _sectionLabel('الأندية المتابَعة'),
                    _card(child: _clubs()),
                    const SizedBox(height: 14),
                    _sectionLabel('المباريات المكتومة'),
                    _card(child: _muted()),
                    const SizedBox(height: 20),
                    _clearAll(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _describe(MatchAlertType type) {
    switch (type) {
      case MatchAlertType.before45:
        return 'وقت يكفي للوصول أو إيجاد شاشة';
      case MatchAlertType.before15:
        return 'تذكير أخير قبل البداية';
      case MatchAlertType.kickoff:
        return 'عند انطلاق المباراة فعلاً';
      case MatchAlertType.fullTime:
        return 'النتيجة النهائية عند انتهائها';
    }
  }

  Widget _header(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
    child: Row(
      children: [
        FocusableIconButton(
          icon: Icons.arrow_forward_rounded,
          semanticLabel: 'رجوع',
          autofocus: true,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'تنبيهات المباريات',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.cairo(
              color: AppColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    ),
  );

  /// Says plainly when the device is not actually subscribed to what the
  /// switches above claim. A screen full of switches that are on while nothing
  /// reached Firebase is the worst outcome this feature has.
  Widget _syncBanner() {
    final state = _alerts.syncState;
    if (state != AlertSyncState.failed &&
        state != AlertSyncState.permissionDenied) {
      return const SizedBox.shrink();
    }
    final message = _alerts.lastError ?? 'تعذّر تحديث التنبيهات';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.accentRed.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.accentRed.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: AppColors.accentRedLight,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              textDirection: TextDirection.rtl,
              style: AppFonts.cairo(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (state == AlertSyncState.failed)
            TextButton(
              onPressed: () => _alerts.retrySync(),
              child: Text(
                'إعادة',
                style: AppFonts.cairo(
                  color: AppColors.accentRedLight,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _clubs() {
    final clubs = _alerts.followedClubs.toList();
    if (clubs.isEmpty) {
      return _empty(
        'لا تتابع أي نادٍ. اضغط النجمة بجانب اسم النادي في شاشة المباريات '
        'لتصلك تنبيهات كل مبارياته تلقائياً.',
      );
    }
    return Column(
      children: [
        for (final id in clubs)
          ListTile(
            leading: const Icon(
              Icons.star_rounded,
              color: AppColors.accentRedLight,
              size: 20,
            ),
            title: _title(_alerts.clubName(id) ?? 'نادٍ #$id'),
            trailing: TextButton(
              onPressed: () => _alerts.setFollowClub(id, false),
              child: Text(
                'إلغاء',
                style: AppFonts.cairo(
                  color: AppColors.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _muted() {
    final muted = _alerts.mutedFixtures.toList();
    if (muted.isEmpty) {
      return _empty(
        'لا توجد مباريات مكتومة. إيقاف جرس مباراة لنادٍ تتابعه يكتمها وحدها '
        'دون أن يؤثر على بقية مبارياته.',
      );
    }
    return Column(
      children: [
        for (final id in muted)
          ListTile(
            leading: const Icon(
              Icons.notifications_off_rounded,
              color: AppColors.textMuted,
              size: 20,
            ),
            title: _title(_alerts.mutedLabel(id) ?? 'مباراة #$id'),
            trailing: TextButton(
              onPressed: () => _alerts.unmute(id),
              child: Text(
                'إلغاء الكتم',
                style: AppFonts.cairo(
                  color: AppColors.accentRedLight,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _clearAll() => Center(
    child: TextButton.icon(
      onPressed: () async {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: AppColors.surfaceDark,
            title: Text(
              'إلغاء كل التنبيهات؟',
              textDirection: TextDirection.rtl,
              style: AppFonts.cairo(color: AppColors.textPrimary),
            ),
            content: Text(
              'سيُلغى كل جرس وكل نادٍ متابَع. يمكنك إعادة تفعيل ما تريد لاحقاً.',
              textDirection: TextDirection.rtl,
              style: AppFonts.cairo(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(
                  'تراجع',
                  style: AppFonts.cairo(color: AppColors.textMuted),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(
                  'إلغاء الكل',
                  style: AppFonts.cairo(
                    color: AppColors.accentRedLight,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        );
        if (confirmed ?? false) await _alerts.clearAll();
      },
      icon: const Icon(
        Icons.notifications_off_rounded,
        size: 18,
        color: AppColors.textMuted,
      ),
      label: Text(
        'إلغاء كل التنبيهات',
        style: AppFonts.cairo(
          color: AppColors.textMuted,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );

  // ── small pieces ─────────────────────────────────────────────────────────

  /// A Material, not a decorated Container.
  ///
  /// A ListTile paints its ink splash on the nearest Material ancestor, so a
  /// coloured box between the two swallows every tap highlight — the framework
  /// says so out loud, and the switches inside here are exactly the controls
  /// that need the feedback.
  Widget _card({required Widget child}) => Material(
    color: AppColors.surfaceDark,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: BorderSide(color: Colors.white.withValues(alpha: 0.07)),
    ),
    child: MediaQuery.withClampedTextScaling(maxScaleFactor: 1.4, child: child),
  );

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
    child: Text(
      text,
      textDirection: TextDirection.rtl,
      style: AppFonts.cairo(
        color: AppColors.textSecondary,
        fontSize: 13,
        fontWeight: FontWeight.w800,
      ),
    ),
  );

  Widget _title(String text) => Text(
    text,
    textDirection: TextDirection.rtl,
    style: AppFonts.cairo(
      color: AppColors.textPrimary,
      fontSize: 14,
      fontWeight: FontWeight.w700,
    ),
  );

  Widget _subtitle(String text) => Text(
    text,
    textDirection: TextDirection.rtl,
    style: AppFonts.cairo(color: AppColors.textMuted, fontSize: 11.5),
  );

  Widget _empty(String text) => Padding(
    padding: const EdgeInsets.all(14),
    child: Text(
      text,
      textDirection: TextDirection.rtl,
      style: AppFonts.cairo(
        color: AppColors.textMuted,
        fontSize: 12,
        height: 1.6,
      ),
    ),
  );
}
