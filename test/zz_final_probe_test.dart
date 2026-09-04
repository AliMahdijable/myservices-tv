import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/models/channel.dart';
import 'package:myservices_tv/screens/home_screen.dart';
import 'package:myservices_tv/theme/app_theme.dart';
import 'package:myservices_tv/theme/layout_metrics.dart';
import 'package:myservices_tv/widgets/channel_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('playing chip vs favourite badge at large scale', (t) async {
    for (final s in [1.0, 1.6, 2.35, 3.12]) {
      await t.pumpWidget(const SizedBox.shrink());
      await t.pumpWidget(MediaQuery(
        data: MediaQueryData(
            size: const Size(390, 844), textScaler: TextScaler.linear(s)),
        child: Directionality(
          textDirection: TextDirection.rtl,
          child: Center(
            child: ChannelCard(
              channel: Channel(
                  name: 'beIN 1', url: 'u', group: 'رياضة'),
              onTap: () {},
              isPlaying: true,
              isFavorite: true,
            ),
          ),
        ),
      ));
      final chip = find.text('يُعرض');
      final heart = find.byIcon(Icons.favorite_rounded);
      final card = find.byType(ChannelCard);
      // ignore: avoid_print
      print('CHIP scale=$s cardW=${t.getSize(card).width} '
          'chipTextRight=${t.getTopRight(chip).dx.toStringAsFixed(1)} '
          'chipTextLeft=${t.getTopLeft(chip).dx.toStringAsFixed(1)} '
          'cardLeft=${t.getTopLeft(card).dx.toStringAsFixed(1)} '
          'heartLeft=${t.getTopLeft(heart).dx.toStringAsFixed(1)} '
          'heartRight=${t.getTopRight(heart).dx.toStringAsFixed(1)}');
    }
  });

  testWidgets('horizontal flush alignment at rail end', (t) async {
    SharedPreferences.setMockInitialValues({});
    const size = Size(1024, 768);
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: size),
      child: MaterialApp(
        theme: AppTheme.darkTheme,
        home: HomeScreen(preloadedCategories: [
          ChannelCategory(
            name: 'A',
            displayName: 'باقة',
            channels: List.generate(
                12,
                (i) => Channel(
                    name: 'قناة $i',
                    url: 'http://x/$i',
                    group: 'رياضة',
                    streamId: i)),
            sortOrder: 0,
          ),
        ]),
      ),
    ));
    await t.pump(const Duration(milliseconds: 600));
    final outer = find.byType(Scrollable).first;
    final rail = find.byType(Scrollable).at(1);
    for (var i = 0; i < 8; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
    }
    final ctx = FocusManager.instance.primaryFocus?.context;
    final w = ctx?.findAncestorWidgetOfExactType<ChannelCard>();
    if (w == null) {
      // ignore: avoid_print
      print('RAIL no card focused');
      return;
    }
    final f = find.byWidget(w);
    final m = ChannelCardMetrics.of(t.element(find.byType(ChannelCard).first));
    final grow = m.width * (ChannelCardMetrics.focusScale - 1) / 2;
    // ignore: avoid_print
    print('RAIL cardBoxRight=${t.getBottomRight(f).dx.toStringAsFixed(1)} '
        'railViewportRight=${t.getBottomRight(rail).dx.toStringAsFixed(1)} '
        'outerViewportRight=${t.getBottomRight(outer).dx.toStringAsFixed(1)} '
        'visibleCardRight=${(t.getBottomRight(f).dx - m.gutter + grow).toStringAsFixed(1)} '
        'growHalf=$grow');
  });
}
