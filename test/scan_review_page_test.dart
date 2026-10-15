import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scan_app/pdf_worker.dart';
import 'package:scan_app/scan_review_page.dart';

import 'test_images.dart';

void main() {
  late Directory dir;
  late List<String> imagePaths;
  late List<String> extraPaths;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('scan_review');
    imagePaths = await writeTestImages(dir, 3);
    extraPaths = await writeTestImages(dir, 2, prefix: 'extra');
  });

  tearDown(() async => dir.delete(recursive: true));

  /// Shows the review page, returning a getter for whatever it pops.
  Future<List<ScanPage>? Function()> showReview(
    WidgetTester tester, {
    List<String>? paths,
    Future<List<String>> Function()? onAddPages,
  }) async {
    List<ScanPage>? popped;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              popped = await Navigator.of(context).push<List<ScanPage>>(
                MaterialPageRoute(
                  builder: (_) => ScanReviewPage(
                    initialPages: [
                      for (final path in paths ?? imagePaths)
                        ScanPage(imagePath: path),
                    ],
                    onAddPages: onAddPages ?? () async => const [],
                    maxPages: 300,
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    return () => popped;
  }

  testWidgets('lists every scanned page', (tester) async {
    await showReview(tester);

    expect(find.text('ページの確認'), findsOneWidget);
    expect(find.byTooltip('回転'), findsNWidgets(3));
    expect(find.text('3 / 300 ページ'), findsOneWidget);
  });

  testWidgets('deleting a page drops it from the list and the result',
      (tester) async {
    final result = await showReview(tester);

    await tester.tap(find.byTooltip('削除').first);
    await tester.pumpAndSettle();

    expect(find.byTooltip('回転'), findsNWidgets(2));
    expect(find.text('2 / 300 ページ'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(
      result()!.map((page) => page.imagePath),
      [imagePaths[1], imagePaths[2]],
    );
  });

  testWidgets('rotating a page is carried into the result', (tester) async {
    final result = await showReview(tester, paths: [imagePaths.first]);

    await tester.tap(find.byTooltip('回転'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('回転'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(result()!.single.quarterTurns, 2);
  });

  testWidgets('adding pages appends what the scanner returned',
      (tester) async {
    await showReview(tester, onAddPages: () async => extraPaths);

    await tester.tap(find.text('ページを追加'));
    await tester.pumpAndSettle();

    expect(find.text('5 / 300 ページ'), findsOneWidget);
    expect(find.byTooltip('回転'), findsNWidgets(5));
  });

  testWidgets('save is unavailable once every page is deleted',
      (tester) async {
    await showReview(tester, paths: [imagePaths.first]);

    await tester.tap(find.byTooltip('削除'));
    await tester.pumpAndSettle();

    final save = tester.widget<TextButton>(
      find.ancestor(of: find.text('保存'), matching: find.byType(TextButton)),
    );
    expect(save.onPressed, isNull);
    expect(find.textContaining('ページがありません'), findsOneWidget);
  });
}
