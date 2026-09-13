import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/competition.dart';
import '../models/fixture.dart';
import '../models/standing.dart';

/// What a fixtures fetch produced, and whether every competition answered.
///
/// An empty list used to mean both "no matches today" and "every request
/// failed", and the screen could only render the first — so a rate-limited or
/// offline moment was shown to the user as a quiet, confident "لا توجد
/// مباريات في هذا اليوم".
class FixturesResult {
  final List<Fixture> fixtures;

  /// Competitions whose request did not answer. Empty on a clean fetch.
  final List<int> failedLeagueIds;

  const FixturesResult(this.fixtures, {this.failedLeagueIds = const []});

  bool get hasFailures => failedLeagueIds.isNotEmpty;

  /// True when nothing was returned and nothing failed — a genuinely empty day.
  bool get isGenuinelyEmpty => fixtures.isEmpty && failedLeagueIds.isEmpty;
}

/// One league's answer, kept separate from the merge so a failure survives it.
class _LeagueFetch {
  final List<Fixture> fixtures;
  final bool answered;
  const _LeagueFetch(this.fixtures, {required this.answered});
}

/// Why a request did not produce data, and whether asking again could help.
enum _FailureKind {
  /// A blip: a dropped connection, a timeout, a 5xx, or the per-second rate
  /// limit. Worth exactly one more attempt.
  transient,

  /// A dead key, a lapsed plan, or the daily quota. Asking again inside the
  /// same second changes nothing and spends a request proving it.
  permanent,
}

class _Failure {
  final _FailureKind kind;

  /// How long the provider asked us to wait, if it said.
  final Duration? retryAfter;

  const _Failure(this.kind, {this.retryAfter});
}

/// A table, and whether the provider actually answered for it.
///
/// Serving a cached table on failure is right; counting that as success is
/// not. Without the flag the screen sees a non-empty list and reports the
/// refresh as having worked.
class StandingsResult {
  final List<List<Standing>> groups;
  final bool answered;

  const StandingsResult(this.groups, {required this.answered});

  bool get isEmpty => groups.isEmpty;
}

class _CacheEntry<T> {
  final T value;
  final DateTime storedAt;
  const _CacheEntry(this.value, this.storedAt);

  bool isFresh(Duration ttl) => DateTime.now().difference(storedAt) < ttl;
}

/// Wraps API-Football v3 (schedule + standings only — no goal-by-goal feed).
///
/// Results are cached in memory per call signature so switching between the
/// date chips or competition tabs the user already visited this session
/// doesn't re-spend the daily request quota.
/// Lets requests out one at a time, spaced, with a ceiling on how many are in
/// the air at once.
///
/// API-Football's Pro plan allows 300 requests a minute *and* 5 a second.
/// Eight leagues fired together all start within a millisecond of each other,
/// which is eight in that second — and the account was checked and healthy at
/// the time the errors were being seen, so the burst is what this addresses.
/// Whether the daily quota was ever also involved is not established either
/// way. A cap on concurrency alone would not help: replies come back in under
/// 300ms, so slots free up faster than the per-second limit allows new starts.
///
/// So the control is the gap between *starts*, not the number in flight. Eight
/// requests at 300ms apart is 3.3 a second, with room under the limit for the
/// screen and the standings tab to overlap without colliding.
class _Pacer {
  _Pacer._();

  static const Duration minimumGap = Duration(milliseconds: 300);
  static const int maxInFlight = 2;

  static DateTime? _lastStart;
  static int _inFlight = 0;

  /// The admission currently ahead of us, if any. Admissions are chained so
  /// two callers cannot measure the same gap and both decide they may go now.
  ///
  /// Null rather than a resolved Future when nothing is pending. A Future
  /// created outside the caller's zone never delivers its callbacks inside
  /// one: a seed made in a test's setUp belongs to the real event loop, and
  /// chaining onto it from inside a widget test's fake clock produces a
  /// request that is admitted and then waits forever.
  static Future<void>? _admissions;

