/// Match schedules, results and league tables, as served by the home server's
/// own `/data/fixtures.json`.
///
/// The file is produced by a cron job on that server (scripts/fetch-fixtures.mjs
/// in the web project), which merges two keyless upstream sources and writes
/// Arabic team and competition names. The app therefore needs no API key, no
/// third-party network call and no name mapping of its own — and the whole
/// feature is only meaningful on the home network, which is why
/// [FixturesService] gates it on the server being reachable.
library;

/// How far along a match is.
enum MatchState {
  /// Not started.
  upcoming,

  /// Being played right now.
  live,

  /// Finished.
  finished,
}

extension MatchStateInfo on MatchState {
  String get label => switch (this) {
    MatchState.upcoming => 'لم تبدأ',
    MatchState.live => 'مباشر الآن',
    MatchState.finished => 'انتهت',
  };

  bool get hasScore => this != MatchState.upcoming;
}

class TeamSide {
  final String name;
  final String logoUrl;

  /// Null before kickoff.
  final String? score;

  const TeamSide({required this.name, this.logoUrl = '', this.score});

  factory TeamSide.fromJson(Map<String, dynamic> json) => TeamSide(
    name: json['name']?.toString() ?? '',
    logoUrl: json['logo']?.toString() ?? '',
    score: json['score']?.toString(),
  );

  int get goals => int.tryParse(score ?? '') ?? 0;
}

class Fixture {
  final String id;

  /// Kickoff, already converted to Baghdad time by the server.
  final DateTime kickoff;
  final String league;

  /// Display priority of the competition — lower sorts first. Set on the
  /// server so the app and the web front-end agree on ordering.
  final int rank;

  final MatchState state;
  final TeamSide home;
  final TeamSide away;

  const Fixture({
    required this.id,
    required this.kickoff,
    required this.league,
    required this.rank,
    required this.state,
    required this.home,
    required this.away,
  });

  static MatchState _stateFrom(String? raw) => switch (raw) {
    'in' => MatchState.live,
    'post' => MatchState.finished,
    _ => MatchState.upcoming,
  };

  static Fixture? fromJson(Map<String, dynamic> json) {
    final rawTime = json['ts']?.toString();
    if (rawTime == null || rawTime.isEmpty) return null;
    final kickoff = DateTime.tryParse(rawTime);
    if (kickoff == null) return null;

    final home = json['home'];
    final away = json['away'];
    if (home is! Map || away is! Map) return null;

    return Fixture(
      id: json['id']?.toString() ?? rawTime,
      // Local time: the server stamps +03:00, and toLocal() keeps a viewer in
      // another timezone honest rather than showing them Baghdad's clock.
      kickoff: kickoff.toLocal(),
      league: json['league']?.toString() ?? '',
      rank: (json['rank'] as num?)?.toInt() ?? 999,
      state: _stateFrom(json['state']?.toString()),
      home: TeamSide.fromJson(Map<String, dynamic>.from(home)),
      away: TeamSide.fromJson(Map<String, dynamic>.from(away)),
    );
  }

  /// Midnight of the match's day, for grouping.
  DateTime get day => DateTime(kickoff.year, kickoff.month, kickoff.day);
}

/// One club's row in a league table.
class StandingRow {
  final int position;
  final String team;
  final String logoUrl;
  final int played;
  final int won;
  final int drawn;
  final int lost;
  final int goalsFor;
  final int goalsAgainst;
  final int points;

  const StandingRow({
    required this.position,
    required this.team,
    required this.logoUrl,
    required this.played,
    required this.won,
    required this.drawn,
    required this.lost,
    required this.goalsFor,
    required this.goalsAgainst,
    required this.points,
  });

  static int _int(dynamic value) => (value as num?)?.toInt() ?? 0;

  static StandingRow? fromJson(Map<String, dynamic> json) {
    final team = json['name']?.toString();
    if (team == null || team.isEmpty) return null;
    return StandingRow(
      position: _int(json['pos']),
      team: team,
      logoUrl: json['logo']?.toString() ?? '',
      played: _int(json['played']),
      won: _int(json['won']),
      drawn: _int(json['draw']),
      lost: _int(json['lost']),
      goalsFor: _int(json['gf']),
      goalsAgainst: _int(json['ga']),
      points: _int(json['points']),
    );
  }

  int get goalDifference => goalsFor - goalsAgainst;
}

class LeagueTable {
  final String league;
  final int rank;
  final List<StandingRow> rows;

  const LeagueTable({
    required this.league,
    required this.rank,
    required this.rows,
  });

  static LeagueTable? fromJson(Map<String, dynamic> json) {
    final raw = json['rows'];
    if (raw is! List) return null;
    final rows = raw
        .whereType<Map>()
        .map((r) => StandingRow.fromJson(Map<String, dynamic>.from(r)))
        .whereType<StandingRow>()
        .toList()
      ..sort((a, b) => a.position.compareTo(b.position));
    if (rows.isEmpty) return null;

    return LeagueTable(
      league: json['league']?.toString() ?? '',
      rank: (json['rank'] as num?)?.toInt() ?? 999,
      rows: rows,
    );
  }
}

/// Everything the fixtures screen renders, from one file.
class FixturesData {
  final DateTime? updated;
  final List<Fixture> matches;
  final List<LeagueTable> tables;

  const FixturesData({
    required this.updated,
    required this.matches,
    required this.tables,
  });

  factory FixturesData.fromJson(Map<String, dynamic> json) {
    final rawMatches = json['matches'];
    final rawTables = json['standings'];

    final matches =
        (rawMatches is List
                ? rawMatches
                      .whereType<Map>()
                      .map((m) => Fixture.fromJson(Map<String, dynamic>.from(m)))
                      .whereType<Fixture>()
                      .toList()
                : <Fixture>[])
          ..sort((a, b) {
            final byTime = a.kickoff.compareTo(b.kickoff);
            return byTime != 0 ? byTime : a.rank.compareTo(b.rank);
          });

    final tables =
        (rawTables is List
                ? rawTables
                      .whereType<Map>()
                      .map(
                        (t) => LeagueTable.fromJson(Map<String, dynamic>.from(t)),
                      )
                      .whereType<LeagueTable>()
                      .toList()
                : <LeagueTable>[])
          ..sort((a, b) => a.rank.compareTo(b.rank));

    return FixturesData(
      updated: DateTime.tryParse(json['updated']?.toString() ?? ''),
      matches: matches,
      tables: tables,
    );
  }

  bool get isEmpty => matches.isEmpty && tables.isEmpty;
}
