import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/competition.dart';
import '../models/fixture.dart';
import '../models/standing.dart';
import '../services/football_api_service.dart';
import '../services/match_alerts_service.dart';
import '../theme/app_theme.dart';
import 'alert_settings_screen.dart';
import '../widgets/focusable_icon_button.dart';
import '../widgets/match_card.dart';
import '../widgets/standings_table.dart';

class MatchesScreen extends StatefulWidget {
  /// Whether this page is the one the user is looking at.
  ///
  /// The page keeps its state, so being built says nothing about being seen —
  /// it stays alive behind the home page and behind the standings tab. Passed
  /// down rather than signalled, because a signal only fires on the paths
  /// someone remembered to wire: tapping the bar went through it and swiping
  /// to the page did not.
  final bool active;

  /// True when this is a page of the home shell rather than its own route.
  /// The shell paints the background for every destination and already
  /// provides a way back via its own nav bar, so an embedded instance skips
  /// both the gradient (avoiding a second, darker layer over the shell's)
  /// and the back button.
  final bool embedded;

  const MatchesScreen({super.key, this.embedded = false, this.active = true});

  @override
  State<MatchesScreen> createState() => _MatchesScreenState();
}

class _MatchesScreenState extends State<MatchesScreen>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  /// Kept alive so leaving for the home page and coming back does not throw
  /// the day away and reload it — which is what put a spinner, and then a
  /// league error, in front of the user every time they returned.
  @override
  bool get wantKeepAlive => true;

  late final TabController _tabController;

  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (_tabController.index != _tabIndex) {
        setState(() => _tabIndex = _tabController.index);
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Required by the keep-alive mixin: it registers the handler that stops
    // this page being thrown away when the shell scrolls past it.
    super.build(context);
    final body = SafeArea(
      bottom: !widget.embedded,
      child: Column(
        children: [
          _buildHeader(),
          _buildTabBar(),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _ScheduleTab(active: widget.active && _tabIndex == 0),
                _StandingsTab(active: widget.active && _tabIndex == 1),
              ],
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
          // One place that answers "what have I agreed to, and how do I stop
          // it" — a feature that can wake a phone at night needs one.
          FocusableIconButton(
            icon: Icons.notifications_none_rounded,
            semanticLabel: 'تنبيهات المباريات',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AlertSettingsScreen(),
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
  /// Whether this tab is the one on screen — the matches page is showing and
  /// the schedule tab is selected within it.
  final bool active;

  const _ScheduleTab({required this.active});

  @override
  State<_ScheduleTab> createState() => _ScheduleTabState();
}

class _ScheduleTabState extends State<_ScheduleTab>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  /// A TabBarView disposes the tab you are not looking at. Without this,
  /// switching to the standings and back threw away the selected day and the
  /// fixtures under it, and reloaded both.
  @override
  bool get wantKeepAlive => true;

  late DateTime _selectedDate;
  int? _selectedCompetitionId;

  /// What is on screen, and the selection it belongs to. Held rather than
  /// rebuilt from a Future: a FutureBuilder handed a new future blanks the
  /// list and shows a spinner, on every return to this page.
  FixturesResult? _data;

  /// The selection [_data] was loaded for. Anything else would be last
  /// Tuesday's fixtures under today's heading.
  String? _dataKey;

  /// Only to debounce a rapid flick back and forth. Whether the data is
  /// current is the service cache's business; two clocks measuring the same
  /// thing eventually disagree.
  DateTime? _loadedAt;

  bool _loading = false;
  bool _refreshing = false;

  /// The last refresh of this selection failed. What is below is still shown —
  /// it is the best we have — but it is not claimed as current.
  bool _refreshFailed = false;

  int _loadToken = 0;

  /// A flick to the other tab and back should not re-run the load; anything
  /// longer asks again and lets the service's cache answer for free if it can.
  static const Duration _reloadDebounce = Duration(seconds: 5);

  String get _selectionKey =>
      '${_selectedDate.toIso8601String()}|${_selectedCompetitionId ?? 'all'}';

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDate = DateTime(now.year, now.month, now.day);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_startLoad());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Coming back from the background is when the fixtures on screen are most
  /// likely to be stale, and when the user is looking at them.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Only when this tab is the one being looked at. Keeping state alive means
    // it is still here behind the home page and behind the standings tab, and
    // a hidden page has no business spending a request.
    if (state == AppLifecycleState.resumed && widget.active) refreshIfStale();
  }

  /// Reloads unless the page was loaded moments ago. No timer stands behind
  /// it: a screen nobody is looking at has no business spending requests.
  /// Becoming visible is the moment to reconsider what is on screen. This is
  /// the only path: it fires whether the user tapped the bar, swiped the
  /// shell, or came back from the standings tab.
  @override
  void didUpdateWidget(_ScheduleTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.active && widget.active) refreshIfStale();
  }

  void refreshIfStale() {
    if (!mounted || _loading || _refreshing) return;
    final loadedAt = _loadedAt;
    if (!_refreshFailed &&
        loadedAt != null &&
        DateTime.now().difference(loadedAt) < _reloadDebounce) {
      return;
    }
    // Deliberately not forceRefresh: the service decides whether this needs
    // the network. Inside its window it answers from cache and costs nothing;
    // outside it, one paced sweep.
    unawaited(_startLoad(quiet: _data != null));
  }

  Future<void> _startLoad({
    bool quiet = false,
    bool forceRefresh = false,
  }) async {
    final key = _selectionKey;
    final token = ++_loadToken;

    setState(() {
      if (quiet) {
        _refreshing = true;
      } else {
        _loading = true;
        _data = null;
        _dataKey = null;
        _refreshFailed = false;
      }
    });

    FixturesResult result;
    try {
      result = await _fetch(forceRefresh: forceRefresh);
    } catch (_) {
      result = const FixturesResult([], failedLeagueIds: [-1]);
    }

    // The user moved on while this was in the air. Showing it now would put
    // one selection's fixtures under another's heading.
    if (!mounted || token != _loadToken || key != _selectionKey) return;

    setState(() {
      _loading = false;
      _refreshing = false;
      if (result.fixtures.isEmpty && result.hasFailures && _data != null) {
        // Nothing came back and something broke, but an answer is already on
        // screen. Keep it, and say it could not be refreshed.
        _refreshFailed = true;
      } else {
        _data = result;
        _dataKey = key;
        _loadedAt = DateTime.now();
        _refreshFailed = false;
      }
    });
  }

  Future<FixturesResult> _fetch({bool forceRefresh = false}) {
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
    unawaited(_startLoad(quiet: _data != null, forceRefresh: forceRefresh));
  }

  /// Re-asks only the competitions that did not answer, keeping the rest.
  Future<void> _retryFailed() async {
    final current = _data;
    if (current == null || !current.hasFailures) return;
    final key = _selectionKey;
    final token = ++_loadToken;
    setState(() => _refreshing = true);

    final merged = await FootballApiService.retryFailed(_selectedDate, current);
    if (!mounted || token != _loadToken || key != _selectionKey) return;
    setState(() {
      _refreshing = false;
      _data = merged;
      _dataKey = key;
      _loadedAt = DateTime.now();
      _refreshFailed = false;
    });
  }

  void _selectDate(DateTime date) {
    if (date == _selectedDate) return;
    setState(() => _selectedDate = date);
    unawaited(_startLoad());
  }

  void _selectCompetition(int? id) {
    if (id == _selectedCompetitionId) return;
    setState(() => _selectedCompetitionId = id);
    unawaited(_startLoad());
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
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
            onRefresh: () => _startLoad(quiet: true, forceRefresh: true),
            child: _body(),
          ),
        ),
      ],
    );
  }

  Widget _body() {
    // A first load for this selection: there is nothing honest to show yet.
    if (_loading || _dataKey == null) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.accentRedLight),
      );
    }

    final result = _data ?? const FixturesResult([], failedLeagueIds: [-1]);

    // A postponed match keeps its bell only if the stored kickoff follows the
    // fixture; otherwise it expires against a time it no longer has.
    if (result.fixtures.isNotEmpty) {
      unawaited(MatchAlertsService.instance.noteFixtures(result.fixtures));
    }

    if (result.fixtures.isEmpty) {
      // Nothing came back and something went wrong: saying "no matches today"
      // here is a confident lie, and the user cannot tell it from a real quiet
      // Tuesday.
      // An empty day that failed to refresh is not a quiet day. Reading
      // hasFailures alone missed this: the last good answer was genuinely
      // empty, so the failure lived in _refreshFailed instead.
      final failed = result.hasFailures || _refreshFailed;
      return _EmptyState(
        message: failed
            ? 'تعذّر تحميل المباريات — تحقّق من الاتصال'
            : 'لا توجد مباريات في هذا اليوم',
        onRetry: () => _reload(forceRefresh: true),
      );
    }

    return Column(
      children: [
        // A refresh of what is already on screen says so in a thin line,
        // rather than replacing the list with a spinner.
        if (_refreshing) const _RefreshingStrip(),
        if (result.hasFailures)
          _PartialFailureBanner(
            leagueIds: result.failedLeagueIds,
            onRetry: _retryFailed,
          )
        else if (_refreshFailed)
          _PartialFailureBanner(
            leagueIds: const [],
            onRetry: () => _reload(forceRefresh: true),
          ),
        Expanded(child: _FixturesList(fixtures: result.fixtures)),
      ],
    );
  }
}

