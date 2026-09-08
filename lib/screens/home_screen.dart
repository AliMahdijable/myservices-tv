import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shimmer/shimmer.dart';
import '../config/app_config.dart';
import '../models/channel.dart';
import '../services/channel_service.dart';
import '../services/fixtures_service.dart';
import '../theme/app_theme.dart';
import '../utils/channel_identity.dart';
import '../theme/layout_metrics.dart';
import '../widgets/category_section.dart';
import '../widgets/focusable_icon_button.dart';
import '../widgets/home_destination.dart';
import '../widgets/nav_rail.dart';
import '../widgets/home_bottom_nav.dart';
import 'player_screen.dart';
import 'fixtures_screen.dart';
import 'setup_screen.dart';
import 'search_screen.dart';
import '../services/favorites_service.dart';
import '../services/recently_watched_service.dart';

class HomeScreen extends StatefulWidget {
  final List<ChannelCategory>? preloadedCategories;

  const HomeScreen({super.key, this.preloadedCategories});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver {
  List<ChannelCategory> _categories = [];
  bool _isLoading = true;
  bool _isRefreshing = false;
  String? _errorMessage;
  DateTime? _lastBackPress;
  Set<String> _favoriteKeys = {};
  List<Channel> _favoriteChannels = [];
  List<Channel> _recentlyWatched = [];
  int _dynamicDataRequestId = 0;
  final ScrollController _homeScrollController = ScrollController();
  bool _openingPlayer = false;

  /// The channel most recently opened in the player, marked in the rails so
  /// the user can see where they left off.
  String? _playingKey;

  /// Whether the home server that serves fixtures is reachable. The
  /// destination stays hidden until it is — the feature is LAN-only.
  bool _fixturesAvailable = false;

  /// The destination the shell is showing.
  HomeDestination _destination = HomeDestination.home;

  /// Drives the swipe between destinations. A horizontal drag on the page
  /// background moves between them; a drag that starts on a channel rail or
  /// the day strip belongs to that rail, and the gesture arena gives it to the
  /// inner scrollable, which is what the user means by dragging a row.
  ///
  /// The app sets no [Directionality], so it lays out left-to-right and Arabic
  /// is right-aligned only by the strength of its own characters. Page 0 is
  /// therefore on the left, matching the bar's leftmost item, and dragging
  /// leftwards advances along the bar. Wrapping this screen in an RTL
  /// [Directionality] would mirror both, which is why the tests pump it the
  /// same way the app does rather than forcing a direction.
  final PageController _shellController = PageController();

  int get _totalChannels =>
      _categories.fold(0, (sum, cat) => sum + cat.channels.length);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.preloadedCategories != null &&
        widget.preloadedCategories!.isNotEmpty) {
      _categories = widget.preloadedCategories!;
      _isLoading = false;
      unawaited(_loadDynamicData());
    } else {
      unawaited(_loadChannels());
    }
    unawaited(_checkFixtures());
  }

  /// Re-asks whether the home server is reachable when the app comes back.
  ///
  /// A phone that left the house between one session and the next must stop
  /// offering a section that can no longer load, and one that came home must
  /// get it back — neither happens if the first answer is kept forever.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      FixturesService.invalidateAvailability();
      unawaited(_checkFixtures());
    }
  }

  Future<void> _checkFixtures() async {
    final available = await FixturesService.isAvailable();
    if (!mounted || available == _fixturesAvailable) return;
    setState(() {
      _fixturesAvailable = available;
      // Leaving the network while the section is open would otherwise leave
      // the shell pointing at a page the bar no longer offers.
      if (!available) _destination = HomeDestination.home;
    });
    if (!available && _shellController.hasClients) {
      _shellController.jumpToPage(HomeDestination.home.index);
    }
  }

  void _goTo(HomeDestination destination) {
    if (_destination == destination) return;
    if (destination == HomeDestination.fixtures && !_fixturesAvailable) return;
    setState(() => _destination = destination);
    if (_shellController.hasClients) {
      _shellController.animateToPage(
        destination.index,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shellController.dispose();
    _homeScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadChannels({bool forceRefresh = false}) async {
    final refreshInPlace = forceRefresh && _categories.isNotEmpty;
    setState(() {
      if (refreshInPlace) {
        _isRefreshing = true;
      } else {
        _isLoading = true;
      }
      _errorMessage = null;
    });

    try {
      final categories = await ChannelService.fetchCategories(
        forceRefresh: forceRefresh,
      );
      if (mounted) {
        setState(() {
          _categories = categories;
          _isLoading = false;
          _isRefreshing = false;
        });
        unawaited(_loadDynamicData());
      }
    } catch (_) {
      if (mounted) {
        if (refreshInPlace) {
          setState(() {
            _errorMessage = null;
            _isLoading = false;
            _isRefreshing = false;
          });
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  'تعذّر تحديث القنوات، تم الاحتفاظ بالقائمة الحالية',
                  textAlign: TextAlign.center,
                  style: AppFonts.cairo(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                duration: const Duration(seconds: 3),
                backgroundColor: AppColors.surfaceDark,
                behavior: SnackBarBehavior.floating,
                margin: const EdgeInsets.symmetric(
                  horizontal: 60,
                  vertical: 20,
                ),
              ),
            );
        } else {
          setState(() {
            _errorMessage = 'فشل في تحميل القنوات\nتحقق من اتصالك بالشبكة';
            _isLoading = false;
            _isRefreshing = false;
          });
        }
      }
    }
  }

  void _openPlayer(Channel channel, List<Channel> categoryChannels) {
    // Guards against a double tap/double OK-press pushing two PlayerScreen
    // routes (and two live native players) before the first push lands.
    if (_openingPlayer) return;
    _openingPlayer = true;
    setState(() => _playingKey = channelIdentityKey(channel));
    Navigator.of(context)
        .push(
          PageRouteBuilder(
            pageBuilder: (_, __, ___) =>
                PlayerScreen(channel: channel, categories: _categories),
            transitionsBuilder: (_, animation, __, child) =>
                FadeTransition(opacity: animation, child: child),
            transitionDuration: const Duration(milliseconds: 200),
          ),
        )
        .then((_) {
          _openingPlayer = false;
          if (mounted) unawaited(_loadDynamicData());
        });
  }

  void _openSettings() {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const SetupScreen(),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 200),
      ),
    );
  }

  Future<void> _loadDynamicData() async {
    final requestId = ++_dynamicDataRequestId;
    final categories = List<ChannelCategory>.unmodifiable(_categories);

    try {
      final results = await Future.wait<Object>([
        FavoritesService.getFavoriteKeys(),
        FavoritesService.getFavoriteChannels(categories),
        RecentlyWatchedService.getChannels(),
      ]);
      final favoriteKeys = results[0] as Set<String>;
      final favoriteChannels = results[1] as List<Channel>;
      final storedRecent = results[2] as List<Channel>;
      final recentChannels = _bindRecentToCurrent(storedRecent, categories);

      if (!mounted || requestId != _dynamicDataRequestId) return;
      final keepInitialPositionAtTop =
          _favoriteChannels.isEmpty &&
          _recentlyWatched.isEmpty &&
          (!_homeScrollController.hasClients ||
              _homeScrollController.offset <= 1);
      setState(() {
        _favoriteKeys = favoriteKeys;
        _favoriteChannels = favoriteChannels;
        _recentlyWatched = recentChannels;
      });
      if (keepInitialPositionAtTop &&
          (favoriteChannels.isNotEmpty || recentChannels.isNotEmpty)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _homeScrollController.hasClients) {
            _homeScrollController.jumpTo(0);
          }
        });
      }
    } catch (error) {
      debugPrint('Failed to load home dynamic data: $error');
    }
  }

  List<Channel> _bindRecentToCurrent(
    List<Channel> storedRecent,
    List<ChannelCategory> categories,
  ) {
    final byUrl = <String, Channel>{};
    final byStreamId = <int, Channel>{};
    final byTvgId = <String, Channel>{};
    final byNameAndGroup = <String, Channel>{};

    for (final channel in categories.expand((category) => category.channels)) {
      byUrl.putIfAbsent(channel.url, () => channel);
      if (channel.streamId > 0) {
        byStreamId.putIfAbsent(channel.streamId, () => channel);
      }
      final tvgId = channel.tvgId.trim().toLowerCase();
      if (tvgId.isNotEmpty) {
        byTvgId.putIfAbsent(tvgId, () => channel);
      }
      byNameAndGroup.putIfAbsent(_channelNameGroupKey(channel), () => channel);
    }

    final resolved = <Channel>[];
    final addedUrls = <String>{};
    for (final stored in storedRecent) {
      Channel? current = byUrl[stored.url];
      if (current == null && stored.streamId > 0) {
        current = byStreamId[stored.streamId];
      }
      final tvgId = stored.tvgId.trim().toLowerCase();
      if (current == null && tvgId.isNotEmpty) {
        current = byTvgId[tvgId];
      }
      current ??= byNameAndGroup[_channelNameGroupKey(stored)];

      if (current != null && addedUrls.add(current.url)) {
        resolved.add(current);
      }
    }
    return resolved;
  }

  String _channelNameGroupKey(Channel channel) =>
      '${channel.name.trim().toLowerCase()}\u0000'
      '${channel.group.trim().toLowerCase()}';

  void _openSearch() {
    if (_categories.isEmpty) return;
    Navigator.of(context)
        .push(
          PageRouteBuilder(
            pageBuilder: (_, __, ___) => SearchScreen(categories: _categories),
            transitionsBuilder: (_, animation, __, child) =>
                FadeTransition(opacity: animation, child: child),
            transitionDuration: const Duration(milliseconds: 200),
          ),
        )
        .then((_) {
          if (mounted) unawaited(_loadDynamicData());
        });
  }

  void _handleBackOnHome() {
    final now = DateTime.now();
    if (_lastBackPress != null &&
        now.difference(_lastBackPress!) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
    } else {
      _lastBackPress = now;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'اضغط مرة أخرى للخروج',
            textAlign: TextAlign.center,
            style: AppFonts.cairo(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          duration: const Duration(seconds: 2),
          backgroundColor: AppColors.accentRed.withValues(alpha: 0.9),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 60, vertical: 20),
        ),
      );
    }
  }

  // Rail navigation below this width doesn't leave enough room for content;
  // a bottom nav bar (mobile-native pattern) is used instead.
  static const double _railBreakpoint = 700;

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= _railBreakpoint;
    final content = Column(
      children: [
        _buildAppBar(),
        Expanded(
          child: _isLoading
              ? _buildLoadingShimmer()
              : _errorMessage != null
              ? _buildErrorView()
              : _categories.isEmpty
              ? _buildEmptyView()
              : _buildChannelsList(),
        ),
      ],
    );

    // Each destination keeps its own insets: the home page wants the 16dp
    // gutter its rails are drawn against, the fixtures page sets its own.
    final homePage = SafeArea(
      minimum: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      bottom: isWide,
      child: content,
    );

    final pages = <Widget>[
      homePage,
      if (_fixturesAvailable) const FixturesScreen(embedded: true),
    ];

    final shell = pages.length == 1
        ? homePage
        : PageView(
            controller: _shellController,
            onPageChanged: (index) {
              final destination = HomeDestination.values[index];
              if (_destination != destination) {
                setState(() => _destination = destination);
              }
            },
            children: pages,
          );

    return PopScope(
      // Back returns to the home page before it offers to leave the app —
      // otherwise the fixtures section would exit the app from a subpage.
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_destination != HomeDestination.home) {
          _goTo(HomeDestination.home);
          return;
        }
        _handleBackOnHome();
      },
      child: Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: AppColors.backgroundGradient,
          ),
          child: isWide
              ? Row(
                  children: [
                    Expanded(child: shell),
                    SafeArea(
                      minimum: const EdgeInsets.symmetric(vertical: 8),
                      child: NavRail(
                        active: _destination,
                        onHomeTap: () => _goTo(HomeDestination.home),
                        onFixturesTap: _fixturesAvailable
                            ? () => _goTo(HomeDestination.fixtures)
                            : null,
                        searchEnabled: _categories.isNotEmpty,
                        onSearchTap: _openSearch,
                        onSettingsTap: _openSettings,
                      ),
                    ),
                  ],
                )
              : shell,
        ),
        bottomNavigationBar: isWide
            ? null
            : HomeBottomNav(
                active: _destination,
                onHomeTap: () => _goTo(HomeDestination.home),
                onFixturesTap: _fixturesAvailable
                    ? () => _goTo(HomeDestination.fixtures)
                    : null,
                searchEnabled: _categories.isNotEmpty,
                onSearchTap: _openSearch,
                onSettingsTap: _openSettings,
              ),
      ),
    );
  }

  Widget _buildAppBar() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Beside the nav rail on a narrow window the fixed logo, badge and
        // refresh button together exceed the width — the tagline is already
        // Expanded and cannot give up any more room. The channel count is the
        // least useful of the three at that size, so it goes first.
        final showChannelCount =
            _totalChannels > 0 && constraints.maxWidth >= 220;
        return _buildAppBarRow(showChannelCount: showChannelCount);
      },
    );
  }

  Widget _buildAppBarRow({required bool showChannelCount}) {
    final isWide = screenClassOf(context) == ScreenClass.wide;
    final inset = isWide ? 24.0 : 16.0;

    return Container(
      padding: EdgeInsets.fromLTRB(inset, 12, inset, 10),
      child: Row(
        children: [
          Container(
            width: isWide ? 52 : 44,
            height: isWide ? 52 : 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              boxShadow: [
                BoxShadow(
                  color: AppColors.accentRed.withValues(alpha: 0.22),
                  blurRadius: 16,
                  spreadRadius: -2,
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(13),
              child: Image.asset('assets/images/logo.png', fit: BoxFit.contain),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Promoted from a muted 12px caption to the headline it always
                // should have been — the app bar previously led with nothing.
                Text(
                  'شاشتك لمشاهدة المباريات',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.cairo(
                    color: AppColors.textPrimary,
                    fontSize: isWide ? 20 : 17,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                    height: 1.15,
                  ),
                ),
                if (_totalChannels > 0) ...[
                  const SizedBox(height: 2),
                  Text(
                    '$_totalChannels قناة مباشرة',
                    textDirection: TextDirection.rtl,
                    style: AppFonts.cairo(
                      color: AppColors.textMuted,
                      fontSize: isWide ? 13 : 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (showChannelCount && isWide) ...[
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.accentRed.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: AppColors.accentRed.withValues(alpha: 0.4),
                ),
              ),
              child: Row(
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
                  const SizedBox(width: 6),
                  Text(
                    'مباشر',
                    style: AppFonts.cairo(
                      color: AppColors.accentRedLight,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(width: 8),
          FocusableIconButton(
            icon: Icons.refresh_rounded,
            semanticLabel: 'تحديث القنوات',
            isLoading: _isRefreshing,
            onTap: _isRefreshing || _isLoading
                ? null
                : () => _loadChannels(forceRefresh: true),
          ),
        ],
      ),
    );
  }

  Widget _buildChannelsList() {
    final hasRecent = _recentlyWatched.isNotEmpty;
    final hasFavs = _favoriteChannels.isNotEmpty;
    final extra = (hasRecent ? 1 : 0) + (hasFavs ? 1 : 0);
    final sectionIndexes = <Key, int>{};
    var sectionIndex = 0;
    if (hasRecent) {
      sectionIndexes[const ValueKey<String>('special:recent')] = sectionIndex++;
    }
    if (hasFavs) {
      sectionIndexes[const ValueKey<String>('special:favorites')] =
          sectionIndex++;
    }
    for (final category in _categories) {
      sectionIndexes[_categorySectionKey(category)] = sectionIndex++;
    }
    sectionIndexes[const ValueKey<String>('home-copyright')] = sectionIndex;

    return ListView.builder(
      controller: _homeScrollController,
      physics: const ClampingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      itemCount: _categories.length + extra + 1,
      findChildIndexCallback: (key) => sectionIndexes[key],
      itemBuilder: (context, index) {
        int i = index;

        if (hasRecent) {
          if (i == 0) {
            return _buildSpecialSection(
              sectionKey: 'recent',
              displayName: 'شاهدت مؤخراً',
              icon: Icons.history_rounded,
              channels: _recentlyWatched,
              isFirst: true,
            );
          }
          i--;
        }

        if (hasFavs) {
          if (i == 0) {
            return _buildSpecialSection(
              sectionKey: 'favorites',
              displayName: 'المفضلة',
              icon: Icons.favorite_rounded,
              channels: _favoriteChannels,
              isFirst: !hasRecent,
            );
          }
          i--;
        }

        if (i == _categories.length) {
          return KeyedSubtree(
            key: const ValueKey<String>('home-copyright'),
            child: _buildCopyright(),
          );
        }

        final category = _categories[i];
        return CategorySection(
          key: _categorySectionKey(category),
          category: category,
          onChannelTap: _openPlayer,
          isFirstCategory: i == 0 && extra == 0,
          favoriteKeys: _favoriteKeys,
          playingKey: _playingKey,
        );
      },
    );
  }

  Key _categorySectionKey(ChannelCategory category) =>
      ValueKey<String>('category:${category.name}:${category.sortOrder}');

  Widget _buildSpecialSection({
    required String sectionKey,
    required String displayName,
    required IconData icon,
    required List<Channel> channels,
    bool isFirst = false,
  }) {
    final cat = ChannelCategory(
      name: displayName,
      displayName: displayName,
      channels: channels,
      sortOrder: -1,
    );
    return CategorySection(
      key: ValueKey<String>('special:$sectionKey'),
      category: cat,
      onChannelTap: _openPlayer,
      isFirstCategory: isFirst,
      favoriteKeys: _favoriteKeys,
      iconOverride: icon,
      playingKey: _playingKey,
    );
  }

  Widget _buildCopyright() {
    final year = DateTime.now().year;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      child: Column(
        children: [
          Divider(color: Colors.white.withValues(alpha: 0.06), thickness: 1),
          const SizedBox(height: 12),
          Image.asset('assets/images/logo.png', width: 30, height: 30),
          const SizedBox(height: 8),
          Text(
            'الإصدار ${AppConfig.appVersion}',
            style: AppFonts.cairo(color: AppColors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            'جميع الحقوق محفوظة $year ©',
            style: AppFonts.cairo(color: AppColors.textMuted, fontSize: 12),
            textDirection: TextDirection.rtl,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildLoadingShimmer() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: 4,
      itemBuilder: (context, index) {
        return Shimmer.fromColors(
          baseColor: AppColors.surfaceDark,
          highlightColor: AppColors.cardDark,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 180,
                height: 28,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              SizedBox(
                height: 185,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: 5,
                  itemBuilder: (context, i) {
                    return Container(
                      width: 140,
                      margin: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.surfaceDark.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(
                Icons.tv_off_rounded,
                color: AppColors.textMuted,
                size: 60,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'لا توجد قنوات متاحة',
              textAlign: TextAlign.center,
              textDirection: TextDirection.rtl,
              style: AppFonts.cairo(
                color: AppColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'حدّث القائمة أو راجع إعدادات مصدر القنوات',
              textAlign: TextAlign.center,
              textDirection: TextDirection.rtl,
              style: AppFonts.cairo(
                color: AppColors.textSecondary,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 24),
            FocusTraversalGroup(
              policy: WidgetOrderTraversalPolicy(),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    autofocus: true,
                    onPressed: () => _loadChannels(forceRefresh: true),
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(
                      'تحديث القائمة',
                      style: AppFonts.cairo(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accentRed,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 13,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: _openSettings,
                    icon: const Icon(Icons.settings_rounded),
                    label: Text(
                      'الإعدادات',
                      style: AppFonts.cairo(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.surfaceDark,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 13,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.accentRed.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(
                Icons.wifi_off_rounded,
                color: AppColors.accentRed,
                size: 60,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              _errorMessage ?? 'حدث خطأ',
              textAlign: TextAlign.center,
              textDirection: TextDirection.rtl,
              style: AppFonts.cairo(
                color: AppColors.textSecondary,
                fontSize: 18,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            FocusTraversalGroup(
              policy: WidgetOrderTraversalPolicy(),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    autofocus: true,
                    onPressed: () => _loadChannels(forceRefresh: true),
                    icon: const Icon(Icons.refresh),
                    label: Text(
                      'إعادة المحاولة',
                      style: AppFonts.cairo(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accentRed,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 13,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: _openSettings,
                    icon: const Icon(Icons.settings),
                    label: Text(
                      'الإعدادات',
                      style: AppFonts.cairo(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.surfaceDark,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 13,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
