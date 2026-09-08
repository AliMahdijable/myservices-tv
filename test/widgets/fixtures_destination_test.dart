import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/theme/app_theme.dart';
import 'package:myservices_tv/widgets/home_bottom_nav.dart';
import 'package:myservices_tv/widgets/nav_rail.dart';

/// The fixtures destination is gated on the home server being reachable, and
/// the gate is expressed as a nullable callback. Both navigation widgets take
/// that callback, so both can silently drop it: `home_bottom_nav.dart` accepted
/// `onFixturesTap`, documented it, and rendered nothing for it — the section was
/// unreachable on every phone regardless of the network. These tests pin the
/// contract on both widgets so the next one to grow a destination cannot repeat
/// it.
void main() {
  Widget wrap(Widget child, {Size size = const Size(390, 844)}) => MediaQuery(
    data: MediaQueryData(size: size),
    child: Builder(
      builder: (_) => MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          backgroundColor: AppColors.primaryDark,
          body: Align(alignment: Alignment.bottomCenter, child: child),
        ),
      ),
    ),
  );

  group('phone bottom bar', () {
    testWidgets('shows the fixtures destination when the server is reachable', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        wrap(
          HomeBottomNav(
            searchEnabled: true,
            onSearchTap: () {},
            onSettingsTap: () {},
            onFixturesTap: () => taps++,
          ),
        ),
      );

      expect(find.text('المباريات'), findsOneWidget);
      expect(find.byIcon(Icons.sports_soccer_rounded), findsOneWidget);

      await tester.tap(find.text('المباريات'));
      expect(taps, 1, reason: 'the destination must actually invoke the callback');
    });

    testWidgets('hides it entirely when the server is unreachable', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          HomeBottomNav(
            searchEnabled: true,
            onSearchTap: () {},
            onSettingsTap: () {},
          ),
        ),
      );

      expect(find.text('المباريات'), findsNothing);
      expect(find.byIcon(Icons.sports_soccer_rounded), findsNothing);
      // The other destinations must survive the gate being shut.
      expect(find.text('الرئيسية'), findsOneWidget);
      expect(find.text('بحث'), findsOneWidget);
      expect(find.text('الإعدادات'), findsOneWidget);
    });
  });

  group('wide nav rail', () {
    testWidgets('shows the fixtures destination when the server is reachable', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        wrap(
          NavRail(
            searchEnabled: true,
            onSearchTap: () {},
            onSettingsTap: () {},
            onFixturesTap: () => taps++,
          ),
          size: const Size(1280, 720),
        ),
      );

      expect(find.text('المباريات'), findsOneWidget);
      await tester.tap(find.text('المباريات'));
      expect(taps, 1);
    });

    testWidgets('hides it entirely when the server is unreachable', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          NavRail(
            searchEnabled: true,
            onSearchTap: () {},
            onSettingsTap: () {},
          ),
          size: const Size(1280, 720),
        ),
      );

      expect(find.text('المباريات'), findsNothing);
    });
  });

  // The bar is a fixed 62dp tall and its items share one row, so a fourth
  // destination is the case most likely to overflow — check the narrowest
  // supported phone at the clamp ceiling the widget itself applies.
  group('four destinations still fit', () {
    for (final entry in const <String, Size>{
      'iPhone SE 320x568': Size(320, 568),
      'iPhone 8 375x667': Size(375, 667),
      'iPhone 15 Pro 393x852': Size(393, 852),
    }.entries) {
      for (final scale in const [1.0, 1.3, 2.0, 3.0]) {
        testWidgets('${entry.key} @${scale}x has no overflow', (tester) async {
          tester.view.physicalSize = entry.value;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          await tester.pumpWidget(
            MediaQuery(
              data: MediaQueryData(
                size: entry.value,
                textScaler: TextScaler.linear(scale),
              ),
              child: Builder(
                builder: (_) => MaterialApp(
                  theme: AppTheme.darkTheme,
                  home: Scaffold(
                    backgroundColor: AppColors.primaryDark,
                    body: Align(
                      alignment: Alignment.bottomCenter,
                      child: HomeBottomNav(
                        searchEnabled: true,
                        onSearchTap: () {},
                        onSettingsTap: () {},
                        onFixturesTap: () {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );

          expect(tester.takeException(), isNull);
          expect(find.text('المباريات'), findsOneWidget);
        });
      }
    }
  });
}
