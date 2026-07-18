import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/widgets/tv_keyboard.dart';

void main() {
  testWidgets('Arabic keyboard accepts the TV select key', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TvKeyboard(
            fieldLabel: 'بحث',
            initialLanguage: TvKeyboardLanguage.arabic,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('ض'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pump();

    // One occurrence is the key and the other is the text preview.
    expect(find.text('ض'), findsNWidgets(2));
  });

  testWidgets('language toggle exposes the English layout', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TvKeyboard(
            fieldLabel: 'بحث',
            initialLanguage: TvKeyboardLanguage.arabic,
          ),
        ),
      ),
    );

    await tester.tap(find.text('English'));
    await tester.pump();

    expect(find.text('q'), findsOneWidget);
    expect(find.text('عربي'), findsOneWidget);
  });
}