  /// Replaced in tests so a paced sweep can be measured without waiting for it.
  static Future<void> Function(Duration) sleep = _realSleep;

  static Future<void> _realSleep(Duration duration) =>
      Future<void>.delayed(duration);

  static Future<T> run<T>(Future<T> Function() request) async {
    await _admit();
    try {
      return await request();
    } finally {
      _inFlight--;
    }
  }

  static Future<void> _admit() {
    final ahead = _admissions ?? Future<void>.value();
    final next = ahead.then((_) async {
      while (_inFlight >= maxInFlight) {
        await sleep(const Duration(milliseconds: 20));
      }
      final now = DateTime.now();
      final earliest = _lastStart?.add(minimumGap);
      if (earliest != null && earliest.isAfter(now)) {
        await sleep(earliest.difference(now));
      }
      _lastStart = DateTime.now();
      _inFlight++;
    });
    _admissions = next.catchError((_) {});
    return next;
  }

  static void reset() {
    _lastStart = null;
    _inFlight = 0;
    _admissions = null;
    // Restored as well: a test that sped the clock up would otherwise leave
    // every later test running against its stub.
    sleep = _realSleep;
  }
}

class FootballApiService {
  static const _fixturesTtl = Duration(seconds: 60);
  static const _standingsTtl = Duration(minutes: 10);

  static final Map<String, _CacheEntry<List<Fixture>>> _fixturesCache = {};
  static final Map<String, _CacheEntry<List<List<Standing>>>> _standingsCache =
      {};

  /// Fixtures to serve instead of calling the API.
  ///
  /// Exists so the schedule's section ordering can be tested against a day
  /// that is awkward on purpose — an Arab fixture kicking off before a
  /// European one — without depending on what happens to be played today, and
  /// without a widget test reaching the network.
  @visibleForTesting
  static List<Fixture>? debugFixturesOverride;

  /// Clears every cache, in-flight request and pacing measurement.
  ///
  /// The service is static, so without this one test's timings and cached days
  /// leak into the next and the failures look like flakes.
  @visibleForTesting
  static void debugReset() {
    _fixturesCache.clear();
    _standingsCache.clear();
    _inFlightFixtures.clear();
    _inFlightStandings.clear();
    debugFixturesOverride = null;
    _Pacer.reset();
  }

  /// One retry, and only for something a retry can fix.
  static const Duration _retryBackoff = Duration(milliseconds: 600);

  /// A provider that asks us to wait longer than this is not worth blocking a
  /// screen for; the request is reported as failed and can be retried by hand.
  static const Duration _maxRetryAfter = Duration(seconds: 5);

  /// Requests already in the air, by cache key.
  ///
  /// Two rebuilds a moment apart used to fire two identical requests at a
  /// provider that counts them. Whoever asks second now waits on the first.
  static final Map<String, Future<_LeagueFetch>> _inFlightFixtures = {};
  static final Map<String, Future<StandingsResult>> _inFlightStandings = {};

  static Map<String, String> get _headers => {
    'x-apisports-key': AppConfig.footballApiKey,
  };

  /// Fixtures for [date] across every competition in [Competition.all],
  /// merged and sorted by kickoff time. Each league is fetched in parallel;
  /// one failing league doesn't take the others down with it.
  static Future<FixturesResult> fixturesForDate(
    DateTime date, {
    bool forceRefresh = false,
  }) async {
    final override = debugFixturesOverride;
    if (override != null) {
      // Sorted the way the real merge sorts, so a test sees the same ordering
      // the screen would really be handed.
      final sorted = List.of(override)
        ..sort((a, b) => a.kickoff.compareTo(b.kickoff));
      return FixturesResult(sorted);
    }

    final ids = Competition.all.map((c) => c.id).toList();
    final results = await Future.wait(
      ids.map((id) => _fetchLeague(id, date, forceRefresh: forceRefresh)),
    );

    final merged = <Fixture>[];
    final failed = <int>[];
    for (var i = 0; i < results.length; i++) {
      merged.addAll(results[i].fixtures);
      if (!results[i].answered) failed.add(ids[i]);
    }
    merged.sort((a, b) => a.kickoff.compareTo(b.kickoff));
    return FixturesResult(merged, failedLeagueIds: failed);
  }

