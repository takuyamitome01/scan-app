import 'dart:io';

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

void main() {
  runApp(const ScanApp());
}

class ScanApp extends StatelessWidget {
  const ScanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '簡易スキャナー',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const ScanHomePage(),
    );
  }
}

class ScanHomePage extends StatefulWidget {
  const ScanHomePage({super.key});

  @override
  State<ScanHomePage> createState() => _ScanHomePageState();
}

class _ScanHomePageState extends State<ScanHomePage> {
  List<File> _pdfPages = [];
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    _loadSavedPages();
  }

  Future<Directory> _scansDir() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docsDir.path, 'scans'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _loadSavedPages() async {
    final dir = await _scansDir();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.pdf'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    setState(() => _pdfPages = files);
  }

  Future<void> _startScan() async {
    setState(() => _isScanning = true);
    try {
      final List<String>? imagePaths =
          await CunningDocumentScanner.getPictures(
        noOfPages: 20,
        scannerSource: ScannerSource.camera,
      );

      if (imagePaths == null || imagePaths.isEmpty) {
        setState(() => _isScanning = false);
        return;
      }

      final dir = await _scansDir();
      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());

      for (var i = 0; i < imagePaths.length; i++) {
        final pdfFile = await _imageToA4Pdf(
          imagePath: imagePaths[i],
          outputPath: p.join(
            dir.path,
            '${timestamp}_page${(i + 1).toString().padLeft(2, '0')}.pdf',
          ),
        );
        _pdfPages.insert(0, pdfFile);
      }

      await _loadSavedPages();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('スキャンに失敗しました: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  Future<File> _imageToA4Pdf({
    required String imagePath,
    required String outputPath,
  }) async {
    final imageBytes = await File(imagePath).readAsBytes();
    final pdfImage = pw.MemoryImage(imageBytes);

    final doc = pw.Document();
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.zero,
        build: (context) {
          return pw.Center(
            child: pw.Image(pdfImage, fit: pw.BoxFit.contain),
          );
        },
      ),
    );

    final outFile = File(outputPath);
    await outFile.writeAsBytes(await doc.save());
    return outFile;
  }

  Future<void> _deletePage(File file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('削除確認'),
        content: Text('「${p.basename(file.path)}」を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await file.delete();
      await _loadSavedPages();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('簡易スキャナー')),
      body: _pdfPages.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '右下の「スキャン」ボタンから\nA4の書類を撮影してPDFを作成します',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, color: Colors.grey),
                ),
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 0.72,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: _pdfPages.length,
              itemBuilder: (context, index) {
                final file = _pdfPages[index];
                return _PdfCard(
                  file: file,
                  onTap: () => OpenFilex.open(file.path),
                  onLongPress: () => _deletePage(file),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isScanning ? null : _startScan,
        icon: _isScanning
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.document_scanner),
        label: Text(_isScanning ? '処理中...' : 'スキャン'),
      ),
    );
  }
}

class _PdfCard extends StatelessWidget {
  const _PdfCard({
    required this.file,
    required this.onTap,
    required this.onLongPress,
  });

  final File file;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                color: Colors.grey.shade200,
                child: const Icon(
                  Icons.picture_as_pdf,
                  size: 48,
                  color: Colors.redAccent,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 6,
              ),
              child: Text(
                p.basename(file.path),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
