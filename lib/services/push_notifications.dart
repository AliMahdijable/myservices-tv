import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';

/// Push notifications, on whatever platform the app happens to be running.
///
/// Three things are kept deliberately separate, because conflating them is
/// what makes push feel hostile or broken:
///
///  * **Starting Firebase** is free and silent, and has to happen before
///    anything else can be asked or undone.
///  * **Registering** — permission, APNs, a token — is what a notification
///    needs to arrive. It may prompt, so it happens when the user asks for an
///    alert, never at launch.
///  * **Restoring** is registering without prompting, for someone who already
///    granted permission on a previous run. They should not be asked again.
///
/// Nothing here is allowed to stop the app starting, and nothing reports
/// success it did not have.
class PushNotifications {
  PushNotifications._();

  static final PushNotifications instance = PushNotifications._();

  static const Duration _retryDelay = Duration(seconds: 1);
  static const int _apnsAttempts = 8;
  static const int _tokenAttempts = 3;

  /// Debug builds join this so a test send can be aimed at a development
  /// device without a registration token having to leave the phone.
  static const String debugTestTopic = 'debug-test-device';

  bool _firebaseUp = false;
  bool _starting = false;
  bool _listening = false;
  String? _token;

  /// True once a registration token exists — the only state in which a
  /// subscription can be made or removed.
  bool get isRegistered => _token != null;

  final StreamController<RemoteMessage> _foreground =
      StreamController<RemoteMessage>.broadcast();
  Stream<RemoteMessage> get onMessage => _foreground.stream;

  final StreamController<RemoteMessage> _opened =
      StreamController<RemoteMessage>.broadcast();
  Stream<RemoteMessage> get onOpened => _opened.stream;

  /// Fires when FCM issues a new token. Subscriptions are tied to the token,
  /// so everything the device wanted has to be asserted again.
  final StreamController<void> _tokenChanged =
      StreamController<void>.broadcast();
  Stream<void> get onTokenChanged => _tokenChanged.stream;

  AppLifecycleListener? _lifecycle;

  // ── Firebase, on its own ───────────────────────────────────────────────

  /// Brings Firebase up. Silent, and safe to call as often as you like.
  Future<bool> ensureFirebase() async {
    if (_firebaseUp) return true;
    try {
      await Firebase.initializeApp();
      _firebaseUp = true;
      return true;
    } catch (error) {
      // Almost always a missing platform config file — on iOS that is
      // GoogleService-Info.plist. Retrying will not conjure one.
      debugPrint('push: Firebase could not start — $error');
      return false;
    }
  }

  // ── Registration ───────────────────────────────────────────────────────

  /// Registers for push. [mayPrompt] false means: only proceed if the user has
  /// already granted permission, and never show the system dialog.
  ///
  /// Returns whether a registration token exists afterwards.
  Future<bool> ensureRegistered({required bool mayPrompt}) async {
    if (_token != null) return true;
    if (_starting) return false;
    _starting = true;
    try {
      return await _register(mayPrompt: mayPrompt);
    } finally {
      _starting = false;
    }
  }

  /// Registration for a returning user: no dialog, no interruption.
  ///
  /// Called at launch so someone who followed a club last week has their
  /// subscriptions re-asserted against a possibly new token without being
  /// asked for anything.
  Future<bool> restoreSilently() => ensureRegistered(mayPrompt: false);

