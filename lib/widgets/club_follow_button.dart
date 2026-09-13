import 'package:flutter/material.dart';

import '../models/fixture.dart';
import '../services/match_alerts_service.dart';
import '../theme/app_theme.dart';

/// Follows a club, from wherever its name appears.
///
/// Following is the durable half of the feature: one subscription that covers
/// every match the club plays, including the ones that have not been scheduled
/// yet. That is why it is offered next to the club rather than only inside a
/// settings screen — the moment you care about a club is the moment you are
/// looking at it.
class ClubFollowButton extends StatefulWidget {
  final FixtureTeam club;
  final double size;

  const ClubFollowButton({super.key, required this.club, this.size = 18});

  @override
  State<ClubFollowButton> createState() => _ClubFollowButtonState();
}

class _ClubFollowButtonState extends State<ClubFollowButton> {
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
    final following = _alerts.followsClub(widget.club.id);
    setState(() => _busy = true);
    await _alerts.setFollowClub(
      widget.club.id,
      !following,
      name: widget.club.name,
    );
    if (!mounted) return;
    setState(() => _busy = false);

    final error = _alerts.lastError;
    if (error != null &&
        _alerts.syncState != AlertSyncState.ok &&
        context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error, textDirection: TextDirection.rtl),
          backgroundColor: AppColors.surfaceDark,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final following = _alerts.followsClub(widget.club.id);
    return Semantics(
      button: true,
      toggled: following,
      label: following
          ? 'إلغاء متابعة ${widget.club.name}'
          : 'متابعة ${widget.club.name}',
      child: InkResponse(
        onTap: _busy ? null : _toggle,
        radius: widget.size,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: _busy
              ? SizedBox(
                  width: widget.size,
                  height: widget.size,
                  child: const CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.accentRedLight,
                  ),
                )
              : Icon(
                  following ? Icons.star_rounded : Icons.star_border_rounded,
                  size: widget.size,
                  color: following
                      ? AppColors.accentRedLight
                      : AppColors.textMuted,
                ),
        ),
      ),
    );
  }
}
