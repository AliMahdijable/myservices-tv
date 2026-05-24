import 'package:flutter/material.dart';
import '../config/app_config.dart';
import '../models/channel.dart';
import '../services/channel_service.dart';
import '../theme/app_theme.dart';
import 'home_screen.dart';
import 'setup_screen.dart';

class SplashScreen extends StatefulWidget {
  /// Set true after the user completes setup manually — skips auto-detect.
  final bool skipSetupCheck;

  const SplashScreen({super.key, this.skipSetupCheck = false});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;
  late Animation<double> _textFadeAnimation;

  List<ChannelCategory>? _preloadedCategories;
  bool _animationDone = false;
  bool _dataReady    = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.5, curve: Curves.easeIn),
      ),
    );

    _scaleAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.6, curve: Curves.elasticOut),
      ),
    );

    _textFadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.5, 0.8, curve: Curves.easeIn),
      ),
    );

    _controller.forward();
    _initialize();

    Future.delayed(const Duration(milliseconds: 1500), () {
      _animationDone = true;
      _navigateIfReady();
    });
  }

  Future<void> _initialize() async {
    await AppConfig.load();

    if (!widget.skipSetupCheck) {
      // Always check if the private server is reachable first.
      // This ensures returning to the home network auto-restores default config.
      final onPrivateNetwork = await AppConfig.isDefaultServerReachable();

      if (onPrivateNetwork) {
        // On private network → always use default credentials.
        await AppConfig.save(
          serverUrl: AppConfig.defaultBaseUrl,
          username:  AppConfig.defaultUsername,
          password:  AppConfig.defaultPassword,
        );
        // Fall through to load channels below.
      } else {
        // Not on private network.
        if (!AppConfig.isConfigured ||
            AppConfig.baseUrl == AppConfig.defaultBaseUrl) {
          // No manual config (or still pointing at unreachable private server)
          // → ask user to enter server details.
          await AppConfig.clear();
          _dataReady = true;
          _navigateIfReady();
          return;
        }
        // Has manual (external) config → use it as-is, fall through.
      }
    }

    // Load channels (cache or network) using whatever config is active.
    try {
      _preloadedCategories = await ChannelService.fetchCategories();
    } catch (e) {
      _loadError = e.toString();
    }
    _dataReady = true;
    _navigateIfReady();
  }

  void _navigateIfReady() {
    if (!_animationDone || !_dataReady || !mounted) return;

    // Still no config (not on private network, no manual config) → setup
    if (!AppConfig.isConfigured && !widget.skipSetupCheck) {
      _goToSetup();
      return;
    }

    // Config exists but all load attempts failed and no cache → setup
    if (_loadError != null &&
        (_preloadedCategories == null || _preloadedCategories!.isEmpty)) {
      _goToSetup(
        error: 'تعذّر الاتصال بالسيرفر.\n'
            'تحقق من اتصالك بالشبكة أو عدّل بيانات الاتصال.',
      );
      return;
    }

    // All good → home
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) =>
            HomeScreen(preloadedCategories: _preloadedCategories),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  void _goToSetup({String? error}) {
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => SetupScreen(initialError: error),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppColors.primaryDark,
              Color(0xFF0B1929),
              AppColors.secondaryDark,
            ],
          ),
        ),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Spacer(flex: 3),
                FadeTransition(
                  opacity: _fadeAnimation,
                  child: ScaleTransition(
                    scale: _scaleAnimation,
                    child: Container(
                      width: 160,
                      height: 160,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(30),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.accentRed.withValues(alpha: 0.3),
                            blurRadius: 40,
                            spreadRadius: 5,
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(30),
                        child: Image.asset(
                          'assets/images/logo.png',
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 30),
                FadeTransition(
                  opacity: _fadeAnimation,
                  child: Text(
                    'MyServices TV',
                    style: AppFonts.cairo(
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                      letterSpacing: 2,
                    ),
                  ),
                ),
                const Spacer(flex: 3),
                FadeTransition(
                  opacity: _textFadeAnimation,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 60),
                    child: Text(
                      'شاشتك لمشاهدة المباريات',
                      style: AppFonts.cairo(
                        fontSize: 20,
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
