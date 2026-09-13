import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/fixture.dart';
import '../models/match_alert.dart';
import 'push_notifications.dart';

/// The three things the alert preferences need from the push layer.
///
/// Behind an interface so the preference logic can be exercised without a
/// Firebase channel — and, more usefully, so the failure paths can be: a
/// refused permission, a subscribe that does not take, an unsubscribe that
/// fails while the user believes their alerts are off.
abstract class AlertsGateway {
  /// Asks for notification permission if it has not been granted. May prompt.
  Future<bool> ensurePermission();

  /// True only if the device really joined the topic.
  Future<bool> subscribe(String topic);

  /// True only if the device really left it. Never inferred from local state.
  Future<bool> unsubscribe(String topic);

  /// Fires when subscriptions have to be asserted again from scratch.
  Stream<void> get onTokenChanged;
}

class _PushGateway implements AlertsGateway {
  const _PushGateway();

  @override
  Future<bool> ensurePermission() =>
      PushNotifications.instance.ensureRegistered(mayPrompt: true);

  @override
  Future<bool> subscribe(String topic) =>
      PushNotifications.instance.subscribe(topic);

  @override
  Future<bool> unsubscribe(String topic) =>
      PushNotifications.instance.unsubscribe(topic);

  @override
  Stream<void> get onTokenChanged => PushNotifications.instance.onTokenChanged;
}

/// Whether the device is actually signed up to receive what the user asked
/// for, or only appears to be.
///
/// A switch that flips on and stays on while the subscription behind it
/// failed is worse than one that refuses: the user believes they will be told
/// about the match, and finds out they were not by missing it.
enum AlertSyncState { idle, pending, ok, permissionDenied, failed }

/// Which matches this device wants to be told about, and the topic
/// subscriptions that make that true.
///
/// Nothing here talks to a server or stores a token anywhere. A device
/// subscribes itself to a topic per (fixture, alert type); the sender only
/// ever addresses that topic and never learns who is listening.
class MatchAlertsService extends ChangeNotifier {
  MatchAlertsService._();

  static final MatchAlertsService instance = MatchAlertsService._();

  /// Swapped out in tests. Production talks to Firebase through [_PushGateway].
  @visibleForTesting
  AlertsGateway gateway = const _PushGateway();

  static const _kEnabled = 'alerts_enabled_v1';
  static const _kTypes = 'alerts_types_v1';
  static const _kBells = 'alerts_bells_v1';
  static const _kClubs = 'alerts_clubs_v1';
  static const _kMuted = 'alerts_muted_v1';
  static const _kSubscribed = 'alerts_subscribed_topics_v1';

  bool _loaded = false;

  /// The master switch. Off means nothing is subscribed, whatever else is set.
  bool _enabled = true;
  bool get enabled => _enabled;

  Set<MatchAlertType> _types = {...MatchAlertType.quietDefault};
  Set<MatchAlertType> get types => UnmodifiableSetView(_types);

  /// Fixtures with a bell the user set by hand, each with its kickoff.
  ///
  /// The time is stored with the bell so that expiry does not depend on which
  /// day the screen happens to be showing. An earlier version kept a plain set
  /// and dropped anything missing from the currently loaded fixtures, so
  /// flicking to tomorrow silently unsubscribed today's matches.
  final Map<int, DateTime> _bells = {};
  Set<int> get bells => UnmodifiableSetView(_bells.keys.toSet());

  /// Clubs whose matches are covered without a bell on each one.
  final Set<int> _clubs = {};
  Set<int> get followedClubs => UnmodifiableSetView(_clubs);

  /// Fixtures the user silenced individually.
  ///
  /// Only meaningful for a match reached through a followed club: a match with
  /// its own bell is silenced by turning the bell off. Muting is remembered
  /// separately so that following the club again does not resurrect a match
  /// the user has already said no to.
  final Set<int> _muted = {};
  Set<int> get mutedFixtures => UnmodifiableSetView(_muted);

  /// Topics this device believes it is subscribed to.
  ///
  /// Kept on disk because FCM has no way to ask. Without it, a reinstall or a
  /// changed set of preferences would leave subscriptions behind that nothing
  /// would ever unsubscribe, and the user would keep getting alerts they had
  /// switched off.
  final Set<String> _subscribed = {};
  Set<String> get subscribedTopics => UnmodifiableSetView(_subscribed);

  /// Serialises reconciles. Flicking three bells in a second would otherwise
  /// run three overlapping diffs against the same on-disk record and leave it
  /// describing subscriptions the device does not have.
  Future<void> _queue = Future<void>.value();

  /// Re-asserts everything when FCM reissues the token. Subscriptions live
  /// against a token, so a new one arrives with none of them.
  StreamSubscription<void>? _tokenWatch;

  AlertSyncState _syncState = AlertSyncState.idle;
  AlertSyncState get syncState => _syncState;

