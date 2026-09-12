import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/competition.dart';
import '../models/fixture.dart';
import '../models/standing.dart';
import '../services/football_api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/focusable_icon_button.dart';
import '../widgets/match_card.dart';
import '../widgets/standings_table.dart';

class MatchesScreen extends StatefulWidget {
  const MatchesScreen({super.key});

  @override
  State<MatchesScreen> createState() => _MatchesScreenState();
}

class _MatchesScreenState extends State<MatchesScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.backgroundGradient),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              _buildTabBar(),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: const [_ScheduleTab(), _StandingsTab()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: [
          FocusableIconButton(
            icon: Icons.arrow_forward_rounded,
            semanticLabel: 'رجوع',
            autofocus: true,
            onTap: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 12),
          Text(
            'المباريات',
            style: AppFonts.cairo(
              color: AppColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
      ),
      child: TabBar(
        controller: _tabController,
        indicator: BoxDecoration(
          gradient: AppColors.redGradient,
          borderRadius: BorderRadius.circular(11),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        labelColor: Colors.white,
        unselectedLabelColor: AppColors.textMuted,
        labelStyle: AppFonts.cairo(fontSize: 14, fontWeight: FontWeight.w800),
        unselectedLabelStyle: AppFonts.cairo(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        tabs: const [
          Tab(text: 'الجدول'),
          Tab(text: 'الترتيب'),
        ],
      ),
    );
  }
}

// ── Schedule tab ─────────────────────────────────────────────────────────

class _ScheduleTab extends StatefulWidget {
  const _ScheduleTab();

  @override
  State<_ScheduleTab> createState() => _ScheduleTabState();
}

class _ScheduleTabState extends State<_ScheduleTab> {
  late DateTime _selectedDate;
  int? _selectedCompetitionId; // null = all
  late Future<List<Fixture>> _future;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDate = DateTime(now.year, now.month, now.day);
    _future = _load();
  }

  Future<List<Fixture>> _load({bool forceRefresh = false}) {
    return _selectedCompetitionId == null
        ? FootballApiService.fixturesForDate(
            _selectedDate,
            forceRefresh: forceRefresh,
          )
        : FootballApiService.fixturesForLeague(
            _selectedCompetitionId!,
            _selectedDate,
            forceRefresh: forceRefresh,
          );
  }

  void _reload({bool forceRefresh = false}) {
    setState(() => _future = _load(forceRefresh: forceRefresh));
  }

  void _selectDate(DateTime date) {
    if (date == _selectedDate) return;
    setState(() {
      _selectedDate = date;
      _future = _load();
    });
  }

  void _selectCompetition(int? id) {
    if (id == _selectedCompetitionId) return;
    setState(() {
      _selectedCompetitionId = id;
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 8),
        _DateStrip(selected: _selectedDate, onSelect: _selectDate),
        const SizedBox(height: 10),
        _CompetitionStrip(
          selectedId: _selectedCompetitionId,
          onSelect: _selectCompetition,
          showAllOption: true,
        ),
        const SizedBox(height: 4),
        Expanded(
          child: RefreshIndicator(
            color: AppColors.accentRedLight,
            backgroundColor: AppColors.surfaceDark,
            onRefresh: () async {
              final result = _load(forceRefresh: true);
              setState(() => _future = result);
              await result;
            },
            child: FutureBuilder<List<Fixture>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(
                      color: AppColors.accentRedLight,
                    ),
                  );
                }
                final fixtures = snapshot.data ?? const [];
                if (fixtures.isEmpty) {
                  return _EmptyState(
                    message: 'لا توجد مباريات في هذا اليوم',
                    onRetry: () => _reload(forceRefresh: true),
                  );
                }
                return _FixturesList(fixtures: fixtures);
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _FixturesList extends StatelessWidget {
  final List<Fixture> fixtures;
  const _FixturesList({required this.fixtures});

  @override
  Widget build(BuildContext context) {
    // Grouped by league so the list reads like a program guide rather than a
    // flat stream of unrelated matches.
    final order = <int>[];
    final grouped = <int, List<Fixture>>{};
    for (final f in fixtures) {
      if (!grouped.containsKey(f.leagueId)) order.add(f.leagueId);
      grouped.putIfAbsent(f.leagueId, () => []).add(f);
    }

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 4, bottom: 20),
      itemCount: order.length,
      itemBuilder: (context, index) {
        final leagueId = order[index];
        final leagueFixtures = grouped[leagueId]!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _LeagueHeader(fixture: leagueFixtures.first),
            for (final fixture in leagueFixtures) MatchCard(fixture: fixture),
            const SizedBox(height: 6),
          ],
        );
      },
    );
  }
}

class _LeagueHeader extends StatelessWidget {
  final Fixture fixture;
  const _LeagueHeader({required this.fixture});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 18,
            decoration: BoxDecoration(
              gradient: AppColors.redGradient,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              fixture.leagueName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textDirection: TextDirection.rtl,
              style: AppFonts.cairo(
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (fixture.round.isNotEmpty)
            Text(
              fixture.round,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.cairo(color: AppColors.textMuted, fontSize: 11),
            ),
        ],
      ),
    );
  }
}

