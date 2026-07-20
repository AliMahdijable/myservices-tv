import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config/app_config.dart';
import '../services/xtream_service.dart';
import '../theme/app_theme.dart';
import '../widgets/tv_keyboard.dart';
import 'splash_screen.dart';

class SetupScreen extends StatefulWidget {
  final String? initialError;

  const SetupScreen({super.key, this.initialError});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _serverController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  final _serverFocus = FocusNode();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _connectFocus = FocusNode();

  bool _isConnecting = false;
  String? _errorMessage;

  /// على iOS/iPad نستعمل system keyboard الطبيعي (touch UX).
  /// TvKeyboard المخصّص يبقى لـAndroid TV + Desktop (D-pad UX).
  bool get _useSystemKeyboard => !kIsWeb && Platform.isIOS;

  @override
  void initState() {
    super.initState();
    if (AppConfig.isConfigured) {
      _serverController.text = AppConfig.baseUrl;
      _usernameController.text = AppConfig.username;
      _passwordController.text = AppConfig.password;
    }
    if (widget.initialError != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _errorMessage = widget.initialError);
      });
    }
    // Rebuild when connect-button focus changes so the glow ring is visible.
    _connectFocus.addListener(() {
      if (mounted) setState(() {});
    });

    // D-pad center / Enter on each field opens the TV keyboard dialog.
    // على iOS/iPad نتخطى هذا كلياً — system keyboard الطبيعي يظهر
    // مباشرة لما يضغط المستخدم على الحقل.
    if (!_useSystemKeyboard) {
      _bindTvKeyboard(
        _serverFocus,
        _serverController,
        'عنوان السيرفر',
        next: _usernameFocus,
      );
      _bindTvKeyboard(
        _usernameFocus,
        _usernameController,
        'اسم المستخدم',
        next: _passwordFocus,
      );
      _bindTvKeyboard(
        _passwordFocus,
        _passwordController,
        'كلمة المرور',
        next: _connectFocus,
        obscure: true,
      );
    }
  }

  void _bindTvKeyboard(
    FocusNode node,
    TextEditingController ctrl,
    String label, {
    FocusNode? next,
    bool obscure = false,
  }) {
    node.onKeyEvent = (_, event) {
      if (event is KeyDownEvent &&
          (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter ||
              event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
        _openTvKeyboard(ctrl, label, obscure: obscure, next: next);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
  }

  Future<void> _openTvKeyboard(
    TextEditingController ctrl,
    String label, {
    bool obscure = false,
    FocusNode? next,
  }) async {
    final result = await TvKeyboard.show(
      context,
      fieldLabel: label,
      initialText: ctrl.text,
      obscureText: obscure,
    );
    if (!mounted) return;
    if (result != null) {
      setState(() => ctrl.text = result);
      if (next != null) FocusScope.of(context).requestFocus(next);
    }
  }

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _serverFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _connectFocus.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    final serverUrl = _serverController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    final ok = await XtreamService.testConnection(
      serverUrl,
      username,
      password,
    );

    if (!mounted) return;

    if (ok) {
      await AppConfig.save(
        serverUrl: serverUrl,
        username: username,
        password: password,
      );
      await _navigateToHome();
    } else {
      // Xtream check failed — still save and let the app try M3U fallback
      final shouldContinue = await _showFallbackDialog();
      if (shouldContinue && mounted) {
        await AppConfig.save(
          serverUrl: serverUrl,
          username: username,
          password: password,
        );
        await _navigateToHome();
      } else {
        setState(() {
          _isConnecting = false;
          _errorMessage =
              'تعذّر الاتصال. تحقق من عنوان السيرفر وبيانات الدخول.';
        });
      }
    }
  }

  String? _validateServerUrl(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) return 'مطلوب';
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return 'أدخل رابطاً صحيحاً يبدأ بـ http أو https';
    }
    return null;
  }

  Future<bool> _showFallbackDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.secondaryDark,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'تنبيه',
          style: AppFonts.cairo(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
          textDirection: TextDirection.rtl,
        ),
        content: Text(
          'لم يتمكن التطبيق من التحقق من بيانات Xtream.\nهل تريد المتابعة باستخدام قائمة M3U؟',
          style: AppFonts.cairo(color: Colors.white70, fontSize: 14),
          textDirection: TextDirection.rtl,
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('إلغاء', style: AppFonts.cairo(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'متابعة',
              style: AppFonts.cairo(color: AppColors.accentRedLight),
            ),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _navigateToHome() async {
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const SplashScreen(skipSetupCheck: true),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 300),
      ),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.backgroundGradient),
        child: SafeArea(
          child: FocusTraversalGroup(
            policy: WidgetOrderTraversalPolicy(),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 850;
                final minimumHeight = max(0.0, constraints.maxHeight - 48);
                return SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 24,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: minimumHeight),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1080),
                        child: wide
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(child: _buildLogo()),
                                  const SizedBox(width: 56),
                                  SizedBox(
                                    width: 480,
                                    child: _buildFormPanel(),
                                  ),
                                ],
                              )
                            : ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 480,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _buildLogo(),
                                    const SizedBox(height: 32),
                                    _buildFormPanel(),
                                  ],
                                ),
                              ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFormPanel() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildForm(),
        const SizedBox(height: 24),
        _buildConnectButton(),
        if (_errorMessage != null) ...[
          const SizedBox(height: 16),
          _buildErrorBanner(),
        ],
        const SizedBox(height: 28),
        _buildFooterNote(),
      ],
    );
  }

  Widget _buildLogo() {
    return Column(
      children: [
        Container(
          width: 90,
          height: 90,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: AppColors.accentRed.withValues(alpha: 0.35),
                blurRadius: 30,
                spreadRadius: 4,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Image.asset('assets/images/logo.png', fit: BoxFit.contain),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'MyServices TV',
          style: AppFonts.cairo(
            color: AppColors.textPrimary,
            fontSize: 26,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'أدخل بيانات سيرفر IPTV الخاص بك',
          style: AppFonts.cairo(color: AppColors.textMuted, fontSize: 14),
          textDirection: TextDirection.rtl,
        ),
      ],
    );
  }

  Widget _buildForm() {
    return Form(
      key: _formKey,
      child: Column(
        children: [
          _buildField(
            controller: _serverController,
            focusNode: _serverFocus,
            autofocus: true,
            label: 'عنوان السيرفر',
            hint: 'http://server.example.com:8080',
            icon: Icons.dns_rounded,
            onTap: () => _openTvKeyboard(
              _serverController,
              'عنوان السيرفر',
              next: _usernameFocus,
            ),
            validator: _validateServerUrl,
          ),
          const SizedBox(height: 14),
          _buildField(
            controller: _usernameController,
            focusNode: _usernameFocus,
            label: 'اسم المستخدم',
            hint: 'username',
            icon: Icons.person_rounded,
            onTap: () => _openTvKeyboard(
              _usernameController,
              'اسم المستخدم',
              next: _passwordFocus,
            ),
            validator: (v) => (v == null || v.trim().isEmpty) ? 'مطلوب' : null,
          ),
          const SizedBox(height: 14),
          _buildField(
            controller: _passwordController,
            focusNode: _passwordFocus,
            label: 'كلمة المرور',
            hint: '••••••••',
            icon: Icons.lock_rounded,
            obscureText: true,
            onTap: () => _openTvKeyboard(
              _passwordController,
              'كلمة المرور',
              obscure: true,
              next: _connectFocus,
            ),
            validator: (v) => (v == null || v.trim().isEmpty) ? 'مطلوب' : null,
          ),
        ],
      ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    FocusNode? focusNode,
    bool obscureText = false,
    bool autofocus = false,
    VoidCallback? onTap,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      // iOS/iPad → system keyboard مباشر (readOnly=false).
      // Android TV/Desktop → readOnly + onTap يفتح TvKeyboard المخصّص.
      readOnly: !_useSystemKeyboard,
      showCursor: _useSystemKeyboard,
      enableInteractiveSelection: _useSystemKeyboard,
      obscureText: obscureText,
      autofocus: autofocus,
      onTap: _useSystemKeyboard ? null : onTap,
      keyboardType: _useSystemKeyboard
          ? (obscureText ? TextInputType.visiblePassword : TextInputType.url)
          : null,
      textInputAction: _useSystemKeyboard ? TextInputAction.next : null,
      style: AppFonts.cairo(color: Colors.white, fontSize: 15),
      textDirection: TextDirection.ltr,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: AppFonts.cairo(color: Colors.white24, fontSize: 13),
        labelStyle: AppFonts.cairo(color: Colors.white54, fontSize: 13),
        prefixIcon: Icon(icon, color: AppColors.accentRedLight, size: 20),
        filled: true,
        fillColor: AppColors.surfaceDark.withValues(alpha: 0.7),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(
            color: AppColors.accentRedLight,
            width: 1.5,
          ),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.accentRed, width: 1.5),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.accentRed, width: 1.5),
        ),
        errorStyle: AppFonts.cairo(color: AppColors.accentRed, fontSize: 11),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
    );
  }

  Widget _buildConnectButton() {
    final focused = _connectFocus.hasFocus;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: focused
            ? Border.all(color: AppColors.accentRedLight, width: 3)
            : null,
        boxShadow: focused
            ? [
                BoxShadow(
                  color: AppColors.accentRed.withValues(alpha: 0.65),
                  blurRadius: 22,
                  spreadRadius: 3,
                ),
              ]
            : null,
      ),
      child: SizedBox(
        width: double.infinity,
        height: 52,
        child: ElevatedButton(
          focusNode: _connectFocus,
          onPressed: _isConnecting ? null : _connect,
          style: ElevatedButton.styleFrom(
            backgroundColor: focused
                ? AppColors.accentRedLight
                : AppColors.accentRed,
            disabledBackgroundColor: AppColors.accentRed.withValues(alpha: 0.4),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            elevation: focused ? 8 : 4,
            shadowColor: AppColors.accentRed.withValues(alpha: 0.4),
          ),
          child: _isConnecting
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'جاري الاتصال…',
                      style: AppFonts.cairo(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                )
              : Text(
                  'اتصال',
                  style: AppFonts.cairo(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildErrorBanner() {
    return Semantics(
      liveRegion: true,
      label: _errorMessage,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.accentRed.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.accentRed.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.error_outline,
              color: AppColors.accentRed,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _errorMessage!,
                style: AppFonts.cairo(
                  color: AppColors.accentRedLight,
                  fontSize: 13,
                ),
                textDirection: TextDirection.rtl,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFooterNote() {
    return Text(
      'يدعم بروتوكول Xtream Codes و قوائم M3U',
      style: AppFonts.cairo(color: Colors.white24, fontSize: 12),
      textAlign: TextAlign.center,
    );
  }
}
