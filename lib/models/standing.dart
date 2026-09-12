class StandingTeam {
  final int id;
  final String name;
  final String logoUrl;

  const StandingTeam({
    required this.id,
    required this.name,
    required this.logoUrl,
  });

  factory StandingTeam.fromJson(Map<String, dynamic> json) => StandingTeam(
    id: json['id'] as int? ?? 0,
    name: json['name']?.toString() ?? '',
    logoUrl: json['logo']?.toString() ?? '',
  );
}

/// One row of a league table, plus a [group] label carried alongside it so a
/// competition split into multiple groups (Champions League group stage)
/// can be rendered as separate mini-tables instead of one misleading list.
class Standing {
  final String group;
  final int rank;
  final StandingTeam team;
  final int played;
  final int win;
  final int draw;
  final int lose;
  final int goalsFor;
  final int goalsAgainst;
  final int goalsDiff;
  final int points;
  final String form;

  /// Free-text API-Football sends for the row's qualification zone, e.g.
  /// "Promotion - Champions League (Group Stage)" or "Relegation" — used to
  /// pick the colored side-bar.
  final String? description;

  const Standing({
    required this.group,
    required this.rank,
    required this.team,
    required this.played,
    required this.win,
    required this.draw,
    required this.lose,
    required this.goalsFor,
    required this.goalsAgainst,
    required this.goalsDiff,
    required this.points,
    required this.form,
    this.description,
  });

  factory Standing.fromJson(Map<String, dynamic> json) {
    final all = json['all'] as Map<String, dynamic>? ?? const {};
    final goals = all['goals'] as Map<String, dynamic>? ?? const {};
    return Standing(
      group: json['group']?.toString() ?? '',
      rank: json['rank'] as int? ?? 0,
      team: StandingTeam.fromJson(
        json['team'] as Map<String, dynamic>? ?? const {},
      ),
      played: all['played'] as int? ?? 0,
      win: all['win'] as int? ?? 0,
      draw: all['draw'] as int? ?? 0,
      lose: all['lose'] as int? ?? 0,
      goalsFor: goals['for'] as int? ?? 0,
      goalsAgainst: goals['against'] as int? ?? 0,
      goalsDiff: json['goalsDiff'] as int? ?? 0,
      points: json['points'] as int? ?? 0,
      form: json['form']?.toString() ?? '',
      description: json['description']?.toString(),
    );
  }
}