class _DateStrip extends StatelessWidget {
  final DateTime selected;
  final ValueChanged<DateTime> onSelect;

  const _DateStrip({required this.selected, required this.onSelect});

  static const _weekdays = ['اثنين', 'ثلاثاء', 'أربعاء', 'خميس', 'جمعة', 'سبت', 'أحد'];

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final base = DateTime(today.year, today.month, today.day);
    final days = List.generate(7, (i) => base.add(Duration(days: i - 1)));

    return SizedBox(
      height: 64,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: days.length,
        itemBuilder: (context, index) {
          final date = days[index];
          final isSelected = date == selected;
          final isToday = date == base;
          final label = isToday
              ? 'اليوم'
              : date == base.add(const Duration(days: 1))
              ? 'غداً'
              : _weekdays[date.weekday - 1];

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: _SelectableChip(
              selected: isSelected,
              onTap: () => onSelect(date),
              width: 58,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    style: AppFonts.cairo(
                      color: isSelected ? Colors.white : AppColors.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${date.day}',
                    style: AppFonts.cairo(
                      color: isSelected ? Colors.white : AppColors.textSecondary,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _CompetitionStrip extends StatelessWidget {
  final int? selectedId;
  final ValueChanged<int?> onSelect;
  final bool showAllOption;

  const _CompetitionStrip({
    required this.selectedId,
    required this.onSelect,
    this.showAllOption = false,
  });

  @override
  Widget build(BuildContext context) {
    final items = Competition.all;
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          if (showAllOption)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _SelectableChip(
                selected: selectedId == null,
                onTap: () => onSelect(null),
                child: Text(
                  'الكل',
                  style: AppFonts.cairo(
                    color: selectedId == null ? Colors.white : AppColors.textMuted,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          for (final c in items)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _SelectableChip(
                selected: selectedId == c.id,
                onTap: () => onSelect(c.id),
                child: Text(
                  c.shortName,
                  style: AppFonts.cairo(
                    color: selectedId == c.id ? Colors.white : AppColors.textMuted,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Touch- and D-pad-selectable pill, shared by the date and competition
/// filter strips.
class _SelectableChip extends StatefulWidget {
  final bool selected;
  final VoidCallback onTap;
  final Widget child;
  final double? width;

  const _SelectableChip({
    required this.selected,
    required this.onTap,
    required this.child,
    this.width,
  });

  @override
  State<_SelectableChip> createState() => _SelectableChipState();
}

class _SelectableChipState extends State<_SelectableChip> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (focused) {
        if (_isFocused != focused) setState(() => _isFocused = focused);
      },
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: widget.width,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            gradient: widget.selected ? AppColors.redGradient : null,
            color: widget.selected ? null : Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: _isFocused
                  ? AppColors.accentRedLight
                  : widget.selected
                  ? Colors.transparent
                  : Colors.white.withValues(alpha: 0.08),
              width: _isFocused ? 1.6 : 1,
            ),
          ),
          child: Center(widthFactor: 1, child: widget.child),
        ),
      ),
    );
  }
}

// ── Standings tab ────────────────────────────────────────────────────────

class _StandingsTab extends StatefulWidget {
  const _StandingsTab();

  @override
  State<_StandingsTab> createState() => _StandingsTabState();
}

class _StandingsTabState extends State<_StandingsTab> {
  late int _selectedCompetitionId;
  late Future<List<List<Standing>>> _future;

  @override
  void initState() {
    super.initState();
    _selectedCompetitionId = Competition.all.first.id;
    _future = FootballApiService.standings(_selectedCompetitionId);
  }

  void _selectCompetition(int? id) {
    if (id == null || id == _selectedCompetitionId) return;
    setState(() {
      _selectedCompetitionId = id;
      _future = FootballApiService.standings(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 4),
        _CompetitionStrip(
          selectedId: _selectedCompetitionId,
          onSelect: _selectCompetition,
        ),
        const SizedBox(height: 4),
        Expanded(
          child: RefreshIndicator(
            color: AppColors.accentRedLight,
            backgroundColor: AppColors.surfaceDark,
            onRefresh: () async {
              final result = FootballApiService.standings(
                _selectedCompetitionId,
                forceRefresh: true,
              );
              setState(() => _future = result);
              await result;
            },
            child: FutureBuilder<List<List<Standing>>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(
                      color: AppColors.accentRedLight,
                    ),
                  );
                }
                final groups = snapshot.data ?? const [];
                if (groups.isEmpty) {
                  return _EmptyState(
                    message: 'الترتيب غير متاح حالياً لهذه البطولة',
                    onRetry: () => setState(
                      () => _future = FootballApiService.standings(
                        _selectedCompetitionId,
                        forceRefresh: true,
                      ),
                    ),
                  );
                }
                return StandingsTable(groups: groups);
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _EmptyState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.sports_soccer,
                    color: AppColors.textMuted,
                    size: 46,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    textDirection: TextDirection.rtl,
                    style: AppFonts.cairo(
                      color: AppColors.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(
                      Icons.refresh_rounded,
                      color: AppColors.accentRedLight,
                    ),
                    label: Text(
                      'إعادة المحاولة',
                      style: AppFonts.cairo(
                        color: AppColors.accentRedLight,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