/// A hairline that says a reload is happening without taking the list away.
class _RefreshingStrip extends StatelessWidget {
  const _RefreshingStrip();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 2),
    child: LinearProgressIndicator(
      minHeight: 2,
      backgroundColor: Colors.transparent,
      color: AppColors.accentRedLight,
    ),
  );
}

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
    final grouped = <int, List<Fixture>>{};
    for (final f in fixtures) {
      grouped.putIfAbsent(f.leagueId, () => []).add(f);
    }

    // Sections follow the running order in Competition.all — Champions first,
    // Arab competitions last. They used to follow whichever league happened to
    // kick off earliest, so an early Saudi fixture pushed the Champions League
    // to the bottom of the day. Matches inside a section keep their kickoff
    // order, which is the order they arrived in.
    final order = grouped.keys.toList()
      ..sort((a, b) {
        final byRank = Competition.displayRank(
          a,
        ).compareTo(Competition.displayRank(b));
        if (byRank != 0) return byRank;
        // Two competitions the app does not list: keep the earlier one first.
        return grouped[a]!.first.kickoff.compareTo(grouped[b]!.first.kickoff);
      });

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
  /// Whether this tab is the one on screen — see [_ScheduleTab.active].
  final bool active;

  const _StandingsTab({required this.active});

  @override
  State<_StandingsTab> createState() => _StandingsTabState();
}

