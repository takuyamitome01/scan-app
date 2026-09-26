import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:scan_app/pdf_worker.dart';

/// A 16x22 white JPEG, small enough to inline but a real image the PDF
/// writer can embed.
const _tinyJpegBase64 =
    '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoM'
    'DAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsN'
    'FBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAAR'
    'CAAWABADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAA'
    'AgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkK'
    'FhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWG'
    'h4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl'
    '5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREA'
    'AgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYk'
    'NOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOE'
    'hYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk'
    '5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD9U6KKKACiiigD/9k=';

Future<List<String>> _writeTestImages(Directory dir, int count) async {
  final bytes = base64Decode(_tinyJpegBase64);
  final paths = <String>[];
  for (var i = 0; i < count; i++) {
    final file = File(p.join(dir.path, 'page$i.jpg'));
    await file.writeAsBytes(bytes);
    paths.add(file.path);
  }
  return paths;
}

void main() {
  group('buildPdfJobs', () {
    const imagePaths = ['/tmp/a.jpg', '/tmp/b.jpg', '/tmp/c.jpg'];

    test('puts every page into one file when combining', () {
      final jobs = buildPdfJobs(
        imagePaths: imagePaths,
        directory: '/scans',
        timestamp: '20260926_101500',
        combinePages: true,
      );

      expect(jobs, hasLength(1));
      expect(jobs.single.imagePaths, imagePaths);
      expect(jobs.single.outputPath, '/scans/20260926_101500_3p.pdf');
    });

    test('creates one zero-padded file per page when not combining', () {
      final jobs = buildPdfJobs(
        imagePaths: imagePaths,
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
      expect(jobs[1].imagePaths, ['/tmp/b.jpg']);
    });
  });

  group('writePdfsInBackground', () {
    test('writes a combined PDF and reports every page', () async {
      final dir = await Directory.systemTemp.createTemp('pdf_worker_ok');
      addTearDown(() => dir.delete(recursive: true));

      final imagePaths = await _writeTestImages(dir, 3);
      final outputPath = p.join(dir.path, 'combined.pdf');
      final updates = <PdfProgress>[];

      await writePdfsInBackground(
        jobs: [PdfJob(imagePaths: imagePaths, outputPath: outputPath)],
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

      final imagePaths = await _writeTestImages(dir, 2);
      final jobs = [
        for (var i = 0; i < imagePaths.length; i++)
          PdfJob(
            imagePaths: [imagePaths[i]],
            outputPath: p.join(dir.path, 'out$i.pdf'),
          ),
      ];

      await writePdfsInBackground(jobs: jobs, onProgress: (_) {});

      for (final job in jobs) {
        expect(File(job.outputPath).existsSync(), isTrue);
      }
    });

    test('surfaces a worker failure as PdfGenerationException', () async {
      final dir = await Directory.systemTemp.createTemp('pdf_worker_err');
      addTearDown(() => dir.delete(recursive: true));

      await expectLater(
        writePdfsInBackground(
          jobs: [
            PdfJob(
              imagePaths: [p.join(dir.path, 'does_not_exist.jpg')],
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
