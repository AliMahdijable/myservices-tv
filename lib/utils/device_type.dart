import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Whether this device is genuinely Android TV, per the OS itself --
/// PackageManager.FEATURE_LEANBACK and/or UiModeManager's current UI mode
/// (see MainActivity.kt). Screen size/density cannot answer this reliably:
/// real and emulated Android TV devices commonly report the same logical
/// shortestSide range (~540dp) as many phones and small tablets.
class DeviceType {
  static const _channel = MethodChannel('com.myservices.myservices_tv/device_type');

  static bool? _isAndroidTvCache;

  /// Resolves the platform channel once and caches the result. Call this
  /// before the first frame (e.g. in main()) so [isAndroidTvSync] -- used
  /// from synchronous build-time code -- has an answer ready.
  static Future<void> preload() async {
    if (_isAndroidTvCache != null) return;
    _isAndroidTvCache = await _queryIsAndroidTv();
  }

  /// Best-effort synchronous read of the cached value. False (i.e. "not TV")
  /// until [preload] has resolved -- callers that only use this to choose
  /// between two reasonable UI treatments can tolerate that brief window;
  /// awaiting [preload] in main() before runApp() keeps the window at
  /// effectively zero in practice.
  static bool get isAndroidTvSync => _isAndroidTvCache ?? false;

  static Future<bool> _queryIsAndroidTv() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMethod<bool>('isAndroidTv');
      return result ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
