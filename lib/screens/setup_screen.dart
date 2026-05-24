import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config/app_config.dart';
import '../services/xtream_service.dart';
import '../theme/app_theme.dart';
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

  bool _isConnecting = false;
  String? _errorMessage;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    // Pre-fill if already configured (editing mode)
    if (AppConfig.isConfigured) {
      _serverController.text = AppConfig.baseUrl;
      _usernameController.text = AppConfig.username;
      _passwordController.text = AppConfig.password;
    }
    // Show error passed from splash (e.g. outside network)
    if (widget.initialError != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _errorMessage = widget.initialError);
      });
    }
  }

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
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

    final ok = await XtreamService.testConnection(serverUrl, username, password);

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
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('إلغاء',
                style: AppFonts.cairo(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('متابعة',
                style: AppFonts.cairo(color: AppColors.accentRedLight)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _navigateToHome() async {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const SplashScreen(skipSetupCheck: true),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.backgroundGradient),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildLogo(),
                    const SizedBox(height: 32),
                    _buildForm(),
                    const SizedBox(height: 24),
                    _buildConnectButton(),
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 16),
                      _buildErrorBanner(),
                    ],
                    const SizedBox(height: 40),
                    _buildFooterNote(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
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
          style: AppFonts.cairo(
            color: AppColors.textMuted,
            fontSize: 14,
          ),
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
            label: 'عنوان السيرفر',
            hint: 'http://server.example.com:8080',
            icon: Icons.dns_rounded,
            keyboardType: TextInputType.url,
            inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'مطلوب';
              if (!v.trim().startsWith('http')) return 'يجب أن يبدأ بـ http';
              return null;
            },
          ),
          const SizedBox(height: 14),
          _buildField(
            controller: _usernameController,
            label: 'اسم المستخدم',
            hint: 'username',
            icon: Icons.person_rounded,
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'مطلوب' : null,
          ),
          const SizedBox(height: 14),
          _buildField(
            controller: _passwordController,
            label: 'كلمة المرور',
            hint: '••••••••',
            icon: Icons.lock_rounded,
            obscureText: _obscurePassword,
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword ? Icons.visibility : Icons.visibility_off,
                color: Colors.white38,
                size: 20,
              ),
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'مطلوب' : null,
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
    TextInputType keyboardType = TextInputType.text,
    List<TextInputFormatter>? inputFormatters,
    bool obscureText = false,
    Widget? suffixIcon,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      obscureText: obscureText,
      style: AppFonts.cairo(color: Colors.white, fontSize: 15),
      textDirection: TextDirection.ltr,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: AppFonts.cairo(color: Colors.white24, fontSize: 13),
        labelStyle: AppFonts.cairo(color: Colors.white54, fontSize: 13),
        prefixIcon: Icon(icon, color: AppColors.accentRedLight, size: 20),
        suffixIcon: suffixIcon,
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
          borderSide:
              const BorderSide(color: AppColors.accentRedLight, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:
              const BorderSide(color: AppColors.accentRed, width: 1.5),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:
              const BorderSide(color: AppColors.accentRed, width: 1.5),
        ),
        errorStyle: AppFonts.cairo(color: AppColors.accentRed, fontSize: 11),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    );
  }

  Widget _buildConnectButton() {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: _isConnecting ? null : _connect,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accentRed,
          disabledBackgroundColor: AppColors.accentRed.withValues(alpha: 0.4),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 4,
          shadowColor: AppColors.accentRed.withValues(alpha: 0.4),
        ),
        child: _isConnecting
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2.5,
                ),
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
    );
  }

  Widget _buildErrorBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.accentRed.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border:
            Border.all(color: AppColors.accentRed.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline,
              color: AppColors.accentRed, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _errorMessage!,
              style: AppFonts.cairo(
                  color: AppColors.accentRedLight, fontSize: 13),
              textDirection: TextDirection.rtl,
            ),
          ),
        ],
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