  Future<bool> _register({required bool mayPrompt}) async {
    if (!await ensureFirebase()) return false;

    _lifecycle ??= AppLifecycleListener(
      onResume: () {
        // Permission can be revoked in system settings while the app is away,
        // and a token can be reissued. Both are only observable on return.
        if (!_starting) unawaited(ensureRegistered(mayPrompt: false));
      },
    );

    final messaging = FirebaseMessaging.instance;

    try {
      var settings = await messaging.getNotificationSettings();
      var granted = _isGranted(settings.authorizationStatus);

      if (!granted) {
        if (!mayPrompt) {
          // Not an error: nobody has asked for an alert yet, or permission was
          // taken away. Either way the app says nothing.
          return false;
        }
        settings = await messaging.requestPermission();
        granted = _isGranted(settings.authorizationStatus);
      }

      if (!granted) {
        debugPrint('push: permission ${settings.authorizationStatus.name}');
        return false;
      }

      // Without this an iOS notification that arrives while the app is open is
      // delivered and never drawn, which reads as "notifications are broken"
      // even though the backgrounded case works.
      await messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
    } catch (error) {
      debugPrint('push: permission step failed — $error');
      return false;
    }

    // Apple issues the device token asynchronously, and FCM cannot mint its
    // own until it has one. Asking too early throws `apns-token-not-set`,
    // which on a first launch is not a failure — only an answer not yet given.
    if (Platform.isIOS || Platform.isMacOS) {
      final apns = await _awaitApnsToken(messaging);
      if (apns == null) {
        debugPrint('push: APNs has not issued a token yet — will retry later');
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
      debugPrint('push: no registration token yet — will retry later');
      return false;
    }
    // Status only, never the value: a registration token is the credential
    // that addresses this one device.
    debugPrint('push: registration token acquired (${_token!.length} chars)');

    if (kDebugMode) {
      try {
        await messaging.subscribeToTopic(debugTestTopic);
        debugPrint('push: subscribed to "$debugTestTopic" — test sends only');
      } catch (error) {
        debugPrint('push: could not join the test topic — $error');
      }
    }

    if (!_listening) {
      _listening = true;

      messaging.onTokenRefresh.listen((value) {
        // Subscriptions live against a token. A reissued one has none of them,
        // so whoever owns the wishes has to assert them again.
        _token = value;
        debugPrint('push: registration token was reissued');
        _tokenChanged.add(null);
      });

      // Status only, no content: enough to prove a message arrived without
      // putting what it said — or who it addressed — into a log.
      FirebaseMessaging.onMessage.listen((message) {
        debugPrint(
          'push: message received in foreground '
          '(notification: ${message.notification != null}, '
          'data keys: ${message.data.keys.length})',
        );
        _foreground.add(message);
      });
      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        debugPrint('push: app opened from a notification');
        _opened.add(message);
      });

      // A notification tapped while the app was not running is not delivered
      // to the stream — it is waiting here instead.
      final initial = await messaging.getInitialMessage();
      if (initial != null) {
        debugPrint('push: launched by a notification tap');
        _opened.add(initial);
      }
    }

    return true;
  }

  static bool _isGranted(AuthorizationStatus status) =>
      status == AuthorizationStatus.authorized ||
      status == AuthorizationStatus.provisional;

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

  // ── Topics ─────────────────────────────────────────────────────────────

  /// Joins [topic]. False means it did not happen.
  ///
  /// A switch in the interface that flips on while the subscription behind it
  /// failed tells the user they will be warned about a match they will then
  /// miss, so this reports rather than throws — and the caller keeps the
  /// switch off.
  Future<bool> subscribe(String topic) async {
    if (!await ensureRegistered(mayPrompt: true)) return false;
    try {
      await FirebaseMessaging.instance.subscribeToTopic(topic);
      return true;
    } catch (error) {
      debugPrint('push: subscribe failed — $error');
      return false;
    }
  }

  /// Leaves [topic]. False means the device may still be subscribed.
  ///
  /// Never claims success from the absence of a local token. A subscription
  /// lives on Firebase's side and survives the app being restarted, so "we
  /// have not registered in this process yet" says nothing about whether this
  /// device is still going to be sent the message. Reporting success there
  /// would turn every "switch my alerts off" into a lie that only surfaces
  /// when the next notification arrives.
  Future<bool> unsubscribe(String topic) async {
    if (!await ensureFirebase()) return false;
    // Silent: turning something off must never raise a permission dialog.
    if (!await ensureRegistered(mayPrompt: false)) return false;
    try {
      await FirebaseMessaging.instance.unsubscribeFromTopic(topic);
      return true;
    } catch (error) {
      debugPrint('push: unsubscribe failed — $error');
      return false;
    }
  }
}
