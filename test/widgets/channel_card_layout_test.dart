import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/models/channel.dart';
import 'package:myservices_tv/theme/layout_metrics.dart';
import 'package:myservices_tv/widgets/channel_card.dart';

Channel channel(String name) =>
    Channel(name: name, url: 'http://host/$name', group: 'باقة رياضية عربية');

/// Renders one card and returns the first layout error it raised, or null.
Future<String?> pumpCard(
  WidgetTester tester, {
  required Size size,
  required double textScale,
}) async {
  final errors = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (details) => errors.add(details.exceptionAsString());

  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: size,
        textScaler: TextScaler.linear(textScale),
      ),
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Center(
          child: ChannelCard(
            channel: channel('beIN SPORTS 1 HD'),
            onTap: () {},
          ),
        ),
      ),
    ),
  );

  FlutterError.onError = previous;
  return errors.isEmpty ? null : errors.first.split('\n').first;
}

void main() {
  const tv = Size(1280, 720);
  const phone = Size(390, 844);

  group('the card survives every system text scale', () {
    // The rail is a lazy list with a fixed itemExtent, so a tile cannot grow to
    // fit larger text: without a clamp the name plate overflowed at scales a
    // real user can set in accessibility settings, painting a striped overflow
    // bar across the bottom of the card.
    for (final scale in const [1.0, 1.3, 1.6, 2.0, 2.35, 3.0]) {
      testWidgets('no overflow at ${scale}x on a TV', (tester) async {
        expect(await pumpCard(tester, size: tv, textScale: scale), isNull);
      });

      testWidgets('no overflow at ${scale}x on a phone', (tester) async {
        expect(await pumpCard(tester, size: phone, textScale: scale), isNull);
      });
    }
  });

  group('rail metrics stay self-consistent', () {
    for (final metrics in const [
      ChannelCardMetrics.wide,
      ChannelCardMetrics.phone,
    ]) {
      test('itemExtent matches the card footprint (${metrics.width}px)', () {
        expect(metrics.itemExtent, metrics.width + metrics.gutter * 2);
      });

      test('the focus scale fits inside the gutter (${metrics.width}px)', () {
        // A focused card grows about its centre, so it may claim at most half
        // the gap on each side before it overlaps its neighbour.
        final horizontalGrowth =
            metrics.width * (ChannelCardMetrics.focusScale - 1) / 2;
        expect(horizontalGrowth, lessThan(metrics.gutter * 2));
      });

      test('the rail reserves room above and below (${metrics.width}px)', () {
        final verticalGrowth =
            metrics.height * (ChannelCardMetrics.focusScale - 1) / 2;
        // Upward is the tight side: growth plus the lift, and going over means
        // the focused card climbs onto the section header.
        expect(
          metrics.railVerticalPadding,
          greaterThan(verticalGrowth + ChannelCardMetrics.focusLift),
        );
        expect(
          metrics.railHeight,
          metrics.height + metrics.railVerticalPadding * 2,
        );
      });
    }

    test('the wide card is meaningfully larger than the phone card', () {
      expect(
        ChannelCardMetrics.wide.width,
        greaterThan(ChannelCardMetrics.phone.width),
      );
      expect(
        ChannelCardMetrics.wide.height,
        greaterThan(ChannelCardMetrics.phone.height),
      );
    });
  });
}
