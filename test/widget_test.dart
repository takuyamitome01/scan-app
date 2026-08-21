import 'package:flutter_test/flutter_test.dart';

import 'package:scan_app/main.dart';

void main() {
  testWidgets('Home page shows empty state message', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ScanApp());

    expect(find.text('簡易スキャナー'), findsOneWidget);
    expect(find.text('スキャン'), findsOneWidget);
  });
}
