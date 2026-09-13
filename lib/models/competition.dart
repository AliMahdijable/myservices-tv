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

  /// Display order, and the single source of it.
  ///
  /// Everything that shows competitions reads this list in order — the filter
  /// pills on both tabs, the standings tab's opening selection, the league
  /// sections down the schedule — so the running order lives here and nowhere
  /// else. It had the Saudi league first, which also made it the table the
  /// standings tab opened on.
  ///
  /// Champions League first, then the other European competitions in the order
  /// they already had, then Arab competitions last. This is the order the
  /// competitions are shown in and nothing more: clubs are still ranked by
  /// points, and matches still run by kickoff time.
  static const List<Competition> all = [
    // ── Champions ──
    Competition(id: 2, name: 'دوري أبطال أوروبا', shortName: 'أبطال أوروبا'),
    // ── Other European competitions ──
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
    // ── Arab competitions ──
    Competition(
      id: 307,
      name: 'الدوري السعودي للمحترفين',
      shortName: 'السعودي',
    ),
  ];

  /// Where [id] sits in the running order. A competition the app does not
  /// list sorts after every one it does, rather than ahead of them.
  static int displayRank(int id) {
    for (var i = 0; i < all.length; i++) {
      if (all[i].id == id) return i;
    }
    return all.length;
  }

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
