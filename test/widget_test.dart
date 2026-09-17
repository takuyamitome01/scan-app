import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:scan_app/main.dart';

void main() {
  group('describeScanFile', () {
    test('formats a combined multi-page scan', () {
      expect(
        describeScanFile('/scans/20260917_203015_3p.pdf'),
        '9/17 20:30・3ページ',
      );
    });

    test('formats a single-page-per-file scan', () {
      expect(
        describeScanFile('/scans/20260917_203015_page02.pdf'),
        '9/17 20:30・2ページ目',
      );
    });

    test('formats a combined scan of exactly one page', () {
      expect(
        describeScanFile('/scans/20261203_090500_1p.pdf'),
        '12/3 09:05・1ページ',
      );
    });

    test('falls back to the file name when the pattern does not match', () {
      expect(describeScanFile('/scans/notes.pdf'), 'notes.pdf');
    });
  });

  testWidgets('Home page shows the title and the scan button', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const ScanApp());

    expect(find.text('簡易スキャナー'), findsOneWidget);
    expect(find.text('スキャン'), findsOneWidget);
  });
}
