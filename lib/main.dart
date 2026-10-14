import 'dart:io';

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pdf_worker.dart';

/// Preference key for "save all scanned pages into a single PDF".
const combinePagesPrefKey = 'combine_pages';

/// Maximum number of pages collected for one document, across every camera
/// session it takes to capture them.
const maxPagesPerScan = 300;

/// Pages Apple's document camera accepts before it stops taking more.
///
/// VisionKit enforces this itself and exposes no way to raise it, so a longer
/// document is captured by reopening the camera and appending to what is
/// already collected.
const visionKitPageLimit = 24;

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
  PdfProgress? _progress;

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
    // Ordered by when the scan was made rather than by name, so renaming a
    // file does not move it. Renaming leaves the timestamp untouched.
    final entries = [
      for (final file in dir.listSync().whereType<File>())
        if (file.path.toLowerCase().endsWith('.pdf'))
          (file: file, modified: file.statSync().modified),
    ]..sort((a, b) => b.modified.compareTo(a.modified));

    if (!mounted) return;
    setState(() => _pdfFiles = [for (final entry in entries) entry.file]);
  }

  Future<void> _startScan() async {
    setState(() => _isScanning = true);
    try {
      final imagePaths = await _collectPages();
      if (imagePaths.isEmpty) {
        return;
      }

      final dir = await _scansDir();
      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());

      await writePdfsInBackground(
        jobs: buildPdfJobs(
          imagePaths: imagePaths,
          directory: dir.path,
          timestamp: timestamp,
          combinePages: _combinePages,
        ),
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );

      await _loadSavedFiles();

      if (mounted) {
        final message = _combinePages
            ? '${imagePaths.length}ページを1つのPDFに保存しました'
            : '${imagePaths.length}個のPDFを保存しました';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } on PdfGenerationException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDFの作成に失敗しました: $e')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('スキャンに失敗しました: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isScanning = false;
          _progress = null;
        });
      }
    }
  }

  /// Collects the pages of one document, reopening the camera as needed.
  ///
  /// Apple's scanner stops at [visionKitPageLimit] pages, so a session that
  /// comes back full is taken as a document that may have more to it, and the
  /// user is offered another round.
  Future<List<String>> _collectPages() async {
    final collected = <String>[];

    while (collected.length < maxPagesPerScan) {
      final imagePaths = await CunningDocumentScanner.getPictures(
        noOfPages: maxPagesPerScan - collected.length,
        scannerSource: ScannerSource.camera,
        // JPEG pages are embedded into the PDF as-is, while PNG pages are
        // decoded to raw bitmaps first (tens of MB per page) — which a scan of
        // this many pages cannot hold in memory.
        iosScannerOptions: IosScannerOptions(
          imageFormat: IosImageFormat.jpg,
          jpgCompressionQuality: 0.8,
        ),
      );

      // Null means the user backed out of the camera. Anything already
      // collected is still worth saving.
      if (imagePaths == null || imagePaths.isEmpty) break;

      collected.addAll(imagePaths);

      if (imagePaths.length < visionKitPageLimit) break;
      if (collected.length >= maxPagesPerScan) break;
      if (!mounted) break;
      if (!await _askToContinueScanning(collected.length)) break;
    }

    return collected;
  }

  /// Asks whether to reopen the camera and append more pages to this document.
  Future<bool> _askToContinueScanning(int pagesSoFar) async {
    final answer = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('続けてスキャンしますか？'),
        content: Text(
          '$pagesSoFarページ読み込みました。\n\n'
          'iOSのスキャナーは一度に$visionKitPageLimitページまでのため、'
          '続きがある場合はもう一度カメラを開いて読み込みます。'
          '読み込んだページは1つのPDFにまとまります。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('ここまでで保存'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('続けてスキャン'),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  /// Offers what can be done with a saved scan.
  void _showFileActions(File file) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  describeScanFile(file.path),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: const Text('開く'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  OpenFilex.open(file.path);
                },
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline),
                title: const Text('名前を変更'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _renameFile(file);
                },
              ),
              ListTile(
                leading: const Icon(Icons.ios_share),
                title: const Text('共有'),
                subtitle: const Text('メール、AirDrop、ファイルへの保存など'),
                onTap: () {
                  // The anchor has to be measured before the sheet goes away,
                  // because iPad shows the share sheet as a popover from it.
                  final origin = _shareOriginOf(sheetContext);
                  Navigator.pop(sheetContext);
                  _shareFile(file, origin);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  '削除',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _deleteFile(file);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// The rectangle an iPad popover should point at, if it can be measured.
  Rect? _shareOriginOf(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Future<void> _renameFile(File file) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => _RenameDialog(
        initialName: p.basenameWithoutExtension(file.path),
      ),
    );
    if (newName == null) return;

    final target = p.join(p.dirname(file.path), '$newName.pdf');
    if (target == file.path) return;

    if (File(target).existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('同じ名前のファイルがすでにあります')),
        );
      }
      return;
    }

    try {
      await file.rename(target);
      await _loadSavedFiles();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('名前の変更に失敗しました: $e')),
        );
      }
    }
  }

  Future<void> _shareFile(File file, Rect? origin) async {
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/pdf')],
          subject: describeScanFile(file.path),
          sharePositionOrigin: origin,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('共有に失敗しました: $e')),
        );
      }
    }
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
                    title: Text('ページ数の上限'),
                    subtitle: Text(
                      'iOSのスキャナーは一度に$visionKitPageLimitページまでのため、'
                      'それを超えるときは「続けてスキャン」で読み込みます。'
                      '1つのPDFにまとめられるのは合計$maxPagesPerScanページまでです。',
                    ),
                    isThreeLine: true,
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
      body: Column(
        children: [
          if (_progress != null) _ProgressBanner(progress: _progress!),
          Expanded(
            child: _pdfFiles.isEmpty
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
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
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
                        onLongPress: () => _showFileActions(file),
                      );
                    },
                  ),
          ),
        ],
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

