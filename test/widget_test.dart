import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/main.dart';
import 'package:myservices_tv/screens/splash_screen.dart';

void main() {
  testWidgets('App launches into the splash screen', (tester) async {
    await tester.pumpWidget(const MyServicesTV());

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(SplashScreen), findsOneWidget);
  });
}
