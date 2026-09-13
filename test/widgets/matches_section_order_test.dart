import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/models/fixture.dart';
import 'package:myservices_tv/screens/matches_screen.dart';
import 'package:myservices_tv/services/football_api_service.dart';
import 'package:myservices_tv/theme/app_theme.dart';

/// League sections used to follow whichever competition kicked off earliest,
/// so an early Saudi fixture pushed the Champions League to the bottom of the
/// day. This drives the real screen with a day built to be awkward: the Arab
/// fixture kicks off first, the Champions League last.
void main() {
  Fixture fixture({
    required int id,
    required int leagueId,
    required String leagueName,
    required int hour,
    required String home,
    required String away,
  }) => Fixture(
    id: id,
    kickoff: DateTime.now().copyWith(hour: hour, minute: 0, second: 0),
    statusShort: 'NS',
    leagueId: leagueId,
    leagueName: leagueName,
    leagueLogoUrl: '',
    round: 'Regular Season - 5',
    home: FixtureTeam(id: id * 10, name: home, logoUrl: ''),
    away: FixtureTeam(id: id * 10 + 1, name: away, logoUrl: ''),
  );

  setUp(() {
    FootballApiService.debugFixturesOverride = [
      // Deliberately out of running order, and deliberately the earliest.
      fixture(
        id: 1,
        leagueId: 307,
        leagueName: 'Saudi Pro League',
        hour: 10,
        home: 'الهلال',
        away: 'النصر',
      ),
      fixture(
        id: 2,
        leagueId: 39,
        leagueName: 'Premier League',
        hour: 14,
        home: 'Arsenal',
        away: 'Chelsea',
      ),
      fixture(
        id: 3,
        leagueId: 2,
        leagueName: 'UEFA Champions League',
        hour: 19,
        home: 'Real Madrid',
        away: 'Bayern',
      ),
    ];
  });

  tearDown(() => FootballApiService.debugFixturesOverride = null);

  /// A viewport tall enough that all three sections are laid out at once, so
  /// their order in the tree is the order on screen rather than an artefact of
  /// what the list happened to build.
  const tall = Size(430, 1600);

  testWidgets('sections run Champions, English, Saudi — not by kickoff', (
    tester,
  ) async {
    tester.view.physicalSize = tall;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: const Scaffold(
          backgroundColor: AppColors.primaryDark,
          body: MatchesScreen(embedded: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Read the section headings top to bottom by their painted position.
    double yOf(String arabicName) =>
        tester.getTopLeft(find.text(arabicName)).dy;

    final champions = yOf('دوري أبطال أوروبا');
    final english = yOf('الدوري الإنجليزي الممتاز');
    final saudi = yOf('الدوري السعودي للمحترفين');

    expect(
      champions,
      lessThan(english),
      reason: 'the Champions League must head the day',
    );
    expect(
      english,
      lessThan(saudi),
      reason: 'Arab competitions come last, even when they kick off first',
    );
  });

  testWidgets('kickoff order inside a section is untouched', (tester) async {
    FootballApiService.debugFixturesOverride = [
      fixture(
        id: 4,
        leagueId: 39,
        leagueName: 'Premier League',
        hour: 20,
        home: 'Late Home',
        away: 'Late Away',
      ),
      fixture(
        id: 5,
        leagueId: 39,
        leagueName: 'Premier League',
        hour: 12,
        home: 'Early Home',
        away: 'Early Away',
      ),
    ];

    tester.view.physicalSize = tall;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: const Scaffold(
          backgroundColor: AppColors.primaryDark,
          body: MatchesScreen(embedded: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The running order decides which competition comes first, and nothing
    // else: within one, the earlier kickoff is still on top.
    expect(
      tester.getTopLeft(find.text('Early Home')).dy,
      lessThan(tester.getTopLeft(find.text('Late Home')).dy),
    );
  });
}
