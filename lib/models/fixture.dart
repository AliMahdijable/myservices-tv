/// Live/finished/upcoming status of a single match, grouped from
/// API-Football's short status codes into the four buckets the UI cares
/// about — the raw codes (1H/2H/ET/BT/P …) only matter for the "live" label.
enum FixturePhase { upcoming, live, finished, other }

class FixtureTeam {
  final int id;
  final String name;
  final String logoUrl;
  final bool? winner;

  const FixtureTeam({
    required this.id,
    required this.name,
    required this.logoUrl,
    this.winner,
  });

  factory FixtureTeam.fromJson(Map<String, dynamic> json) => FixtureTeam(
    id: json['id'] as int? ?? 0,
    name: json['name']?.toString() ?? '',
    logoUrl: json['logo']?.toString() ?? '',
    winner: json['winner'] as bool?,
  );
}

class Fixture {
  final int id;
  final DateTime kickoff;
  final String statusShort;
  final int? elapsedMinutes;
  final int leagueId;
  final String leagueName;
  final String leagueLogoUrl;
  final String round;
  final FixtureTeam home;
  final FixtureTeam away;
  final int? homeGoals;
  final int? awayGoals;
  final String? venueName;

  const Fixture({
    required this.id,
    required this.kickoff,
    required this.statusShort,
    this.elapsedMinutes,
    required this.leagueId,
    required this.leagueName,
    required this.leagueLogoUrl,
    required this.round,
    required this.home,
    required this.away,
    this.homeGoals,
    this.awayGoals,
    this.venueName,
  });

  static const _liveCodes = {
    '1H',
    '2H',
    'HT',
    'ET',
    'BT',
    'P',
    'LIVE',
    'SUSP',
    'INT',
  };
  static const _finishedCodes = {'FT', 'AET', 'PEN'};
  static const _abnormalCodes = {'PST', 'CANC', 'ABD', 'AWD', 'WO'};

  FixturePhase get phase {
    if (_liveCodes.contains(statusShort)) return FixturePhase.live;
    if (_finishedCodes.contains(statusShort)) return FixturePhase.finished;
    if (_abnormalCodes.contains(statusShort)) return FixturePhase.other;
    return FixturePhase.upcoming;
  }

  factory Fixture.fromJson(Map<String, dynamic> json) {
    final fixtureJson = json['fixture'] as Map<String, dynamic>? ?? const {};
    final leagueJson = json['league'] as Map<String, dynamic>? ?? const {};
    final teamsJson = json['teams'] as Map<String, dynamic>? ?? const {};
    final goalsJson = json['goals'] as Map<String, dynamic>? ?? const {};
    final statusJson =
        fixtureJson['status'] as Map<String, dynamic>? ?? const {};
    final venueJson = fixtureJson['venue'] as Map<String, dynamic>?;

    return Fixture(
      id: fixtureJson['id'] as int? ?? 0,
      kickoff:
          DateTime.tryParse(fixtureJson['date']?.toString() ?? '')?.toLocal() ??
          DateTime.now(),
      statusShort: statusJson['short']?.toString() ?? 'NS',
      elapsedMinutes: statusJson['elapsed'] as int?,
      leagueId: leagueJson['id'] as int? ?? 0,
      leagueName: leagueJson['name']?.toString() ?? '',
      leagueLogoUrl: leagueJson['logo']?.toString() ?? '',
      round: leagueJson['round']?.toString() ?? '',
      home: FixtureTeam.fromJson(
        teamsJson['home'] as Map<String, dynamic>? ?? const {},
      ),
      away: FixtureTeam.fromJson(
        teamsJson['away'] as Map<String, dynamic>? ?? const {},
      ),
      homeGoals: goalsJson['home'] as int?,
      awayGoals: goalsJson['away'] as int?,
      venueName: venueJson?['name']?.toString(),
    );
  }
}
