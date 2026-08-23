/// A single football match from the fixtures API — kickoff time, teams,
/// score, and status. Independent of the app's own IPTV channel lineup;
/// see fixtures_service.dart for the best-effort channel-suggestion logic.
class Fixture {
  final int id;
  final DateTime kickoff;
  final String status;
  final int? elapsedMinutes;
  final String league;
  final String leagueLogoUrl;
  final String homeTeam;
  final String homeLogoUrl;
  final String awayTeam;
  final String awayLogoUrl;
  final int? homeGoals;
  final int? awayGoals;

  const Fixture({
    required this.id,
    required this.kickoff,
    required this.status,
    required this.elapsedMinutes,
    required this.league,
    required this.leagueLogoUrl,
    required this.homeTeam,
    required this.homeLogoUrl,
    required this.awayTeam,
    required this.awayLogoUrl,
    required this.homeGoals,
    required this.awayGoals,
  });

  static const Set<String> _liveStatuses = {
    '1H',
    '2H',
    'HT',
    'ET',
    'BT',
    'P',
    'SUSP',
    'INT',
    'LIVE',
  };
  static const Set<String> _finishedStatuses = {
    'FT',
    'AET',
    'PEN',
    'AWD',
    'WO',
  };

  bool get isLive => _liveStatuses.contains(status);
  bool get isFinished => _finishedStatuses.contains(status);
  bool get isUpcoming => !isLive && !isFinished;

  factory Fixture.fromJson(Map<String, dynamic> json) {
    final fixtureJson = json['fixture'] as Map<String, dynamic>? ?? const {};
    final leagueJson = json['league'] as Map<String, dynamic>? ?? const {};
    final teamsJson = json['teams'] as Map<String, dynamic>? ?? const {};
    final homeJson = teamsJson['home'] as Map<String, dynamic>? ?? const {};
    final awayJson = teamsJson['away'] as Map<String, dynamic>? ?? const {};
    final goalsJson = json['goals'] as Map<String, dynamic>? ?? const {};
    final statusJson =
        fixtureJson['status'] as Map<String, dynamic>? ?? const {};

    final dateString = fixtureJson['date']?.toString();
    final kickoff = dateString != null
        ? (DateTime.tryParse(dateString)?.toLocal() ?? DateTime.now())
        : DateTime.now();

    return Fixture(
      id: (fixtureJson['id'] as num?)?.toInt() ?? 0,
      kickoff: kickoff,
      status: statusJson['short']?.toString() ?? 'NS',
      elapsedMinutes: (statusJson['elapsed'] as num?)?.toInt(),
      league: leagueJson['name']?.toString() ?? '',
      leagueLogoUrl: leagueJson['logo']?.toString() ?? '',
      homeTeam: homeJson['name']?.toString() ?? '',
      homeLogoUrl: homeJson['logo']?.toString() ?? '',
      awayTeam: awayJson['name']?.toString() ?? '',
      awayLogoUrl: awayJson['logo']?.toString() ?? '',
      homeGoals: (goalsJson['home'] as num?)?.toInt(),
      awayGoals: (goalsJson['away'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'kickoff': kickoff.toIso8601String(),
    'status': status,
    'elapsedMinutes': elapsedMinutes,
    'league': league,
    'leagueLogoUrl': leagueLogoUrl,
    'homeTeam': homeTeam,
    'homeLogoUrl': homeLogoUrl,
    'awayTeam': awayTeam,
    'awayLogoUrl': awayLogoUrl,
    'homeGoals': homeGoals,
    'awayGoals': awayGoals,
  };

  factory Fixture.fromCacheJson(Map<String, dynamic> json) => Fixture(
    id: json['id'] as int? ?? 0,
    kickoff: DateTime.tryParse(json['kickoff']?.toString() ?? '') ?? DateTime.now(),
    status: json['status']?.toString() ?? 'NS',
    elapsedMinutes: json['elapsedMinutes'] as int?,
    league: json['league']?.toString() ?? '',
    leagueLogoUrl: json['leagueLogoUrl']?.toString() ?? '',
    homeTeam: json['homeTeam']?.toString() ?? '',
    homeLogoUrl: json['homeLogoUrl']?.toString() ?? '',
    awayTeam: json['awayTeam']?.toString() ?? '',
    awayLogoUrl: json['awayLogoUrl']?.toString() ?? '',
    homeGoals: json['homeGoals'] as int?,
    awayGoals: json['awayGoals'] as int?,
  );
}