  /// Re-asks only the competitions that did not answer, keeping the rest.
  ///
  /// The retry control used to refetch all eight — including the seven that
  /// worked — which multiplied the load at exactly the moment the provider was
  /// already refusing requests.
  static Future<FixturesResult> retryFailed(
    DateTime date,
    FixturesResult previous,
  ) async {
    if (!previous.hasFailures) return previous;

    final ids = previous.failedLeagueIds;
    final results = await Future.wait(
      ids.map((id) => _fetchLeague(id, date, forceRefresh: true)),
    );

    // Drop whatever the failed leagues previously contributed before adding
    // the new answer. A stale cached value for one of them would otherwise be
    // kept alongside its own replacement — the same match listed twice, or a
    // fixture that has since been removed lingering under a fresh result.
    final retrying = ids.toSet();
    final merged = <Fixture>[
      for (final fixture in previous.fixtures)
        if (!retrying.contains(fixture.leagueId)) fixture,
    ];
    final stillFailed = <int>[];
    for (var i = 0; i < results.length; i++) {
      merged.addAll(results[i].fixtures);
      if (!results[i].answered) stillFailed.add(ids[i]);
    }
    merged.sort((a, b) => a.kickoff.compareTo(b.kickoff));
    return FixturesResult(merged, failedLeagueIds: stillFailed);
  }

  static Future<FixturesResult> fixturesForLeague(
    int leagueId,
    DateTime date, {
    bool forceRefresh = false,
  }) async {
    final override = debugFixturesOverride;
    if (override != null) {
      final sorted = override.where((f) => f.leagueId == leagueId).toList()
        ..sort((a, b) => a.kickoff.compareTo(b.kickoff));
      return FixturesResult(sorted);
    }

    final fetch = await _fetchLeague(
      leagueId,
      date,
      forceRefresh: forceRefresh,
    );
    return FixturesResult(
      fetch.fixtures,
      failedLeagueIds: fetch.answered ? const [] : [leagueId],
    );
  }

  static Future<_LeagueFetch> _fetchLeague(
    int leagueId,
    DateTime date, {
    bool forceRefresh = false,
  }) {
    final dateKey = _dateKey(date);
    final cacheKey = '$leagueId|$dateKey';

    if (!forceRefresh) {
      final cached = _fixturesCache[cacheKey];
      if (cached != null && cached.isFresh(_fixturesTtl)) {
        return Future.value(_LeagueFetch(cached.value, answered: true));
      }
    }

    // Whoever asks while a request is already in the air waits on that one.
    final existing = _inFlightFixtures[cacheKey];
    if (existing != null) return existing;

    final request = _fetchLeagueOverNetwork(leagueId, date, dateKey, cacheKey)
        .whenComplete(() {
          // A block, not an arrow. Map.remove returns the value it removed — which
          // here is this very Future — and whenComplete waits on whatever its
          // callback returns. Written as an expression it made the request wait for
          // itself, and the screen sat on a spinner that could never end.
          _inFlightFixtures.remove(cacheKey);
        });
    _inFlightFixtures[cacheKey] = request;
    return request;
  }

  static Future<_LeagueFetch> _fetchLeagueOverNetwork(
    int leagueId,
    DateTime date,
    String dateKey,
    String cacheKey,
  ) async {
    final season = Competition.seasonFor(date);
    final uri = Uri.parse('${AppConfig.footballApiBase}/fixtures').replace(
      queryParameters: {
        'league': '$leagueId',
        'season': '$season',
        'date': dateKey,
      },
    );

    for (var attempt = 1; attempt <= 2; attempt++) {
      final outcome = await _readFixtures(uri, cacheKey);
      if (outcome is List<Fixture>) {
        _fixturesCache[cacheKey] = _CacheEntry(outcome, DateTime.now());
        return _LeagueFetch(outcome, answered: true);
      }

      final failure = outcome as _Failure;
      if (attempt == 2 || failure.kind == _FailureKind.permanent) break;

      final wait = failure.retryAfter ?? _retryBackoff;
      if (wait > _maxRetryAfter) break;
      await _Pacer.sleep(wait);
    }

    // A stale cached value beats a blank section on a transient failure, but it
    // is still not an answer — the caller has to be able to say so.
    return _staleOrNothing(cacheKey);
  }

