import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'player/playback_preferences.dart';
import 'screens/splash_screen.dart';
import 'theme/app_theme.dart';
import 'utils/device_type.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // Decoder and buffer settings shape how the very first channel opens, so
  // they must be in memory before any player is constructed.
  await PlaybackPreferences.load();

  // Screens that choose between the native keyboard and the D-pad-navigable
  // TvKeyboard read this synchronously at build time, so it must resolve
  // before the first frame.
  await DeviceType.preload();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.primaryDark,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(const MyServicesTV());
}

class MyServicesTV extends StatelessWidget {
  const MyServicesTV({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IPTV Player',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const SplashScreen(),
    );
  }
}
