import 'dart:io';

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:shared_preferences/shared_preferences.dart';

/// Preference key for "save all scanned pages into a single PDF".
const combinePagesPrefKey = 'combine_pages';

/// Maximum number of pages kept from one scanning session.
///
/// Apple's document camera has no page limit of its own, so anything scanned
/// beyond this is silently dropped by the plugin.
const maxPagesPerScan = 300;

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
  List<File> _pdfFiles = [];
  bool _isScanning = false;
  bool _combinePages = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadSavedFiles();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _combinePages = prefs.getBool(combinePagesPrefKey) ?? true;
    });
  }

  Future<void> _setCombinePages(bool value) async {
    setState(() => _combinePages = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(combinePagesPrefKey, value);
  }

  Future<Directory> _scansDir() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docsDir.path, 'scans'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _loadSavedFiles() async {
    final dir = await _scansDir();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.pdf'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    if (!mounted) return;
    setState(() => _pdfFiles = files);
  }

  Future<void> _startScan() async {
    setState(() => _isScanning = true);
    try {
      final List<String>? imagePaths =
          await CunningDocumentScanner.getPictures(
        noOfPages: maxPagesPerScan,
        scannerSource: ScannerSource.camera,
        // JPEG pages are embedded into the PDF as-is, while PNG pages are
        // decoded to raw bitmaps first (tens of MB per page) — which a scan of
        // this many pages cannot hold in memory.
        iosScannerOptions: IosScannerOptions(
          imageFormat: IosImageFormat.jpg,
          jpgCompressionQuality: 0.8,
        ),
      );

      if (imagePaths == null || imagePaths.isEmpty) {
        return;
      }

      final dir = await _scansDir();
      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());

      if (_combinePages) {
        await _imagesToA4Pdf(
          imagePaths: imagePaths,
          outputPath: p.join(dir.path, '${timestamp}_${imagePaths.length}p.pdf'),
        );
      } else {
        for (var i = 0; i < imagePaths.length; i++) {
          await _imagesToA4Pdf(
            imagePaths: [imagePaths[i]],
            outputPath: p.join(
              dir.path,
              '${timestamp}_page${(i + 1).toString().padLeft(2, '0')}.pdf',
            ),
          );
        }
      }

      await _loadSavedFiles();

      if (mounted) {
        final message = _combinePages
            ? '${imagePaths.length}ページを1つのPDFに保存しました'
            : '${imagePaths.length}個のPDFを保存しました';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
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

  /// Writes every image in [imagePaths] as one A4 page of a single PDF.
  Future<File> _imagesToA4Pdf({
    required List<String> imagePaths,
    required String outputPath,
  }) async {
    final doc = pw.Document();

    for (final imagePath in imagePaths) {
      final imageBytes = await File(imagePath).readAsBytes();
      final pdfImage = pw.MemoryImage(imageBytes);
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
    }

    final outFile = File(outputPath);
    await outFile.writeAsBytes(await doc.save());
    return outFile;
  }

  Future<void> _deleteFile(File file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('削除確認'),
        content: Text('「${describeScanFile(file.path)}」を削除しますか？'),
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
      await _loadSavedFiles();
    }
  }

  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
                    child: Text(
                      '設定',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('まとめて1つのPDFにする'),
                    subtitle: Text(
                      _combinePages
                          ? '複数ページを1つのPDFファイルに保存します'
                          : '1ページごとに別々のPDFファイルに保存します',
                    ),
                    value: _combinePages,
                    onChanged: (value) {
                      // Updates _combinePages synchronously, then repaints
                      // the sheet, which lives in its own route subtree.
                      _setCombinePages(value);
                      setSheetState(() {});
                    },
                  ),
                  const Divider(height: 24),
                  const ListTile(
                    leading: Icon(Icons.filter_none),
                    title: Text('1回のスキャンの上限'),
                    subtitle: Text(
                      '連続で最大$maxPagesPerScanページまで撮影できます。',
                    ),
                  ),
                  const ListTile(
                    leading: Icon(Icons.info_outline),
                    title: Text('撮影タイミング（自動 / 手動）'),
                    subtitle: Text(
                      'カメラ画面の右上にある「自動」「手動」ボタンで切り替えられます。'
                      '自動では書類を認識すると自動でシャッターが切られ、'
                      '手動ではシャッターボタンを押したタイミングで撮影します。',
                    ),
                    isThreeLine: true,
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('簡易スキャナー'),
        actions: [
          IconButton(
            onPressed: _openSettings,
            icon: const Icon(Icons.settings),
            tooltip: '設定',
          ),
        ],
      ),
      body: _pdfFiles.isEmpty
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
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 0.72,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: _pdfFiles.length,
              itemBuilder: (context, index) {
                final file = _pdfFiles[index];
                return _PdfCard(
                  file: file,
                  onTap: () => OpenFilex.open(file.path),
                  onLongPress: () => _deleteFile(file),
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

/// Turns a saved scan's file name into a readable label,
/// e.g. `20260917_203000_3p.pdf` -> `9/17 20:30・3ページ`.
String describeScanFile(String path) {
  final base = p.basenameWithoutExtension(path);
  final match = RegExp(r'^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})\d{2}_(.+)$')
      .firstMatch(base);
  if (match == null) return p.basename(path);

  final when = '${int.parse(match[2]!)}/${int.parse(match[3]!)} '
      '${match[4]}:${match[5]}';
  final suffix = match[6]!;

  final combined = RegExp(r'^(\d+)p$').firstMatch(suffix);
  if (combined != null) return '$when・${combined[1]}ページ';

  final single = RegExp(r'^page(\d+)$').firstMatch(suffix);
  if (single != null) return '$when・${int.parse(single[1]!)}ページ目';

  return when;
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
                vertical: 8,
              ),
              child: Text(
                describeScanFile(file.path),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
