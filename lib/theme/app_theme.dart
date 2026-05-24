import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  // Dark navy gradient colors from the design
  static const Color primaryDark = Color(0xFF0A1628);
  static const Color secondaryDark = Color(0xFF0F1F35);
  static const Color surfaceDark = Color(0xFF152A45);
  static const Color cardDark = Color(0xFF1A3252);
  static const Color cardHover = Color(0xFF1E3A5F);

  // Accent colors
  static const Color accentRed = Color(0xFFC62828);
  static const Color accentRedLight = Color(0xFFE53935);

  // Text colors
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFB0BEC5);
  static const Color textMuted = Color(0xFF607D8B);

  // Gradient
  static const LinearGradient backgroundGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [primaryDark, secondaryDark],
  );

  static const LinearGradient cardGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [surfaceDark, cardDark],
  );

  static const LinearGradient redGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [accentRed, accentRedLight],
  );
}

class AppFonts {
  /// Get Cairo text theme for beautiful Arabic text
  static TextTheme get cairoTextTheme => GoogleFonts.cairoTextTheme();

  /// Cairo text style helper
  static TextStyle cairo({
    double fontSize = 14,
    FontWeight fontWeight = FontWeight.normal,
    Color color = AppColors.textPrimary,
    double? height,
    double? letterSpacing,
  }) {
    return GoogleFonts.cairo(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
    );
  }
}

class AppTheme {
  static ThemeData get darkTheme {
    final cairoTheme = GoogleFonts.cairoTextTheme(
      ThemeData.dark().textTheme,
    );

    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.primaryDark,
      primaryColor: AppColors.accentRed,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.accentRed,
        secondary: AppColors.accentRedLight,
        surface: AppColors.surfaceDark,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      textTheme: cairoTheme.copyWith(
        headlineLarge: cairoTheme.headlineLarge?.copyWith(color: AppColors.textPrimary),
        headlineMedium: cairoTheme.headlineMedium?.copyWith(color: AppColors.textPrimary),
        headlineSmall: cairoTheme.headlineSmall?.copyWith(color: AppColors.textPrimary),
        titleLarge: cairoTheme.titleLarge?.copyWith(color: AppColors.textPrimary),
        titleMedium: cairoTheme.titleMedium?.copyWith(color: AppColors.textPrimary),
        bodyLarge: cairoTheme.bodyLarge?.copyWith(color: AppColors.textPrimary),
        bodyMedium: cairoTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
        bodySmall: cairoTheme.bodySmall?.copyWith(color: AppColors.textMuted),
      ),
    );
  }
}
