import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';

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

  /// Poll gaps widen as attempt * this, so APNs gets roughly half a minute
  /// before the attempt is abandoned and a later one takes over.
  static const Duration _retryDelay = Duration(seconds: 1);
  static const int _apnsAttempts = 8;
  static const int _tokenAttempts = 3;

  /// Retries registration when the app comes back to the foreground.
  ///
  /// The first attempt on a cold start can legitimately come up empty — the
  /// phone may be out of signal, or Apple may simply be slow to answer. Coming
  /// back to the app is both the moment that is most likely to have changed
  /// and the moment the user is present to answer a permission dialog, so it
  /// is where a second attempt belongs. It stops asking once a token exists.
  AppLifecycleListener? _lifecycle;

  /// True only while an attempt is in flight, so two callers cannot register
  /// twice. Deliberately NOT a "we already tried" latch: the first attempt on
  /// a cold start often runs before the device has a network or before APNs
  /// has answered, and a latch would turn that ordinary delay into an app that
  /// never receives a notification until it is reinstalled.
  bool _starting = false;

  /// Set once the message handlers are attached, so a retry does not stack a
  /// second set of listeners on the same streams.
  bool _listening = false;

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
    _lifecycle ??= AppLifecycleListener(
      onResume: () {
        if (_token == null && !_starting) unawaited(start());
      },
    );
    if (_token != null) return true;
    if (_starting) return false;
    _starting = true;
    try {
      return await _register();
    } finally {
      _starting = false;
    }
  }

  Future<bool> _register() async {
    try {
      await Firebase.initializeApp();
    } catch (error) {
      // The commonest cause by far is that the platform's Firebase config file
      // is not in the bundle — on iOS that is GoogleService-Info.plist, which
      // has to be downloaded from the Firebase console for this bundle id.
      // Nothing about that improves by retrying, so this one gives up.
      debugPrint('push: Firebase could not start — $error');
      return false;
    }

    final messaging = FirebaseMessaging.instance;

    try {
      // On iOS this is the system dialog; on Android 13 and later it is the
      // POST_NOTIFICATIONS runtime permission. On older Androids it resolves
      // as granted without showing anything.
      final settings = await messaging.requestPermission();
      final granted =
          settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
      if (!granted) {
        debugPrint('push: permission ${settings.authorizationStatus.name}');
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
    } catch (error) {
      debugPrint('push: permission request failed — $error');
      return false;
    }

    // Apple issues the device's APNs token asynchronously after registration,
    // and FCM cannot mint its own token until it has one. Asking too early
    // throws `apns-token-not-set`, which on a first launch is not a failure —
    // it only means Apple has not answered yet.
    if (Platform.isIOS || Platform.isMacOS) {
      final apns = await _awaitApnsToken(messaging);
      if (apns == null) {
        debugPrint(
          'push: APNs did not issue a token in time — will try again later',
        );
        return false;
      }
      debugPrint('push: APNs token ready');
    }

    for (var attempt = 1; attempt <= _tokenAttempts; attempt++) {
      try {
        _token = await messaging.getToken();
        if (_token != null) break;
      } catch (error) {
        debugPrint('push: getToken attempt $attempt failed — $error');
      }
      if (attempt < _tokenAttempts) {
        await Future<void>.delayed(_retryDelay * attempt);
      }
    }

    if (_token == null) {
      debugPrint('push: no registration token yet — will try again later');
      return false;
    }
    // Status only, never the value: a registration token is the credential
    // that addresses this one device, so it is not something to leave lying
    // in a log that anything on the machine can read.
    debugPrint('push: registration token acquired (${_token!.length} chars)');

    if (!_listening) {
      _listening = true;
      messaging.onTokenRefresh.listen((value) => _token = value);
      FirebaseMessaging.onMessage.listen(_foreground.add);
      FirebaseMessaging.onMessageOpenedApp.listen(_opened.add);

      // A notification tapped while the app was not running is not delivered
      // to the stream — it is waiting here instead.
      final initial = await messaging.getInitialMessage();
      if (initial != null) _opened.add(initial);
    }

    return true;
  }

  /// Waits for Apple to hand over the device token, polling with a widening
  /// gap. Returns null if it never arrives, which is a reason to try the whole
  /// registration again later rather than to give up.
  Future<String?> _awaitApnsToken(FirebaseMessaging messaging) async {
    for (var attempt = 1; attempt <= _apnsAttempts; attempt++) {
      try {
        final apns = await messaging.getAPNSToken();
        if (apns != null) return apns;
      } catch (error) {
        debugPrint('push: APNs poll $attempt — $error');
      }
      await Future<void>.delayed(_retryDelay * attempt);
    }
    return null;
  }
}