  /// Either the fixtures, or why there are none.
  static Future<Object> _readFixtures(Uri uri, String cacheKey) async {
    try {
      final res = await _Pacer.run(
        () => http
            .get(uri, headers: _headers)
            .timeout(const Duration(seconds: 12)),
      );

      if (res.statusCode != 200) {
        return _Failure(
          _statusIsTransient(res.statusCode)
              ? _FailureKind.transient
              : _FailureKind.permanent,
          retryAfter: _retryAfterOf(res),
        );
      }

      final body = jsonDecode(utf8.decode(res.bodyBytes));

      // API-Football answers a dead key, a lapsed subscription, an exhausted
      // quota *and* the per-second rate limit with HTTP 200, an empty response
      // and a populated `errors`. Read as a bare 200 they all become "no
      // matches today", every league, every day, until someone thinks to open
      // the dashboard.
      final apiError = _errorOf(body);
      if (apiError != null) {
        return _Failure(
          _apiErrorIsTransient(apiError)
              ? _FailureKind.transient
              : _FailureKind.permanent,
        );
      }

      final rawResponse = body is Map ? body['response'] : null;
      if (rawResponse is! List) {
        return const _Failure(_FailureKind.permanent);
      }

      return rawResponse
          .whereType<Map<String, dynamic>>()
          .map(Fixture.fromJson)
          .toList();
    } catch (_) {
      // A dropped connection or a timeout: the one case a second attempt is
      // most likely to fix.
      return const _Failure(_FailureKind.transient);
    }
  }

  static String _dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  /// 429 and the 5xx family are the provider having a moment. Everything else
  /// is us asking for something it will refuse just as firmly next time.
  static bool _statusIsTransient(int status) =>
      status == 429 || status == 408 || (status >= 500 && status < 600);

  static Duration? _retryAfterOf(http.Response response) {
    final header = response.headers['retry-after'];
    if (header == null) return null;
    final seconds = int.tryParse(header.trim());
    if (seconds == null || seconds < 0) return null;
    return Duration(seconds: seconds);
  }

  /// The error keys API-Football uses, split by whether waiting helps.
  ///
  /// `rateLimit` is the per-second ceiling and clears in under a second.
  /// `requests` is the daily quota, `token` a dead key and `plan` a lapsed
  /// subscription — none of which a second attempt improves, and each of which
  /// would spend another request proving it.
  static bool _apiErrorIsTransient(String error) {
    final lower = error.toLowerCase();
    if (lower.contains('ratelimit') || lower.contains('rate limit')) {
      return true;
    }
    return false;
  }

  /// The error text from a 200 body, or null when there was none.
  static String? _errorOf(dynamic body) {
    if (body is! Map) return null;
    final errors = body['errors'];
    if (errors is Map && errors.isNotEmpty) {
      return errors.entries.map((e) => '${e.key}: ${e.value}').join('; ');
    }
    if (errors is List && errors.isNotEmpty) return errors.join('; ');
    return null;
  }

  /// A failed fetch: hand back whatever was cached, but never claim it as an
  /// answer, so the screen can tell the user something went wrong.
  static _LeagueFetch _staleOrNothing(String cacheKey) => _LeagueFetch(
    _fixturesCache[cacheKey]?.value ?? const [],
    answered: false,
  );

