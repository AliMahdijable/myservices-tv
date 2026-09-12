import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// Push notifications, on whatever platform the app happens to be running.
///
/// Android was wired natively first: the Firebase SDK there registers the
/// device by itself, so a Console campaign already reached a backgrounded app
/// without a line of Dart. iOS grants nothing by default — until the app asks
/// the user and registers with APNs, a push is delivered to the device and
/// silently dropped. That asking has to happen in code, so both platforms are
/// driven from here rather than from two native files.
///
/// Nothing here is allowed to stop the app starting. A missing
/// `GoogleService-Info.plist`, a revoked APNs key, a device with no network on
/// first launch — each of those throws, and none of them is a reason the user
/// cannot watch television.
class PushNotifications {
  PushNotifications._();

  static final PushNotifications instance = PushNotifications._();

  bool _started = false;
  String? _token;

  /// The FCM registration token, once one has been issued. Null until the user
  /// has granted permission and APNs has answered.
  String? get token => _token;

  /// Messages that arrived while the app was in the foreground.
  final StreamController<RemoteMessage> _foreground =
      StreamController<RemoteMessage>.broadcast();
  Stream<RemoteMessage> get onMessage => _foreground.stream;

  /// Messages whose notification the user tapped to open the app.
  final StreamController<RemoteMessage> _opened =
      StreamController<RemoteMessage>.broadcast();
  Stream<RemoteMessage> get onOpened => _opened.stream;

  /// Brings up Firebase and registers for push.
  ///
  /// Returns false when push is simply unavailable — no Firebase config file
  /// bundled for this platform, or the user declined. Callers ignore the
  /// result; it exists so tests and diagnostics can tell the difference
  /// between "declined" and "never asked".
  Future<bool> start() async {
    if (_started) return _token != null;
    _started = true;

    try {
      await Firebase.initializeApp();
    } catch (error) {
      // The commonest cause by far is that the platform's Firebase config file
      // is not in the bundle — on iOS that is GoogleService-Info.plist, which
      // has to be downloaded from the Firebase console for this bundle id.
      debugPrint('push: Firebase could not start — $error');
      return false;
    }

    try {
      final messaging = FirebaseMessaging.instance;

      // On iOS this is the system dialog; on Android 13 and later it is the
      // POST_NOTIFICATIONS runtime permission. On older Androids it resolves
      // as granted without showing anything.
      final settings = await messaging.requestPermission();
      final granted =
          settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
      if (!granted) {
        debugPrint('push: permission ${settings.authorizationStatus}');
        return false;
      }

      // Without this a foreground notification on iOS is delivered to the app
      // and never drawn, which reads as "notifications do not work" while the
      // backgrounded case works fine.
      await messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );

      _token = await messaging.getToken();
      debugPrint('push: token ${_token == null ? 'unavailable' : 'acquired'}');

      messaging.onTokenRefresh.listen((value) => _token = value);
      FirebaseMessaging.onMessage.listen(_foreground.add);
      FirebaseMessaging.onMessageOpenedApp.listen(_opened.add);

      // A notification tapped while the app was not running is not delivered
      // to the stream — it is waiting here instead.
      final initial = await messaging.getInitialMessage();
      if (initial != null) _opened.add(initial);

      return _token != null;
    } catch (error) {
      debugPrint('push: registration failed — $error');
      return false;
    }
  }
}
