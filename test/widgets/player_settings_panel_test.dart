import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/widgets/player_settings_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hosts the panel the way the player does — inside a Stack, underneath a
/// full-screen GestureDetector that toggles the OSD. That outer detector is
/// what used to swallow every tap aimed at the panel.
Widget host({
  required void Function(int row, int option) onSelect,
  required VoidCallback onBackgroundTap,
  int focusedRow = 0,
}) {
  return MaterialApp(
    home: Scaffold(
      body: GestureDetector(
        onTap: onBackgroundTap,
        child: Stack(
          children: [
            // Stands in for the video layer: the player's Stack always has a
            // hit-testable child underneath, which is what makes the outer
            // gesture detector fire on the video area.
            const ColoredBox(color: Colors.black, child: SizedBox.expand()),
            PlayerSettingsPanel(
              rows: PlayerSettingsPanel.rowsFor(aspectMode: 0),
              focusedRow: focusedRow,
              onSelect: onSelect,
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('tapping an option chip reports its row and index', (
    tester,
  ) async {
    // The regression this guards: the panel shipped D-pad-only, so on iOS and
    // on Android phones — where there is no remote — the decoder and buffer
    // controls could not be operated at all.
    final selections = <List<int>>[];
    await tester.pumpWidget(
      host(
        onSelect: (row, option) => selections.add([row, option]),
        onBackgroundTap: () => fail('the panel must swallow its own taps'),
      ),
    );

    await tester.tap(find.text('برمجي'));
    await tester.pump();

    expect(selections, [
      [0, 2],
    ], reason: 'decoder row, software option');
  });

  testWidgets('each row reports its own index', (tester) async {
    final selections = <List<int>>[];
    await tester.pumpWidget(
      host(
        onSelect: (row, option) => selections.add([row, option]),
        onBackgroundTap: () {},
      ),
    );

    await tester.tap(find.text('مستقر'));
    await tester.pump();
    await tester.tap(find.text('ملء'));
    await tester.pump();

    expect(selections, [
      [1, 2],
      [2, 1],
    ]);
  });

  testWidgets('a tap on the panel background does not reach the OSD toggle', (
    tester,
  ) async {
    var backgroundTaps = 0;
    await tester.pumpWidget(
      host(onSelect: (_, __) {}, onBackgroundTap: () => backgroundTaps++),
    );

    // The panel header is inert chrome — tapping it must still not dismiss
    // the panel by falling through to the player's OSD gesture.
    await tester.tap(find.text('إعدادات التشغيل'));
    await tester.pump();

    expect(backgroundTaps, 0);
  });

  testWidgets('a tap outside the panel still reaches the OSD toggle', (
    tester,
  ) async {
    var backgroundTaps = 0;
    await tester.pumpWidget(
      host(onSelect: (_, __) {}, onBackgroundTap: () => backgroundTaps++),
    );

    // The panel is pinned to the right; the far left is the video area, where
    // a tap must keep its normal meaning.
    await tester.tapAt(const Offset(40, 300));
    await tester.pump();

    expect(backgroundTaps, 1);
  });

  testWidgets('the focused row is the one the D-pad highlights', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(onSelect: (_, __) {}, onBackgroundTap: () {}, focusedRow: 1),
    );

    expect(find.text('التخزين المؤقت'), findsOneWidget);
    expect(find.text('فك الترميز'), findsOneWidget);
    expect(find.text('نسبة العرض'), findsOneWidget);
  });
}