  /// Set when [syncState] is [AlertSyncState.failed], for the UI to show.
  String? _lastError;
  String? get lastError => _lastError;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_kEnabled) ?? true;

    final codes = prefs.getStringList(_kTypes);
    if (codes != null) {
      _types = codes
          .map(MatchAlertType.fromCode)
          .whereType<MatchAlertType>()
          .toSet();
    }

    _bells
      ..clear()
      ..addAll(_readBells(prefs));
    _clubs
      ..clear()
      ..addAll(_readInts(prefs, _kClubs));
    _muted
      ..clear()
      ..addAll(_readInts(prefs, _kMuted));
    _subscribed
      ..clear()
      ..addAll(prefs.getStringList(_kSubscribed) ?? const []);

    _loaded = true;
    _tokenWatch ??= gateway.onTokenChanged.listen((_) {
      // Forget what we believed we were subscribed to: none of it survived
      // the token change, so every desired topic has to be joined again.
      _subscribed.clear();
      unawaited(_reconcile());
    });
    notifyListeners();
  }

  /// Brings a returning user back without asking them anything.
  ///
  /// Someone who followed a club last week has already granted permission;
  /// showing them the dialog again at launch would be both pointless and the
  /// most common reason people turn notifications off. If nothing was ever
  /// subscribed, this does nothing at all — a new user is asked only when they
  /// first tap a bell.
  Future<void> restoreOnLaunch() async {
    await load();
    if (_subscribed.isEmpty && _clubs.isEmpty && _bells.isEmpty) return;
    await PushNotifications.instance.restoreSilently();
    await pruneAndSync();
  }

  static Iterable<int> _readInts(SharedPreferences prefs, String key) =>
      (prefs.getStringList(key) ?? const []).map(int.tryParse).whereType<int>();

  /// Stored as "fixtureId:millisSinceEpoch" pairs, so a bell carries its own
  /// expiry and never depends on which day the screen happens to be showing.
  static Map<int, DateTime> _readBells(SharedPreferences prefs) {
    final out = <int, DateTime>{};
    for (final entry in prefs.getStringList(_kBells) ?? const <String>[]) {
      final parts = entry.split(':');
      if (parts.length != 2) continue;
      final id = int.tryParse(parts[0]);
      final millis = int.tryParse(parts[1]);
      if (id == null || millis == null) continue;
      out[id] = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
    }
    return out;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, _enabled);
    await prefs.setStringList(
      _kTypes,
      _types.map((t) => t.code).toList()..sort(),
    );
    await prefs.setStringList(_kBells, [
      for (final e in _bells.entries)
        '${e.key}:${e.value.toUtc().millisecondsSinceEpoch}',
    ]);
    await prefs.setStringList(_kClubs, _clubs.map((i) => '$i').toList());
    await prefs.setStringList(_kMuted, _muted.map((i) => '$i').toList());
    await prefs.setStringList(_kSubscribed, _subscribed.toList()..sort());
  }

  // ── Queries the UI asks ────────────────────────────────────────────────

  bool hasBell(int fixtureId) => _bells.containsKey(fixtureId);

  bool followsClub(int teamId) => _clubs.contains(teamId);

  bool isMuted(int fixtureId) => _muted.contains(fixtureId);

  /// Whether [fixture] will produce any alert at all as things stand.
  bool isCovered(Fixture fixture) {
    if (!_enabled || _types.isEmpty) return false;
    if (_muted.contains(fixture.id)) return false;
    if (_bells.containsKey(fixture.id)) return true;
    return _clubs.contains(fixture.home.id) || _clubs.contains(fixture.away.id);
  }

  // ── Changes the user makes ─────────────────────────────────────────────

  /// Turning a bell on is the moment to ask for permission — not app launch,
  /// where the request arrives before the user has any idea what it is for.
  Future<void> setBell(Fixture fixture, bool on) async {
    await load();
    final fixtureId = fixture.id;
    if (on) {
      if (!await _ensurePermission()) return;
      _bells[fixtureId] = fixture.kickoff;
      // Asking for a match explicitly overrules having silenced it before.
      _muted.remove(fixtureId);
    } else {
      _bells.remove(fixtureId);
      // A bell switched off on a match a followed club would otherwise cover
      // means this match, specifically, and not the club.
      if (_clubs.contains(fixture.home.id) ||
          _clubs.contains(fixture.away.id)) {
        _muted.add(fixtureId);
      }
    }
    await _persist();
    notifyListeners();
    await _reconcile();
  }

  Future<void> setFollowClub(int teamId, bool on) async {
    await load();
    if (on) {
      if (!await _ensurePermission()) return;
      _clubs.add(teamId);
    } else {
      _clubs.remove(teamId);
    }
    await _persist();
    notifyListeners();
    await _reconcile();
  }

  Future<void> setType(MatchAlertType type, bool on) async {
    await load();
    if (on) {
      _types.add(type);
    } else {
      _types.remove(type);
    }
    await _persist();
    notifyListeners();
    await _reconcile();
  }

  Future<void> setEnabled(bool value) async {
    await load();
    _enabled = value;
    await _persist();
    notifyListeners();
    await _reconcile();
  }

  /// Forgets every bell, club and mute, and unsubscribes from everything.
  Future<void> clearAll() async {
    await load();
    _bells.clear();
    _clubs.clear();
    _muted.clear();
    await _persist();
    notifyListeners();
    await _reconcile();
  }

  // ── Keeping subscriptions honest ───────────────────────────────────────

  /// Every topic this device should be subscribed to right now.
  @visibleForTesting
  Set<String> desiredTopics({DateTime? now}) {
    if (!_enabled || _types.isEmpty) return const {};
    final at = now ?? DateTime.now();

    return {
      // A club is one durable subscription per alert type, resolved by the
      // sender when it sends. Its next fixture does not have to exist yet, and
      // the phone does not have to be opened before it is played.
      for (final clubId in _clubs)
        for (final type in _types) clubAlertTopic(clubId, type),

      // A bell is kept until well past its own kickoff, not until the match
      // disappears from the list on screen. The grace period matters for the
      // result alert: a match the app has already seen finish may not have
      // been sent yet by the worker.
      for (final entry in _bells.entries)
        if (!_muted.contains(entry.key) && !_isBellExpired(entry.value, at))
          for (final type in _types) matchAlertTopic(entry.key, type),

      // Joining a mute topic is how a subscriber is excluded from one of their
      // club's matches. The sender negates this term; until that operator is
      // proven against the live API the exclusion is unproven with it.
      for (final fixtureId in _muted) muteTopic(fixtureId),
    };
  }

  /// How long after kickoff a per-match subscription is kept.
  ///
  /// Long enough to cover stoppage, a half-time of any length, extra time and
  /// penalties, plus the delay between a match ending and the worker noticing.
  static const Duration bellLifetimeAfterKickoff = Duration(hours: 5);

  static bool _isBellExpired(DateTime kickoff, DateTime now) =>
      now.isAfter(kickoff.add(bellLifetimeAfterKickoff));

  /// Drops bells and mutes for matches that are long over, and brings
  /// subscriptions back in line. Safe to call on resume.
  Future<void> pruneAndSync({DateTime? now}) async {
    await load();
    final at = now ?? DateTime.now();
    final expired = _bells.entries
        .where((e) => _isBellExpired(e.value, at))
        .map((e) => e.key)
        .toList();
    for (final id in expired) {
      _bells.remove(id);
      _muted.remove(id);
    }
    if (expired.isNotEmpty) await _persist();
    await _reconcile();
  }

  /// Brings the device's subscriptions in line with [desiredTopics].
  ///
  /// Both directions matter. A subscription that is never removed keeps
  /// delivering alerts for a switch the user turned off weeks ago, and FCM
  /// offers no way to read back what a device is subscribed to — so the record
  /// on disk is the only thing that can tell us what to remove.
  Future<void> _reconcile() {
    final next = _queue.then((_) => _reconcileNow());
    _queue = next.catchError((_) {});
    return next;
  }

  Future<void> _reconcileNow() async {
    final desired = desiredTopics();
    final toAdd = desired.difference(_subscribed);
    final toRemove = _subscribed.difference(desired);
    if (toAdd.isEmpty && toRemove.isEmpty) {
      if (_syncState != AlertSyncState.ok && _subscribed.isNotEmpty) {
        _setState(AlertSyncState.ok);
      }
      return;
    }

    _setState(AlertSyncState.pending);

    var failed = false;
    for (final topic in toRemove) {
      if (await gateway.unsubscribe(topic)) {
        _subscribed.remove(topic);
      } else {
        failed = true;
      }
    }
    for (final topic in toAdd) {
      if (await gateway.subscribe(topic)) {
        _subscribed.add(topic);
      } else {
        failed = true;
      }
    }

    await _persist();
    _setState(failed ? AlertSyncState.failed : AlertSyncState.ok);
    if (failed) {
      _lastError = 'تعذّر تحديث التنبيهات — سيُعاد المحاولة';
    } else {
      _lastError = null;
    }
  }

  /// Re-runs the reconcile after a failure, or after the app comes back.
  Future<void> retrySync() => _reconcile();

  Future<bool> _ensurePermission() async {
    // The only place the system dialog is allowed to appear: the moment the
    // user asks to be told about something.
    final granted = await gateway.ensurePermission();
    if (!granted) {
      _setState(AlertSyncState.permissionDenied);
      _lastError = 'الإشعارات غير مسموح بها — فعّلها من إعدادات النظام';
    }
    return granted;
  }

  void _setState(AlertSyncState state) {
    if (_syncState == state) return;
    _syncState = state;
    notifyListeners();
  }

  @visibleForTesting
  Future<void> debugReset({AlertsGateway? withGateway}) async {
    await _tokenWatch?.cancel();
    _tokenWatch = null;
    if (withGateway != null) gateway = withGateway;
    _loaded = false;
    _enabled = true;
    _types = {...MatchAlertType.quietDefault};
    _bells.clear();
    _clubs.clear();
    _muted.clear();
    _subscribed.clear();
    _syncState = AlertSyncState.idle;
    _lastError = null;
  }
}
