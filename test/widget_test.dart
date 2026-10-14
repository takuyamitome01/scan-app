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

    test('shows a user-chosen name as it is', () {
      expect(describeScanFile('/scans/契約書.pdf'), '契約書');
    });
  });

  group('validateScanName', () {
    test('accepts an ordinary name', () {
      expect(validateScanName('契約書 2026'), isNull);
    });

    test('trims before deciding a name is empty', () {
      expect(validateScanName('   '), isNotNull);
    });

    test('rejects characters that are not allowed in a file name', () {
      for (final name in [r'a/b', r'a\b', 'a:b', 'a*b', 'a?b', 'a"b', 'a|b']) {
        expect(validateScanName(name), isNotNull, reason: name);
      }
    });

    test('rejects a leading dot, which would hide the file', () {
      expect(validateScanName('.hidden'), isNotNull);
    });

    test('rejects a name that is too long', () {
      expect(validateScanName('あ' * 101), isNotNull);
      expect(validateScanName('あ' * 100), isNull);
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
