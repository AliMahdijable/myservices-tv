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
  /// True when this is a page of the home shell rather than its own route.
  /// The shell paints the background for every destination and already
  /// provides a way back via its own nav bar, so an embedded instance skips
  /// both the gradient (avoiding a second, darker layer over the shell's)
  /// and the back button.
  final bool embedded;

  const MatchesScreen({super.key, this.embedded = false});

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
    final body = SafeArea(
      bottom: !widget.embedded,
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
    );

    if (widget.embedded) return body;
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.backgroundGradient),
        child: body,
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Row(
        children: [
          if (!widget.embedded) ...[
            FocusableIconButton(
              icon: Icons.arrow_forward_rounded,
              semanticLabel: 'رجوع',
              autofocus: true,
              onTap: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 12),
          ] else ...[
            Container(
              width: 4,
              height: 22,
              decoration: BoxDecoration(
                gradient: AppColors.redGradient,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: 12),
          ],
          // The back button and the accent bar are fixed widths, so the title
          // is the only child that can give way — without this the row
          // overflowed by 88dp at text scale 2 and 268dp at 3.
          Expanded(
            child: Text(
              'المباريات',
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
  }

  Widget _buildTabBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
      ),
      // A TabBar sizes itself to a fixed height, so its labels clip instead of
      // overflowing — at 3x 'الترتيب' was handed 46dp for a line needing 60
      // and lost its lower half without raising anything.
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
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
  late Future<FixturesResult> _future;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDate = DateTime(now.year, now.month, now.day);
    _future = _load();
  }

  Future<FixturesResult> _load({bool forceRefresh = false}) {
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
            child: FutureBuilder<FixturesResult>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(
                      color: AppColors.accentRedLight,
                    ),
                  );
                }
                final result =
                    snapshot.data ??
                    const FixturesResult([], failedLeagueIds: [-1]);

                // Nothing came back and something went wrong: saying "no
                // matches today" here is a confident lie, and the user has no
                // way to tell it from a real quiet Tuesday.
                if (result.fixtures.isEmpty) {
                  return _EmptyState(
                    message: result.hasFailures
                        ? 'تعذّر تحميل المباريات — تحقّق من الاتصال'
                        : 'لا توجد مباريات في هذا اليوم',
                    onRetry: () => _reload(forceRefresh: true),
                  );
                }

                // Some leagues answered and some did not. Showing the ones
                // that did, silently, would tell the user their league has no
                // match today when nobody actually asked.
                return Column(
                  children: [
                    if (result.hasFailures)
                      _PartialFailureBanner(
                        leagueIds: result.failedLeagueIds,
                        onRetry: () => _reload(forceRefresh: true),
                      ),
                    Expanded(child: _FixturesList(fixtures: result.fixtures)),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// Says which competitions are missing from the list below it, so a partial
/// answer is never mistaken for a complete one.
class _PartialFailureBanner extends StatelessWidget {
  final List<int> leagueIds;
  final VoidCallback onRetry;

  const _PartialFailureBanner({required this.leagueIds, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final names = leagueIds
        .map((id) => Competition.find(id)?.shortName)
        .whereType<String>()
        .toList();
    final what = names.isEmpty
        ? 'بعض الدوريات'
        : names.length <= 3
        ? names.join('، ')
        : '${names.take(3).join('، ')} و${names.length - 3} غيرها';

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.accentRed.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.accentRed.withValues(alpha: 0.35)),
      ),
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: Row(
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              size: 16,
              color: AppColors.accentRedLight,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'تعذّر تحميل $what',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textDirection: TextDirection.rtl,
                style: AppFonts.cairo(
                  color: AppColors.textSecondary,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onRetry,
              child: Text(
                'إعادة',
                style: AppFonts.cairo(
                  color: AppColors.accentRedLight,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
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
              // The API names its leagues in English; the app already carries
              // an Arabic name for every competition it asks about.
              Competition.nameFor(fixture.leagueId, fixture.leagueName),
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
          if (fixture.round.isNotEmpty) ...[
            // The name sits in an Expanded that eats the whole row, so without
            // a gap the round text sat flush against it and the two read as
            // one run-on word: "La LigaRegular Season - 5".
            const SizedBox(width: 10),
            Text(
              _roundLabel(fixture.round),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.cairo(color: AppColors.textMuted, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  /// API-Football writes the round in English — "Regular Season - 5",
  /// "Round of 16". Numbered rounds are the overwhelming majority, so they are
  /// matched by shape rather than by listing every competition's wording.
  static String _roundLabel(String raw) {
    final numbered = RegExp(r'-\s*(\d+)\s*$').firstMatch(raw);
    if (numbered != null) return 'الجولة ${numbered.group(1)}';

    const knockout = <String, String>{
      'Group Stage': 'دور المجموعات',
      'Round of 16': 'دور الـ16',
      'Quarter-finals': 'ربع النهائي',
      'Semi-finals': 'نصف النهائي',
      'Final': 'النهائي',
      '3rd Place Final': 'تحديد المركز الثالث',
      'Preliminary Round': 'الدور التمهيدي',
    };
    // Anything unrecognised is shown as the API sent it: an English round is
    // less confusing than a wrong Arabic one.
    return knockout[raw.trim()] ?? raw;
  }
}

class _DateStrip extends StatelessWidget {
  final DateTime selected;
  final ValueChanged<DateTime> onSelect;

  const _DateStrip({required this.selected, required this.onSelect});

  static const _weekdays = [
    'اثنين',
    'ثلاثاء',
    'أربعاء',
    'خميس',
    'جمعة',
    'سبت',
    'أحد',
  ];

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final base = DateTime(today.year, today.month, today.day);
    final days = List.generate(7, (i) => base.add(Duration(days: i - 1)));

    // Two lines of text in a fixed box cannot absorb a larger system font on
    // their own: the height has to follow the text, and the text has to stop
    // growing somewhere or no height would ever be enough.
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: SizedBox(
        height: scaler.scale(52),
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
                minWidth: 46,
                // A date reads as a card, not as a button: square enough to sit
                // in a row of dates, and tight enough that a week of them fits a
                // phone without the strip dominating the screen.
                radius: 10,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      style: AppFonts.cairo(
                        color: isSelected
                            ? Colors.white.withValues(alpha: 0.85)
                            : AppColors.textMuted,
                        fontSize: 9.5,
                        height: 1.1,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      '${date.day}',
                      maxLines: 1,
                      style: AppFonts.cairo(
                        color: isSelected
                            ? Colors.white
                            : AppColors.textPrimary,
                        fontSize: 14,
                        height: 1.15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
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
    // A Text that does not fit its box clips silently instead of reporting an
    // overflow, so at a larger font the league names lost their lower half
    // with nothing in the logs.
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: SizedBox(
        height: scaler.scale(34),
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
                      color: selectedId == null
                          ? Colors.white
                          : AppColors.textMuted,
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
                      color: selectedId == c.id
                          ? Colors.white
                          : AppColors.textMuted,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
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

  /// A floor, not a fixed size. Pinning the width to 58 left the label 28dp
  /// between the padding and the border — narrower than 'جمعة' at the default
  /// text size, so the word wrapped and burst the strip's fixed height.
  final double? minWidth;

  /// Fully round suits a one-word filter pill. A date chip stacks two lines
  /// and reads as a card; that tall, a lozenge looks like a stretched button.
  final double radius;

  final EdgeInsets padding;

  const _SelectableChip({
    required this.selected,
    required this.onTap,
    required this.child,
    this.minWidth,
    this.radius = 999,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
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
          constraints: BoxConstraints(minWidth: widget.minWidth ?? 0),
          padding: widget.padding,
          decoration: BoxDecoration(
            gradient: widget.selected ? AppColors.redGradient : null,
            color: widget.selected
                ? null
                : Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(widget.radius),
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