/// Shows how far the background PDF worker has got.
class _ProgressBanner extends StatelessWidget {
  const _ProgressBanner({required this.progress});

  final PdfProgress progress;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              progress.isSaving
                  ? 'PDFを書き出し中...'
                  : '${progress.pagesDone} / ${progress.totalPages} ページを処理中...',
              style: TextStyle(color: colors.onSecondaryContainer),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              // Writing the file reports no progress of its own, so the bar
              // keeps moving rather than sitting at a misleading 100%.
              value: progress.isSaving ? null : progress.ratio,
            ),
          ],
        ),
      ),
    );
  }
}

/// Rejects a name that cannot be used as a file name, returning the reason to
/// show the user, or null when the name is fine.
String? validateScanName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '名前を入力してください';
  if (trimmed.contains(RegExp(r'[/\\:*?"<>|]'))) {
    return r'/ \ : * ? " < > | は使えません';
  }
  if (trimmed.startsWith('.')) return '先頭に「.」は使えません';
  if (trimmed.length > 100) return '100文字以内にしてください';
  return null;
}

/// Asks for a new name for a saved scan, returning it without the extension.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialName);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final error = validateScanName(_controller.text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, _controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('名前を変更'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        decoration: InputDecoration(
          labelText: 'ファイル名',
          suffixText: '.pdf',
          errorText: _error,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('変更'),
        ),
      ],
    );
  }
}

/// Turns a saved scan's file name into a readable label,
/// e.g. `20260917_203000_3p.pdf` -> `9/17 20:30・3ページ`.
///
/// A name the user chose themselves does not match that shape and is shown
/// as it is.
String describeScanFile(String path) {
  final base = p.basenameWithoutExtension(path);
  final match = RegExp(r'^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})\d{2}_(.+)$')
      .firstMatch(base);
  if (match == null) return base;

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
              child: Stack(
                children: [
                  Container(
                    width: double.infinity,
                    color: Colors.grey.shade200,
                    child: const Icon(
                      Icons.picture_as_pdf,
                      size: 48,
                      color: Colors.redAccent,
                    ),
                  ),
                  // Long-pressing the card does the same, but nothing on
                  // screen would say so.
                  Positioned(
                    top: 0,
                    right: 0,
                    child: IconButton(
                      icon: const Icon(Icons.more_vert),
                      iconSize: 20,
                      tooltip: '共有・削除',
                      onPressed: onLongPress,
                    ),
                  ),
                ],
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
