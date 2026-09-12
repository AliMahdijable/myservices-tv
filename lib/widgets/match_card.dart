import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/fixture.dart';
import '../theme/app_theme.dart';

/// One fixture row: two teams, a centered score/time/status column.
///
/// Shared by the "all competitions" list (where a league header groups
/// several of these) and could later be reused standalone — kept dumb and
/// stateless on purpose.
class MatchCard extends StatelessWidget {
  final Fixture fixture;

  const MatchCard({super.key, required this.fixture});

  @override
  Widget build(BuildContext context) {
    final isLive = fixture.phase == FixturePhase.live;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        gradient: AppColors.cardGradient,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isLive
              ? AppColors.accentRed.withValues(alpha: 0.55)
              : Colors.white.withValues(alpha: 0.06),
          width: isLive ? 1.4 : 1,
        ),
        boxShadow: isLive
            ? [
                BoxShadow(
                  color: AppColors.accentRed.withValues(alpha: 0.18),
                  blurRadius: 14,
                  spreadRadius: -4,
                ),
              ]
            : null,
      ),
      child: Row(
        children: [
          Expanded(child: _TeamLabel(team: fixture.home, logoFirst: true)),
          _CenterStatus(fixture: fixture),
          Expanded(child: _TeamLabel(team: fixture.away, logoFirst: false)),
        ],
      ),
    );
  }
}

class _TeamLabel extends StatelessWidget {
  final FixtureTeam team;
  final bool logoFirst;

  const _TeamLabel({required this.team, required this.logoFirst});

  @override
  Widget build(BuildContext context) {
    final logo = _TeamLogo(url: team.logoUrl);
    final name = Expanded(
      child: Text(
        team.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: logoFirst ? TextAlign.start : TextAlign.end,
        style: AppFonts.cairo(
          fontSize: 12.5,
          fontWeight: team.winner == true
              ? FontWeight.w800
              : FontWeight.w600,
          color: team.winner == false
              ? AppColors.textMuted
              : AppColors.textPrimary,
          height: 1.2,
        ),
      ),
    );

    return Row(
      children: logoFirst
          ? [logo, const SizedBox(width: 8), name]
          : [name, const SizedBox(width: 8), logo],
    );
  }
}

class _TeamLogo extends StatelessWidget {
  final String url;
  const _TeamLogo({required this.url});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 30,
      height: 30,
      child: url.isEmpty
          ? const Icon(
              Icons.shield_outlined,
              color: AppColors.textMuted,
              size: 22,
            )
          : CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.contain,
              errorWidget: (_, __, ___) => const Icon(
                Icons.shield_outlined,
                color: AppColors.textMuted,
                size: 22,
              ),
              placeholder: (_, __) => const SizedBox.shrink(),
            ),
    );
  }
}

class _CenterStatus extends StatelessWidget {
  final Fixture fixture;
  const _CenterStatus({required this.fixture});

  @override
  Widget build(BuildContext context) {
    final phase = fixture.phase;
    final hasScore =
        phase == FixturePhase.live || phase == FixturePhase.finished;

    return SizedBox(
      width: 74,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (phase == FixturePhase.live) ...[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: AppColors.accentRedLight,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  fixture.elapsedMinutes != null
                      ? "${fixture.elapsedMinutes}'"
                      : 'مباشر',
                  style: AppFonts.cairo(
                    color: AppColors.accentRedLight,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
          if (hasScore)
            Text(
              '${fixture.homeGoals ?? 0} - ${fixture.awayGoals ?? 0}',
              style: AppFonts.cairo(
                color: AppColors.textPrimary,
                fontSize: 19,
                fontWeight: FontWeight.w800,
              ),
            )
          else if (phase == FixturePhase.upcoming)
            Text(
              _formatTime(fixture.kickoff),
              style: AppFonts.cairo(
                color: AppColors.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            )
          else
            Icon(
              Icons.event_busy_rounded,
              color: AppColors.textMuted,
              size: 18,
            ),
          const SizedBox(height: 3),
          Text(
            _statusLabel(phase, fixture.statusShort),
            textDirection: TextDirection.rtl,
            style: AppFonts.cairo(
              color: phase == FixturePhase.finished
                  ? AppColors.textMuted
                  : AppColors.textSecondary,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  static String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  static String _statusLabel(FixturePhase phase, String code) {
    switch (phase) {
      case FixturePhase.live:
        return code == 'HT' ? 'استراحة' : 'مباشر الآن';
      case FixturePhase.finished:
        return 'انتهت المباراة';
      case FixturePhase.upcoming:
        return 'لم تبدأ بعد';
      case FixturePhase.other:
        switch (code) {
          case 'PST':
            return 'مؤجلة';
          case 'CANC':
            return 'ملغاة';
          case 'ABD':
            return 'متوقفة';
          default:
            return 'غير محددة';
        }
    }
  }
}
