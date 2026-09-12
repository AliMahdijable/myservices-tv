/// A curated list of leagues/cups shown in the schedule and standings
/// screens. IDs are API-Football's stable league identifiers.
class Competition {
  final int id;
  final String name;
  final String shortName;

  const Competition({
    required this.id,
    required this.name,
    required this.shortName,
  });

  String get logoUrl => 'https://media.api-sports.io/football/leagues/$id.png';

  /// The season API-Football expects for [date]: European and Saudi
  /// domestic leagues both run August-through-May, so a fixture in, say,
  /// February 2027 still belongs to the season labelled "2026".
  static int seasonFor(DateTime date) =>
      date.month >= 7 ? date.year : date.year - 1;

  static const List<Competition> all = [
    Competition(
      id: 307,
      name: 'الدوري السعودي للمحترفين',
      shortName: 'السعودي',
    ),
    Competition(id: 2, name: 'دوري أبطال أوروبا', shortName: 'أبطال أوروبا'),
    Competition(id: 3, name: 'الدوري الأوروبي', shortName: 'الأوروبي'),
    Competition(
      id: 39,
      name: 'الدوري الإنجليزي الممتاز',
      shortName: 'الإنجليزي',
    ),
    Competition(id: 140, name: 'الدوري الإسباني', shortName: 'الإسباني'),
    Competition(id: 135, name: 'الدوري الإيطالي', shortName: 'الإيطالي'),
    Competition(id: 78, name: 'الدوري الألماني', shortName: 'الألماني'),
    Competition(id: 61, name: 'الدوري الفرنسي', shortName: 'الفرنسي'),
  ];

  /// The curated entry for [id], or null when the API returns a competition
  /// this app does not list.
  ///
  /// Deliberately nullable. The previous lookup fell back to `all.first`, so
  /// an unrecognised id would have been labelled الدوري السعودي — a wrong
  /// answer is worse here than no answer, because the caller can fall back to
  /// the name the API itself sent.
  static Competition? find(int id) {
    for (final competition in all) {
      if (competition.id == id) return competition;
    }
    return null;
  }

  /// The Arabic name for [id], falling back to whatever the API called it.
  static String nameFor(int id, String fallback) => find(id)?.name ?? fallback;
}
