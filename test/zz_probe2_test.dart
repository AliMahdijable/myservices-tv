import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('bare text scaling', (t) async {
    for (final s in [1.0, 1.64, 1.8, 2.35, 3.12]) {
      await t.pumpWidget(const SizedBox.shrink());
      await t.pumpWidget(MediaQuery(
        data: MediaQueryData(
            size: const Size(1280, 720), textScaler: TextScaler.linear(s)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 176,
              height: 68,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text('beIN SPORTS 1 HD',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 15, height: 1.25)),
                  SizedBox(height: 2),
                  Text('sports',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ),
        ),
      ));
      final texts = find.byType(Text);
      // ignore: avoid_print
      print('scale=$s a=${t.getSize(texts.at(0)).height} '
          'b=${t.getSize(texts.at(1)).height}');
    }
  });
}
