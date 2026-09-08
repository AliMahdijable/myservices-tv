import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/fixture.dart';
import '../services/fixtures_service.dart';
import '../theme/app_theme.dart';
import '../theme/layout_metrics.dart';

/// Match schedules, results and league tables.
///
/// Reads one file from the home server — see [FixturesService] — so there is
/// no API key, no third-party call and no team-name translation here: the
/// server already writes Arabic names that match the web front-end exactly.
class FixturesScreen extends StatefulWidget {
  const FixturesScreen({super.key});

  @override
  State<FixturesScreen> createState() => _FixturesScreenState();
}

enum _Tab { matches, table }

class _FixturesScreenState extends State<FixturesScreen> {
  FixturesData? _data;
  bool _loading = true;
  String? _error;

  _Tab _tab = _Tab.matches;

  /// The day being shown. Defaults to today.
  DateTime? _selectedDay;

  final ScrollController _daysController = ScrollController();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _daysController.dispose();
    super.dispose();
  }

  Future<void> _load({bool forceRefresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final data = await FixturesService.fetch(forceRefresh: forceRefresh);
    if (!mounted) return;
    setState(() {
      _data = data;
      _loading = false;
      _error = data == null ? 'تعذّر تحميل جدول المباريات' : null;
    });
  }

  // ── Day helpers ─────────────────────────────────────────────────────────

  static DateTime _midnight(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static const List<String> _weekdays = [
    'الاثنين',
    'الثلاثاء',
    'الأربعاء',
    'الخميس',
    'الجمعة',
    'السبت',
    'الأحد',
  ];

  static const List<String> _months = [
    'يناير',
    'فبراير',
    'مارس',
    'أبريل',
    'مايو',
    'يونيو',
    'يوليو',
    'أغسطس',
    'سبتمبر',
    'أكتوبر',
    'نوفمبر',
    'ديسمبر',
  ];

  String _dayLabel(DateTime day) {
    final today = _midnight(DateTime.now());
    final diff = _midnight(day).difference(today).inDays;
    if (diff == 0) return 'اليوم';
    if (diff == 1) return 'غداً';
    if (diff == -1) return 'أمس';
    return '${_weekdays[day.weekday - 1]} ${day.day} ${_months[day.month - 1]}';
  }

  /// 24-hour time reads as a number, not a time, in an Arabic interface.
  String _timeLabel(DateTime at) {
    final suffix = at.hour < 12 ? 'صباحاً' : 'مساءً';
    var hour = at.hour % 12;
    if (hour == 0) hour = 12;
    final minute = at.minute.toString().padLeft(2, '0');
    return '$hour:$minute $suffix';
  }

  @override
  Widget build(BuildContext context) {
    final isWide = screenClassOf(context) == ScreenClass.wide;
    final inset = isWide ? 24.0 : 16.0;

    return Container(
      decoration: const BoxDecoration(gradient: AppColors.backgroundGradient),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(isWide, inset),
            if (_data != null && _data!.tables.isNotEmpty)
              _buildTabs(isWide, inset),
            Expanded(child: _buildBody(isWide, inset)),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(bool isWide, double inset) {
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, isWide ? 18 : 14, inset, 4),
      child: Row(
        children: [
          Container(
            width: 4,
            height: isWide ? 26 : 22,
            decoration: BoxDecoration(
              gradient: AppColors.redGradient,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'المباريات',
              style: AppFonts.cairo(
                fontSize: isWide ? 22 : 18,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.2,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          IconButton(
            onPressed: _loading ? null : () => _load(forceRefresh: true),
            icon: const Icon(Icons.refresh_rounded),
            color: AppColors.textSecondary,
            tooltip: 'تحديث',
          ),
        ],
      ),
    );
  }

  Widget _buildTabs(bool isWide, double inset) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: inset),
      child: Row(
        children: [
          _TabButton(
            label: 'المباريات',
            active: _tab == _Tab.matches,
            isWide: isWide,
            onTap: () => setState(() => _tab = _Tab.matches),
          ),
          const SizedBox(width: 8),
          _TabButton(
            label: 'ترتيب الأندية',
            active: _tab == _Tab.table,
            isWide: isWide,
            onTap: () => setState(() => _tab = _Tab.table),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(bool isWide, double inset) {
    if (_loading && _data == null) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.accentRed),
      );
    }
    if (_data == null) {
      return _buildError(inset);
    }
    return _tab == _Tab.table
        ? _buildTables(isWide, inset)
        : _buildMatches(isWide, inset);
  }

  Widget _buildError(double inset) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(inset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              color: AppColors.accentRed,
              size: 48,
            ),
            const SizedBox(height: 14),
            Text(
              _error ?? 'تعذّر التحميل',
              style: AppFonts.cairo(
                color: AppColors.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'هذا القسم متاح داخل الشبكة المحلّية فقط.',
              textAlign: TextAlign.center,
              style: AppFonts.cairo(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: () => _load(forceRefresh: true),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text('إعادة المحاولة', style: AppFonts.cairo()),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accentRed,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Matches ─────────────────────────────────────────────────────────────

  Widget _buildMatches(bool isWide, double inset) {
    final matches = _data!.matches;
    if (matches.isEmpty) {
      return _buildEmpty('لا توجد مباريات.');
    }

    // Distinct days, in order, for the selector.
    final days = <DateTime>[];
    final counts = <DateTime, int>{};
    for (final match in matches) {
      final day = match.day;
      if (!counts.containsKey(day)) days.add(day);
      counts[day] = (counts[day] ?? 0) + 1;
    }
    days.sort();

    // Today by default; if today has nothing, the next day that does — an
    // empty screen on open is worse than showing the nearest real fixture.
    final today = _midnight(DateTime.now());
    var active = _selectedDay;
    if (active == null || !counts.containsKey(active)) {
      active = counts.containsKey(today)
          ? today
          : days.firstWhere((d) => !d.isBefore(today), orElse: () => days.first);
    }

    final dayMatches = matches.where((m) => m.day == active).toList();
    final live = dayMatches.where((m) => m.state == MatchState.live).toList()
      ..sort((a, b) => a.rank.compareTo(b.rank));

    // Group the rest by competition, in the server's priority order.
    // "The rest" is literal: a live match already has its own card at the top,
    // and listing it again under its competition reads as a duplicate rather
    // than as emphasis.
    final byLeague = <String, List<Fixture>>{};
    final order = <String>[];
    final ranks = <String, int>{};
    for (final match in dayMatches.where((m) => m.state != MatchState.live)) {
      if (!byLeague.containsKey(match.league)) {
        order.add(match.league);
        ranks[match.league] = match.rank;
      }
      byLeague.putIfAbsent(match.league, () => []).add(match);
    }
    order.sort((a, b) => (ranks[a] ?? 999).compareTo(ranks[b] ?? 999));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildDaySelector(days, counts, active, isWide, inset),
        Expanded(
          child: ListView(
            padding: EdgeInsets.fromLTRB(inset, 4, inset, 24),
            children: [
              if (live.isNotEmpty) ...[
                _sectionTitle('مباشر الآن', live.length, isWide),
                ...live.map((m) => _MatchCard(
                      fixture: m,
                      isWide: isWide,
                      timeLabel: _timeLabel(m.kickoff),
                    )),
                const SizedBox(height: 8),
              ],
              for (final league in order) ...[
                _sectionTitle(league, byLeague[league]!.length, isWide),
                ...byLeague[league]!.map((m) => _MatchCard(
                      fixture: m,
                      isWide: isWide,
                      timeLabel: _timeLabel(m.kickoff),
                    )),
                const SizedBox(height: 8),
              ],
              if (dayMatches.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: Text(
                    'لا توجد مباريات في هذا اليوم.',
                    textAlign: TextAlign.center,
                    style: AppFonts.cairo(color: AppColors.textSecondary),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDaySelector(
    List<DateTime> days,
    Map<DateTime, int> counts,
    DateTime active,
    bool isWide,
    double inset,
  ) {
    return SizedBox(
      height: isWide ? 78 : 66,
      child: ListView.builder(
        controller: _daysController,
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: inset, vertical: 6),
        itemCount: days.length,
        itemBuilder: (context, index) {
          final day = days[index];
          final isActive = day == active;
          return Padding(
            padding: const EdgeInsets.only(left: 8),
            child: _DayChip(
              label: _dayLabel(day),
              count: counts[day] ?? 0,
              active: isActive,
              isWide: isWide,
              onTap: () => setState(() => _selectedDay = day),
            ),
          );
        },
      ),
    );
  }

  Widget _sectionTitle(String text, int count, bool isWide) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 8),
      child: Row(
        children: [
          Container(
            width: 4,
            height: isWide ? 22 : 18,
            decoration: BoxDecoration(
              gradient: AppColors.redGradient,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.cairo(
                fontSize: isWide ? 19 : 16,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.accentRed.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '$count',
              style: AppFonts.cairo(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: AppColors.accentRedLight,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Standings ───────────────────────────────────────────────────────────

  Widget _buildTables(bool isWide, double inset) {
    final tables = _data!.tables;
    if (tables.isEmpty) return _buildEmpty('لا يوجد ترتيب متاح.');

    return ListView(
      padding: EdgeInsets.fromLTRB(inset, 4, inset, 24),
      children: [
        for (final table in tables) ...[
          _sectionTitle(table.league, table.rows.length, isWide),
          _StandingsTable(table: table, isWide: isWide),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _buildEmpty(String message) {
    return Center(
      child: Text(
        message,
        style: AppFonts.cairo(color: AppColors.textSecondary, fontSize: 15),
      ),
    );
  }
}

// ── Pieces ────────────────────────────────────────────────────────────────

class _TabButton extends StatelessWidget {
  final String label;
  final bool active;
  final bool isWide;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.active,
    required this.isWide,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: active,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: EdgeInsets.symmetric(
            horizontal: isWide ? 20 : 14,
            vertical: isWide ? 10 : 8,
          ),
          decoration: BoxDecoration(
            color: active ? AppColors.accentRed : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: AppFonts.cairo(
              fontSize: isWide ? 15 : 13,
              fontWeight: FontWeight.bold,
              color: active ? Colors.white : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  final String label;
  final int count;
  final bool active;
  final bool isWide;
  final VoidCallback onTap;

  const _DayChip({
    required this.label,
    required this.count,
    required this.active,
    required this.isWide,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: active,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: EdgeInsets.symmetric(horizontal: isWide ? 18 : 14),
          decoration: BoxDecoration(
            color: active ? AppColors.accentRed : AppColors.surfaceDark,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active
                  ? AppColors.accentRedLight
                  : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: AppFonts.cairo(
                  fontSize: isWide ? 15 : 13,
                  fontWeight: FontWeight.bold,
                  color: active ? Colors.white : AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '$count',
                style: AppFonts.cairo(
                  fontSize: isWide ? 12 : 11,
                  color: active
                      ? Colors.white.withValues(alpha: 0.8)
                      : AppColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One match: kickoff and status on top, then a row per side.
///
/// Vertical rather than `[team] score [team]`: a horizontal row cannot fit two
/// team names, two crests and a score on a phone without truncating the names,
/// and Arabic club names carry their distinguishing word at the end.
class _MatchCard extends StatelessWidget {
  final Fixture fixture;
  final bool isWide;
  final String timeLabel;

  const _MatchCard({
    required this.fixture,
    required this.isWide,
    required this.timeLabel,
  });

  @override
  Widget build(BuildContext context) {
    final live = fixture.state == MatchState.live;
    final showScore = fixture.state.hasScore;
    final homeWon = fixture.state == MatchState.finished &&
        fixture.home.goals > fixture.away.goals;
    final awayWon = fixture.state == MatchState.finished &&
        fixture.away.goals > fixture.home.goals;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: EdgeInsets.symmetric(
        horizontal: isWide ? 16 : 12,
        vertical: isWide ? 14 : 11,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceDark,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: live
              ? AppColors.accentRed
              : Colors.white.withValues(alpha: 0.07),
          width: live ? 1.5 : 1,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                timeLabel,
                style: AppFonts.cairo(
                  fontSize: isWide ? 15 : 14,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 9,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: live
                      ? AppColors.accentRed
                      : Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  fixture.state.label,
                  style: AppFonts.cairo(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: live ? Colors.white : AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _SideRow(
            side: fixture.home,
            showScore: showScore,
            winner: homeWon,
            isWide: isWide,
          ),
          Divider(
            height: 14,
            thickness: 1,
            color: Colors.white.withValues(alpha: 0.05),
          ),
          _SideRow(
            side: fixture.away,
            showScore: showScore,
            winner: awayWon,
            isWide: isWide,
          ),
        ],
      ),
    );
  }
}

class _SideRow extends StatelessWidget {
  final TeamSide side;
  final bool showScore;
  final bool winner;
  final bool isWide;

  const _SideRow({
    required this.side,
    required this.showScore,
    required this.winner,
    required this.isWide,
  });

  @override
  Widget build(BuildContext context) {
    final crest = isWide ? 34.0 : 28.0;
    return Row(
      children: [
        SizedBox(
          width: crest,
          height: crest,
          child: side.logoUrl.isEmpty
              ? const Icon(
                  Icons.shield_outlined,
                  color: AppColors.textMuted,
                  size: 18,
                )
              : CachedNetworkImage(
                  imageUrl: side.logoUrl,
                  fit: BoxFit.contain,
                  memCacheWidth: 96,
                  memCacheHeight: 96,
                  errorWidget: (_, __, ___) => const Icon(
                    Icons.shield_outlined,
                    color: AppColors.textMuted,
                    size: 18,
                  ),
                ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            side.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.cairo(
              fontSize: isWide ? 16 : 14,
              fontWeight: winner ? FontWeight.w800 : FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        const SizedBox(width: 8),
        if (showScore)
          Text(
            side.score ?? '0',
            style: AppFonts.cairo(
              fontSize: isWide ? 20 : 18,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
      ],
    );
  }
}

/// A league table. Columns are kept to the ones people actually read; goal
/// difference is computed here rather than spending two columns on for/against,
/// since every extra column squeezes the club names.
class _StandingsTable extends StatelessWidget {
  final LeagueTable table;
  final bool isWide;

  const _StandingsTable({required this.table, required this.isWide});

  @override
  Widget build(BuildContext context) {
    final headStyle = AppFonts.cairo(
      fontSize: isWide ? 12 : 11,
      fontWeight: FontWeight.bold,
      color: AppColors.textSecondary,
    );

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceDark,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            color: Colors.white.withValues(alpha: 0.04),
            padding: EdgeInsets.symmetric(
              horizontal: isWide ? 14 : 10,
              vertical: 9,
            ),
            child: Row(
              children: [
                SizedBox(width: 26, child: Text('#', style: headStyle)),
                const SizedBox(width: 6),
                Expanded(child: Text('الفريق', style: headStyle)),
                _cell('لعب', headStyle, isWide),
                _cell('فاز', headStyle, isWide),
                _cell('خسر', headStyle, isWide),
                _cell('+/−', headStyle, isWide),
                _cell('نقاط', headStyle, isWide),
              ],
            ),
          ),
          for (var i = 0; i < table.rows.length; i++)
            _StandingRowTile(
              row: table.rows[i],
              isWide: isWide,
              striped: i.isOdd,
            ),
        ],
      ),
    );
  }

  static Widget _cell(String text, TextStyle style, bool isWide) => SizedBox(
    width: isWide ? 44 : 34,
    child: Text(text, style: style, textAlign: TextAlign.center),
  );
}

class _StandingRowTile extends StatelessWidget {
  final StandingRow row;
  final bool isWide;
  final bool striped;

  const _StandingRowTile({
    required this.row,
    required this.isWide,
    required this.striped,
  });

  @override
  Widget build(BuildContext context) {
    final body = AppFonts.cairo(
      fontSize: isWide ? 14 : 12.5,
      color: AppColors.textPrimary,
    );
    final diff = row.goalDifference;

    return Container(
      color: striped ? Colors.white.withValues(alpha: 0.02) : null,
      padding: EdgeInsets.symmetric(
        horizontal: isWide ? 14 : 10,
        vertical: isWide ? 9 : 7,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text(
              '${row.position}',
              style: AppFonts.cairo(
                fontSize: isWide ? 13 : 12,
                fontWeight: FontWeight.bold,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: isWide ? 26 : 22,
            height: isWide ? 26 : 22,
            child: row.logoUrl.isEmpty
                ? const SizedBox()
                : CachedNetworkImage(
                    imageUrl: row.logoUrl,
                    fit: BoxFit.contain,
                    memCacheWidth: 72,
                    memCacheHeight: 72,
                    errorWidget: (_, __, ___) => const SizedBox(),
                  ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              row.team,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.cairo(
                fontSize: isWide ? 14 : 12.5,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          _num('${row.played}', body, isWide),
          _num('${row.won}', body, isWide),
          _num('${row.lost}', body, isWide),
          _num(diff > 0 ? '+$diff' : '$diff', body, isWide),
          _num(
            '${row.points}',
            AppFonts.cairo(
              fontSize: isWide ? 15 : 13.5,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
            isWide,
          ),
        ],
      ),
    );
  }

  static Widget _num(String text, TextStyle style, bool isWide) => SizedBox(
    width: isWide ? 44 : 34,
    child: Text(text, style: style, textAlign: TextAlign.center),
  );
}
