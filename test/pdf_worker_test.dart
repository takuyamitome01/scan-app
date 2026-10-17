import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:scan_app/pdf_worker.dart';

import 'test_images.dart';

void main() {
  group('pdfRotationFor', () {
    test('turns clockwise, the way RotatedBox does on screen', () {
      // PDF's Y axis points up, so clockwise is the negative direction.
      // Getting this sign wrong saves the page 180 degrees off the preview.
      expect(pdfRotationFor(1), closeTo(-math.pi / 2, 1e-9));
      expect(pdfRotationFor(2), closeTo(-math.pi, 1e-9));
      expect(pdfRotationFor(3), closeTo(-3 * math.pi / 2, 1e-9));
    });

    test('treats no turns and a full circle alike', () {
      expect(pdfRotationFor(0), 0);
      expect(pdfRotationFor(4), 0);
    });
  });

  group('ScanPage.rotatedBy', () {
    test('accumulates turns and wraps around a full circle', () {
      const page = ScanPage(imagePath: '/tmp/a.jpg');
      expect(page.rotatedBy(1).quarterTurns, 1);
      expect(page.rotatedBy(1).rotatedBy(1).quarterTurns, 2);
      expect(
        page.rotatedBy(1).rotatedBy(1).rotatedBy(1).rotatedBy(1).quarterTurns,
        0,
      );
    });
  });

  group('buildPdfJobs', () {
    const pages = [
      ScanPage(imagePath: '/tmp/a.jpg'),
      ScanPage(imagePath: '/tmp/b.jpg', quarterTurns: 1),
      ScanPage(imagePath: '/tmp/c.jpg'),
    ];

    test('puts every page into one file when combining', () {
      final jobs = buildPdfJobs(
        pages: pages,
        directory: '/scans',
        timestamp: '20260926_101500',
        combinePages: true,
      );

      expect(jobs, hasLength(1));
      expect(jobs.single.pages, pages);
      expect(jobs.single.outputPath, '/scans/20260926_101500_3p.pdf');
    });

    test('creates one zero-padded file per page when not combining', () {
      final jobs = buildPdfJobs(
        pages: pages,
        directory: '/scans',
        timestamp: '20260926_101500',
        combinePages: false,
      );

      expect(jobs, hasLength(3));
      expect(jobs.map((job) => job.outputPath), [
        '/scans/20260926_101500_page01.pdf',
        '/scans/20260926_101500_page02.pdf',
        '/scans/20260926_101500_page03.pdf',
      ]);
      expect(jobs[1].pages.single.imagePath, '/tmp/b.jpg');
      expect(jobs[1].pages.single.quarterTurns, 1);
    });
  });

  group('writePdfsInBackground', () {
    test('writes a combined PDF and reports every page', () async {
      final dir = await Directory.systemTemp.createTemp('pdf_worker_ok');
      addTearDown(() => dir.delete(recursive: true));

      final imagePaths = await writeTestImages(dir, 3);
      final outputPath = p.join(dir.path, 'combined.pdf');
      final updates = <PdfProgress>[];

      await writePdfsInBackground(
        jobs: [
          PdfJob(
            pages: [for (final path in imagePaths) ScanPage(imagePath: path)],
            outputPath: outputPath,
          ),
        ],
        onProgress: updates.add,
      );

      final bytes = await File(outputPath).readAsBytes();
      expect(utf8.decode(bytes.sublist(0, 4)), '%PDF');

      expect(
        updates.where((u) => !u.isSaving).map((u) => u.pagesDone),
        [1, 2, 3],
      );
      expect(updates.every((u) => u.totalPages == 3), isTrue);
      expect(updates.last.isSaving, isTrue);
      expect(updates.last.ratio, 1.0);
    });

    test('writes one PDF per job', () async {
      final dir = await Directory.systemTemp.createTemp('pdf_worker_split');
      addTearDown(() => dir.delete(recursive: true));

      final imagePaths = await writeTestImages(dir, 2);
      final jobs = [
        for (var i = 0; i < imagePaths.length; i++)
          PdfJob(
            pages: [ScanPage(imagePath: imagePaths[i])],
            outputPath: p.join(dir.path, 'out$i.pdf'),
          ),
      ];

      await writePdfsInBackground(jobs: jobs, onProgress: (_) {});

      for (final job in jobs) {
        expect(File(job.outputPath).existsSync(), isTrue);
      }
    });

    test('writes every rotation without overflowing the page', () async {
      final dir = await Directory.systemTemp.createTemp('pdf_worker_rotate');
      addTearDown(() => dir.delete(recursive: true));

      final imagePaths = await writeTestImages(dir, 4);
      final outputPath = p.join(dir.path, 'rotated.pdf');

      await writePdfsInBackground(
        jobs: [
          PdfJob(
            pages: [
              for (var turns = 0; turns < 4; turns++)
                ScanPage(imagePath: imagePaths[turns], quarterTurns: turns),
            ],
            outputPath: outputPath,
          ),
        ],
        onProgress: (_) {},
      );

      final bytes = await File(outputPath).readAsBytes();
      expect(utf8.decode(bytes.sublist(0, 4)), '%PDF');
    });

    test('surfaces a worker failure as PdfGenerationException', () async {
      final dir = await Directory.systemTemp.createTemp('pdf_worker_err');
      addTearDown(() => dir.delete(recursive: true));

      await expectLater(
        writePdfsInBackground(
          jobs: [
            PdfJob(
              pages: [
                ScanPage(imagePath: p.join(dir.path, 'does_not_exist.jpg')),
              ],
              outputPath: p.join(dir.path, 'out.pdf'),
            ),
          ],
          onProgress: (_) {},
        ),
        throwsA(isA<PdfGenerationException>()),
      );
    });
  });
}