class _StandingsTabState extends State<_StandingsTab>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  /// Same reason as the schedule tab: a TabBarView disposes the one you are
  /// not looking at, and coming back should not mean loading a table again.
  @override
  bool get wantKeepAlive => true;

  late int _selectedCompetitionId;

  List<List<Standing>>? _groups;
  int? _dataCompetitionId;
  DateTime? _loadedAt;
  bool _loading = false;
  bool _refreshing = false;
  bool _refreshFailed = false;
  int _loadToken = 0;

  static const Duration _reloadDebounce = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _selectedCompetitionId = Competition.all.first.id;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_startLoad());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didUpdateWidget(_StandingsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.active && widget.active) _refreshIfStale();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && widget.active) _refreshIfStale();
  }

  void _refreshIfStale() {
    if (!mounted || _loading || _refreshing) return;
    final loadedAt = _loadedAt;
    if (!_refreshFailed &&
        loadedAt != null &&
        DateTime.now().difference(loadedAt) < _reloadDebounce) {
      return;
    }
    // Not forceRefresh: the service's ten-minute window answers this for free
    // when it can. A table moves far more slowly than a fixture list.
    unawaited(_startLoad(quiet: _groups != null));
  }

  Future<void> _startLoad({
    bool quiet = false,
    bool forceRefresh = false,
  }) async {
    final competitionId = _selectedCompetitionId;
    final token = ++_loadToken;

    setState(() {
      if (quiet) {
        _refreshing = true;
      } else {
        _loading = true;
        _groups = null;
        _dataCompetitionId = null;
        _refreshFailed = false;
      }
    });

    StandingsResult result;
    try {
      result = await FootballApiService.standings(
        competitionId,
        forceRefresh: forceRefresh,
      );
    } catch (_) {
      result = const StandingsResult([], answered: false);
    }

    // The user picked another competition while this was in the air.
    if (!mounted ||
        token != _loadToken ||
        competitionId != _selectedCompetitionId) {
      return;
    }

    setState(() {
      _loading = false;
      _refreshing = false;
      // Set either way. It marks "a load has finished for this competition",
      // not "a load succeeded" — leaving it null on a first failure left the
      // tab on a spinner that nothing would ever clear.
      _dataCompetitionId = competitionId;
      if (!result.answered) {
        // A cached table may have come with it. Keep whatever is on screen and
        // say the refresh did not succeed: a non-empty cache used to read as a
        // successful load.
        _refreshFailed = true;
        if (_groups == null && result.groups.isNotEmpty) {
          _groups = result.groups;
        }
      } else {
        _groups = result.groups;
        _loadedAt = DateTime.now();
        _refreshFailed = false;
      }
    });
  }

  void _selectCompetition(int? id) {
    if (id == null || id == _selectedCompetitionId) return;
    setState(() => _selectedCompetitionId = id);
    unawaited(_startLoad());
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
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
            onRefresh: () => _startLoad(quiet: true, forceRefresh: true),
            child: _body(),
          ),
        ),
      ],
    );
  }

  Widget _body() {
    if (_loading || _dataCompetitionId == null) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.accentRedLight),
      );
    }

    final groups = _groups ?? const <List<Standing>>[];
    if (groups.isEmpty) {
      return _EmptyState(
        message: _refreshFailed
            ? 'تعذّر تحديث الترتيب — تحقّق من الاتصال'
            : 'الترتيب غير متاح حالياً لهذه البطولة',
        onRetry: () => _startLoad(quiet: _groups != null, forceRefresh: true),
      );
    }

    return Column(
      children: [
        if (_refreshing) const _RefreshingStrip(),
        if (_refreshFailed)
          _PartialFailureBanner(
            leagueIds: const [],
            onRetry: () => _startLoad(quiet: true, forceRefresh: true),
          ),
        // Straight into the Expanded: StandingsTable is a ListView itself, and
        // nesting it in another one gives it no height to lay out in.
        Expanded(child: StandingsTable(groups: groups)),
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
