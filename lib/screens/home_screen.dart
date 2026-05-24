import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shimmer/shimmer.dart';
import '../config/app_config.dart';
import '../models/channel.dart';
import '../services/channel_service.dart';
import '../theme/app_theme.dart';
import '../widgets/category_section.dart';
import 'player_screen.dart';
import 'setup_screen.dart';

class HomeScreen extends StatefulWidget {
  final List<ChannelCategory>? preloadedCategories;

  const HomeScreen({super.key, this.preloadedCategories});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<ChannelCategory> _categories = [];
  bool _isLoading = true;
  bool _isRefreshing = false;
  String? _errorMessage;
  DateTime? _lastBackPress;

  int get _totalChannels =>
      _categories.fold(0, (sum, cat) => sum + cat.channels.length);

  @override
  void initState() {
    super.initState();
    if (widget.preloadedCategories != null &&
        widget.preloadedCategories!.isNotEmpty) {
      _categories = widget.preloadedCategories!;
      _isLoading = false;
    } else {
      _loadChannels();
    }
  }

  Future<void> _loadChannels({bool forceRefresh = false}) async {
    setState(() {
      if (forceRefresh) {
        _isRefreshing = true;
      } else {
        _isLoading = true;
      }
      _errorMessage = null;
    });

    try {
      final categories =
          await ChannelService.fetchCategories(forceRefresh: forceRefresh);
      if (mounted) {
        setState(() {
          _categories = categories;
          _isLoading = false;
          _isRefreshing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'فشل في تحميل القنوات\nتحقق من اتصالك بالشبكة';
          _isLoading = false;
          _isRefreshing = false;
        });
      }
    }
  }

  void _openPlayer(Channel channel, List<Channel> categoryChannels) {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => PlayerScreen(
          channel: channel,
          categories: _categories,
        ),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 200),
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const SetupScreen(),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 200),
      ),
    ).then((_) {
      // Reload channels if server was changed
      if (mounted) _loadChannels(forceRefresh: true);
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

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBackOnHome();
      },
      child: Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: AppColors.backgroundGradient,
          ),
          child: SafeArea(
            child: Column(
              children: [
                _buildAppBar(),
                Expanded(
                  child: _isLoading
                      ? _buildLoadingShimmer()
                      : _errorMessage != null
                          ? _buildErrorView()
                          : _buildChannelsList(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: AppColors.accentRed.withValues(alpha: 0.2),
                  blurRadius: 12,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset(
                'assets/images/logo.png',
                fit: BoxFit.contain,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'MyServices TV',
                  style: AppFonts.cairo(
                    color: AppColors.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
                Text(
                  'شاشتك لمشاهدة المباريات',
                  style: AppFonts.cairo(
                    color: AppColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (_totalChannels > 0)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: AppColors.surfaceDark,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.live_tv,
                      color: AppColors.accentRedLight, size: 15),
                  const SizedBox(width: 4),
                  Text(
                    '$_totalChannels',
                    style: AppFonts.cairo(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          _FocusableIconButton(
            icon: Icons.refresh_rounded,
            isLoading: _isRefreshing,
            onTap: _isRefreshing
                ? null
                : () => _loadChannels(forceRefresh: true),
          ),
          const SizedBox(width: 6),
          if (AppConfig.baseUrl != AppConfig.defaultBaseUrl ||
              AppConfig.username != AppConfig.defaultUsername)
            _FocusableIconButton(
              icon: Icons.settings_rounded,
              onTap: _openSettings,
            ),
        ],
      ),
    );
  }

  Widget _buildChannelsList() {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Column(
        children: [
          for (int i = 0; i < _categories.length; i++)
            CategorySection(
              category: _categories[i],
              onChannelTap: _openPlayer,
              isFirstCategory: i == 0,
            ),
          _buildCopyright(),
        ],
      ),
    );
  }

  Widget _buildCopyright() {
    final year = DateTime.now().year;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      child: Column(
        children: [
          Divider(
            color: Colors.white.withValues(alpha: 0.06),
            thickness: 1,
          ),
          const SizedBox(height: 12),
          Image.asset('assets/images/logo.png', width: 30, height: 30),
          const SizedBox(height: 8),
          Text(
            'الإصدار ${AppConfig.appVersion}',
            style: AppFonts.cairo(color: AppColors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            'جميع الحقوق محفوظة لمجموعة خدماتي $year ©',
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
              child: const Icon(Icons.wifi_off_rounded,
                  color: AppColors.accentRed, size: 60),
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
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: () => _loadChannels(forceRefresh: true),
                  icon: const Icon(Icons.refresh),
                  label: Text(
                    'إعادة المحاولة',
                    style: AppFonts.cairo(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentRed,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _openSettings,
                  icon: const Icon(Icons.settings),
                  label: Text(
                    'الإعدادات',
                    style: AppFonts.cairo(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.surfaceDark,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FocusableIconButton extends StatefulWidget {
  final IconData icon;
  final bool isLoading;
  final VoidCallback? onTap;

  const _FocusableIconButton({
    required this.icon,
    this.isLoading = false,
    this.onTap,
  });

  @override
  State<_FocusableIconButton> createState() => _FocusableIconButtonState();
}

class _FocusableIconButtonState extends State<_FocusableIconButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (focused) => setState(() => _isFocused = focused),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter)) {
          widget.onTap?.call();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: _isFocused ? AppColors.accentRed : AppColors.surfaceDark,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _isFocused
                  ? AppColors.accentRedLight
                  : Colors.white.withValues(alpha: 0.06),
              width: _isFocused ? 2 : 1,
            ),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: AppColors.accentRed.withValues(alpha: 0.4),
                      blurRadius: 12,
                    ),
                  ]
                : [],
          ),
          child: widget.isLoading
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Icon(
                  widget.icon,
                  color:
                      _isFocused ? Colors.white : AppColors.textSecondary,
                  size: 24,
                ),
        ),
      ),
    );
  }
}
