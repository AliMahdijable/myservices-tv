import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/screens/matches_screen.dart';
import 'package:myservices_tv/theme/app_theme.dart';

/// The day strip and the league filter are fixed-height boxes holding Arabic
/// text, so neither can absorb a larger system font on its own.
///
/// The day chips were pinned to 58dp wide, which left the label 28dp between
/// the padding and the border — narrower than 'جمعة' at the *default* text
/// size, so the word wrapped and burst the strip. The league pills were worse:
/// a Text that does not fit its box clips instead of reporting an overflow, so
/// the names lost their lower half in silence, with nothing in the logs.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required Size size,
    required double scale,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
          ),
          child: const Scaffold(
            backgroundColor: AppColors.primaryDark,
            body: MatchesScreen(embedded: true),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  const sizes = <String, Size>{
    'iPhone SE 320x568': Size(320, 568),
    'iPhone 15 393x852': Size(393, 852),
    'iPhone Max 430x932': Size(430, 932),
  };

  group('no overflow at any supported text scale', () {
    for (final entry in sizes.entries) {
      for (final scale in const [1.0, 1.3, 1.5, 2.0, 3.0]) {
        testWidgets('${entry.key} @${scale}x', (tester) async {
          await pump(tester, size: entry.value, scale: scale);
          expect(
            tester.takeException(),
            isNull,
            reason: 'a strip overflowed at ${entry.key} scale $scale',
          );
        });
      }
    }
  });

  group('league names are drawn, not clipped', () {
    // A clipped Text raises nothing, so the only way to catch it is to compare
    // the box it was given against the height the line actually needs.
    for (final scale in const [1.0, 1.3, 1.5, 2.0, 3.0]) {
      testWidgets('every visible label fits its box @${scale}x', (
        tester,
      ) async {
        await pump(tester, size: const Size(320, 568), scale: scale);

        final texts = find.byType(Text);
        var checked = 0;
        for (final element in texts.evaluate()) {
          final render = element.renderObject;
          if (render is! RenderBox || !render.hasSize) continue;
          if (render.size.height == 0) continue;
          final needed = render.getMaxIntrinsicHeight(render.size.width);
          expect(
            render.size.height + 0.5,
            greaterThanOrEqualTo(needed),
            reason:
                'a label was given ${render.size.height}dp for a line needing '
                '${needed}dp at scale $scale — it is being silently clipped',
          );
          checked++;
        }
        expect(checked, greaterThan(0), reason: 'nothing was measured');
      });
    }
  });
}