  /// The league table for [leagueId], as one list of rows per group (most
  /// competitions have exactly one group; the Champions League group stage
  /// has several).
  static Future<StandingsResult> standings(
    int leagueId, {
    int? season,
    bool forceRefresh = false,
  }) {
    final resolvedSeason = season ?? Competition.seasonFor(DateTime.now());
    final cacheKey = '$leagueId|$resolvedSeason';

    if (!forceRefresh) {
      final cached = _standingsCache[cacheKey];
      if (cached != null && cached.isFresh(_standingsTtl)) {
        return Future.value(StandingsResult(cached.value, answered: true));
      }
    }

    // The standings tab shares the pacer with the schedule, so opening one
    // straight after the other does not put both over the per-second limit.
    final existing = _inFlightStandings[cacheKey];
    if (existing != null) return existing;

    final request = _standingsOverNetwork(leagueId, resolvedSeason, cacheKey)
        .whenComplete(() {
          _inFlightStandings.remove(cacheKey);
        });
    _inFlightStandings[cacheKey] = request;
    return request;
  }

  static Future<StandingsResult> _standingsOverNetwork(
    int leagueId,
    int resolvedSeason,
    String cacheKey,
  ) async {
    final uri = Uri.parse('${AppConfig.footballApiBase}/standings').replace(
      queryParameters: {'league': '$leagueId', 'season': '$resolvedSeason'},
    );

    // The same one retry the schedule gets. A table that fails to load is the
    // whole tab, so a blip here is more visible than a blip in one league.
    for (var attempt = 1; attempt <= 2; attempt++) {
      final outcome = await _readStandings(uri);
      if (outcome is List<List<Standing>>) {
        _standingsCache[cacheKey] = _CacheEntry(outcome, DateTime.now());
        return StandingsResult(outcome, answered: true);
      }

      final failure = outcome as _Failure;
      if (attempt == 2 || failure.kind == _FailureKind.permanent) break;
      final wait = failure.retryAfter ?? _retryBackoff;
      if (wait > _maxRetryAfter) break;
      await _Pacer.sleep(wait);
    }

    // The cached table is still the best thing to show — but it is not an
    // answer, and the caller has to be able to say so.
    return StandingsResult(
      _standingsCache[cacheKey]?.value ?? const [],
      answered: false,
    );
  }

  /// Either the table, grouped, or why there is none.
  static Future<Object> _readStandings(Uri uri) async {
    try {
      final res = await _Pacer.run(
        () => http
            .get(uri, headers: _headers)
            .timeout(const Duration(seconds: 12)),
      );

      if (res.statusCode != 200) {
        return _Failure(
          _statusIsTransient(res.statusCode)
              ? _FailureKind.transient
              : _FailureKind.permanent,
          retryAfter: _retryAfterOf(res),
        );
      }

      final body = jsonDecode(utf8.decode(res.bodyBytes));
      final apiError = _errorOf(body);
      if (apiError != null) {
        return _Failure(
          _apiErrorIsTransient(apiError)
              ? _FailureKind.transient
              : _FailureKind.permanent,
        );
      }

      final rawResponse = body is Map ? body['response'] : null;
      if (rawResponse is! List) {
        // A shape we do not understand is a failure.
        return const _Failure(_FailureKind.permanent);
      }
      if (rawResponse.isEmpty) {
        // An empty list with no errors is a real answer: this competition has
        // no table yet. Reporting it as a failure invented an error for a
        // tournament that simply has not started.
        return const <List<Standing>>[];
      }

      final leagueJson =
          (rawResponse.first as Map<String, dynamic>)['league']
              as Map<String, dynamic>?;
      final rawGroups = leagueJson?['standings'];
      if (rawGroups is! List) return const <List<Standing>>[];

      return rawGroups
          .whereType<List>()
          .map(
            (group) => group
                .whereType<Map<String, dynamic>>()
                .map(Standing.fromJson)
                .toList(),
          )
          .where((group) => group.isNotEmpty)
          .toList();
    } catch (_) {
      return const _Failure(_FailureKind.transient);
    }
  }
}
