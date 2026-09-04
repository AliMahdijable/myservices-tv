import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/models/channel.dart';
import 'package:myservices_tv/theme/layout_metrics.dart';
import 'package:myservices_tv/widgets/channel_card.dart';

Channel ch(String n) => Channel(name: n, url: 'http://x/$n', group: 'باقة رياضية');

void main() {
  testWidgets('name plate content vs fixed plate height', (t) async {
    for (final entry in {
      'wide 1280x720': const Size(1280, 720),
      'phone 390x844': const Size(390, 844),
    }.entries) {
      for (final s in [1.0, 1.3, 1.5, 1.64, 1.8, 1.94, 2.35, 3.12]) {
        await t.pumpWidget(const SizedBox.shrink());
        await t.pumpWidget(MediaQuery(
          data: MediaQueryData(
              size: entry.value, textScaler: TextScaler.linear(s)),
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: Center(
              child:
                  ChannelCard(channel: ch('beIN SPORTS 1 HD'), onTap: () {}),
            ),
          ),
        ));
        final texts = find.byType(Text);
        final n = t.getSize(texts.at(0)).height;
        final g = t.getSize(texts.at(1)).height;
        final plate = entry.value.shortestSide >= 600
            ? ChannelCardMetrics.wide.plateHeight
            : ChannelCardMetrics.phone.plateHeight;
        final content = n + 2 + g;
        // Also ask the render flex whether it overflowed.
        final flex = t.renderObject<RenderFlex>(
          find.ancestor(of: texts.at(0), matching: find.byType(Column)).first,
        );
        // ignore: avoid_print
        print('${entry.key} scale=$s name=$n group=$g content='
            '${content.toStringAsFixed(2)} plate=$plate '
            'over=${(content - plate).toStringAsFixed(2)} '
            'flexSize=${flex.size.height}');
      }
    }
  });
}
