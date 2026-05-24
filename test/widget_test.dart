import 'package:flutter_test/flutter_test.dart';
import 'package:myservices_tv/main.dart';

void main() {
  testWidgets('App launches correctly', (WidgetTester tester) async {
    await tester.pumpWidget(const MyServicesTV());
    expect(find.text('MyServices TV'), findsOneWidget);
  });
}
