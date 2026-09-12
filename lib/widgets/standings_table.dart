import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/standing.dart';
import '../theme/app_theme.dart';
import '../theme/layout_metrics.dart';

/// A full league table, split into one mini-table per group — most
/// competitions have a single group, but the Champions League group stage
/// has several and showing them merged would misrepresent the ranking.
class StandingsTable extends StatelessWidget {
  final List<List<Standing>> groups;

  const StandingsTable({super.key, required this.groups});

  @override
  Widget build(BuildContext context) {
    final isWide = screenClassOf(context) == ScreenClass.wide;
    final showGroupTitles = groups.length > 1;

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final rows = groups[index];
        return Padding(
          padding: EdgeInsets.only(bottom: index == groups.length - 1 ? 0 : 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showGroupTitles) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 8, right: 4),
                  child: Text(
                    rows.first.group,
                    textDirection: TextDirection.rtl,
                    style: AppFonts.cairo(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: AppColors.cardGradient,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.06),
                    ),
                  ),
                  child: Column(
                    children: [
                      _HeaderRow(isWide: isWide),
                      for (final row in rows)
                        _StandingRow(standing: row, isWide: isWide),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HeaderRow extends StatelessWidget {
  final bool isWide;
  const _HeaderRow({required this.isWide});

  @override
  Widget build(BuildContext context) {
    final style = AppFonts.cairo(
      color: AppColors.textMuted,
      fontSize: 11,
      fontWeight: FontWeight.w700,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: 26),
          const SizedBox(width: 34),
          Expanded(
            child: Text('الفريق', textDirection: TextDirection.rtl, style: style),
          ),
          if (isWide) ...[
            SizedBox(width: 28, child: Text('لعب', textAlign: TextAlign.center, style: style)),
            SizedBox(width: 28, child: Text('ف', textAlign: TextAlign.center, style: style)),
            SizedBox(width: 28, child: Text('ت', textAlign: TextAlign.center, style: style)),
            SizedBox(width: 28, child: Text('خ', textAlign: TextAlign.center, style: style)),
          ] else
            SizedBox(width: 32, child: Text('لعب', textAlign: TextAlign.center, style: style)),
          SizedBox(width: 34, child: Text('+/-', textAlign: TextAlign.center, style: style)),
          SizedBox(
            width: 34,
            child: Text('نقاط', textAlign: TextAlign.center, style: style),
          ),
        ],
      ),
    );
  }
}

class _StandingRow extends StatelessWidget {
  final Standing standing;
  final bool isWide;
  const _StandingRow({required this.standing, required this.isWide});

  Color? get _zoneColor {
    final d = standing.description?.toLowerCase() ?? '';
    if (d.contains('champions league')) return const Color(0xFF2E7DD7);
    if (d.contains('europa league')) return const Color(0xFFE58E26);
    if (d.contains('conference')) return const Color(0xFF2FA84F);
    if (d.contains('relegation')) return AppColors.accentRed;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final numStyle = AppFonts.cairo(
      color: AppColors.textSecondary,
      fontSize: 12,
      fontWeight: FontWeight.w600,
    );
    final zoneColor = _zoneColor;

    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
          right: BorderSide(
            color: zoneColor ?? Colors.transparent,
            width: 3,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text(
              '${standing.rank}',
              textAlign: TextAlign.center,
              style: AppFonts.cairo(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          SizedBox(
            width: 34,
            height: 24,
            child: standing.team.logoUrl.isEmpty
                ? const Icon(Icons.shield_outlined, color: AppColors.textMuted, size: 18)
                : CachedNetworkImage(
                    imageUrl: standing.team.logoUrl,
                    fit: BoxFit.contain,
                    errorWidget: (_, __, ___) => const Icon(
                      Icons.shield_outlined,
                      color: AppColors.textMuted,
                      size: 18,
                    ),
                    placeholder: (_, __) => const SizedBox.shrink(),
                  ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              standing.team.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.cairo(
                color: AppColors.textPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (isWide) ...[
            SizedBox(width: 28, child: Text('${standing.played}', textAlign: TextAlign.center, style: numStyle)),
            SizedBox(width: 28, child: Text('${standing.win}', textAlign: TextAlign.center, style: numStyle)),
            SizedBox(width: 28, child: Text('${standing.draw}', textAlign: TextAlign.center, style: numStyle)),
            SizedBox(width: 28, child: Text('${standing.lose}', textAlign: TextAlign.center, style: numStyle)),
          ] else
            SizedBox(width: 32, child: Text('${standing.played}', textAlign: TextAlign.center, style: numStyle)),
          SizedBox(
            width: 34,
            child: Text(
              standing.goalsDiff > 0
                  ? '+${standing.goalsDiff}'
                  : '${standing.goalsDiff}',
              textAlign: TextAlign.center,
              style: numStyle,
            ),
          ),
          SizedBox(
            width: 34,
            child: Text(
              '${standing.points}',
              textAlign: TextAlign.center,
              style: AppFonts.cairo(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
