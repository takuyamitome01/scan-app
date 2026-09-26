import 'dart:io';
import 'dart:isolate';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// One PDF to produce: every image in [imagePaths] becomes one A4 page of the
/// file written to [outputPath].
class PdfJob {
  const PdfJob({required this.imagePaths, required this.outputPath});

  final List<String> imagePaths;
  final String outputPath;
}

/// A progress update from the background PDF worker.
class PdfProgress {
  const PdfProgress({
    required this.pagesDone,
    required this.totalPages,
    required this.isSaving,
  });

  /// Pages laid out so far, across every job.
  final int pagesDone;

  /// Pages to lay out in total, across every job.
  final int totalPages;

  /// Whether the worker has moved on to encoding and writing a file, a step
  /// whose progress cannot be measured.
  final bool isSaving;

  /// Share of the pages laid out so far, from 0.0 to 1.0.
  double get ratio => totalPages == 0 ? 0 : pagesDone / totalPages;
}

/// Raised when the background PDF worker fails or stops before finishing.
class PdfGenerationException implements Exception {
  const PdfGenerationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Runs [jobs] on a background isolate so the UI keeps rendering while a long
/// document is encoded, reporting each step through [onProgress].
///
/// Throws a [PdfGenerationException] if the worker fails or exits early.
Future<void> writePdfsInBackground({
  required List<PdfJob> jobs,
  required void Function(PdfProgress progress) onProgress,
}) async {
  final receivePort = ReceivePort();
  final isolate = await Isolate.spawn(
    _pdfWorkerEntry,
    _PdfWorkerRequest(jobs, receivePort.sendPort),
    // Without these an isolate that dies outright would leave the loop below
    // waiting on a port that never receives anything again.
    onError: receivePort.sendPort,
    onExit: receivePort.sendPort,
  );

  var finished = false;
  try {
    await for (final message in receivePort) {
      if (message is PdfProgress) {
        onProgress(message);
      } else if (message == _workerSuccess) {
        finished = true;
        break;
      } else if (message is String) {
        throw PdfGenerationException(message);
      } else if (message is List) {
        // onError delivers [error, stackTrace], both already stringified.
        throw PdfGenerationException('${message.first}');
      } else {
        // onExit delivers null: the isolate stopped without reporting success.
        break;
      }
    }
  } finally {
    receivePort.close();
    isolate.kill(priority: Isolate.immediate);
  }

  if (!finished) {
    throw const PdfGenerationException('PDFの作成が中断されました');
  }
}

/// Builds the PDF jobs for one scanning session.
///
/// With [combinePages] every scanned page goes into a single file, otherwise
/// each page becomes a file of its own.
List<PdfJob> buildPdfJobs({
  required List<String> imagePaths,
  required String directory,
  required String timestamp,
  required bool combinePages,
}) {
  if (combinePages) {
    return [
      PdfJob(
        imagePaths: imagePaths,
        outputPath: '$directory/${timestamp}_${imagePaths.length}p.pdf',
      ),
    ];
  }

  return [
    for (var i = 0; i < imagePaths.length; i++)
      PdfJob(
        imagePaths: [imagePaths[i]],
        outputPath: '$directory/${timestamp}_page'
            '${(i + 1).toString().padLeft(2, '0')}.pdf',
      ),
  ];
}

/// Sentinel the worker sends once every job has been written.
const _workerSuccess = true;

class _PdfWorkerRequest {
  const _PdfWorkerRequest(this.jobs, this.sendPort);

  final List<PdfJob> jobs;
  final SendPort sendPort;
}

/// Isolate entry point. Lays out and writes every requested PDF.
Future<void> _pdfWorkerEntry(_PdfWorkerRequest request) async {
  final sendPort = request.sendPort;
  try {
    final totalPages = request.jobs
        .fold<int>(0, (sum, job) => sum + job.imagePaths.length);
    var pagesDone = 0;

    for (final job in request.jobs) {
      final doc = pw.Document();

      for (final imagePath in job.imagePaths) {
        final image = pw.MemoryImage(await File(imagePath).readAsBytes());
        doc.addPage(
          pw.Page(
            pageFormat: PdfPageFormat.a4,
            margin: pw.EdgeInsets.zero,
            build: (context) => pw.Center(
              child: pw.Image(image, fit: pw.BoxFit.contain),
            ),
          ),
        );
        pagesDone++;
        sendPort.send(
          PdfProgress(
            pagesDone: pagesDone,
            totalPages: totalPages,
            isSaving: false,
          ),
        );
      }

      sendPort.send(
        PdfProgress(
          pagesDone: pagesDone,
          totalPages: totalPages,
          isSaving: true,
        ),
      );
      await File(job.outputPath).writeAsBytes(await doc.save());
    }

    sendPort.send(_workerSuccess);
  } catch (error) {
    sendPort.send('$error');
  }
}
