import 'dart:io';

import 'package:flutter/material.dart';

import 'pdf_worker.dart';

/// Lets the scanned pages be checked and fixed up before they become a PDF:
/// rotating, deleting, reordering, and scanning more.
class ScanReviewPage extends StatefulWidget {
  const ScanReviewPage({
    super.key,
    required this.initialPages,
    required this.onAddPages,
    required this.maxPages,
  });

  final List<ScanPage> initialPages;

  /// Opens the scanner again, returning the paths of anything captured.
  final Future<List<String>> Function() onAddPages;

  /// How many pages this document may hold in total.
  final int maxPages;

  @override
  State<ScanReviewPage> createState() => _ScanReviewPageState();
}

class _ScanReviewPageState extends State<ScanReviewPage> {
  late final List<ScanPage> _pages = [...widget.initialPages];
  bool _isAdding = false;

  Future<void> _addPages() async {
    setState(() => _isAdding = true);
    try {
      final paths = await widget.onAddPages();
      if (paths.isEmpty || !mounted) return;
      setState(() {
        _pages.addAll([for (final path in paths) ScanPage(imagePath: path)]);
      });
    } finally {
      if (mounted) setState(() => _isAdding = false);
    }
  }

  void _rotate(int index) {
    setState(() => _pages[index] = _pages[index].rotatedBy(1));
  }

  void _delete(int index) {
    setState(() => _pages.removeAt(index));
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      // ReorderableListView reports the slot the row lands in, which counts
      // the row itself while it is still in the list.
      final target = newIndex > oldIndex ? newIndex - 1 : newIndex;
      _pages.insert(target, _pages.removeAt(oldIndex));
    });
  }

  void _preview(int index) {
    final page = _pages[index];
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: InteractiveViewer(
                child: RotatedBox(
                  quarterTurns: page.quarterTurns,
                  child: Image.file(File(page.imagePath)),
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('閉じる'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('スキャンを破棄しますか？'),
        content: const Text('読み込んだページは保存されません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('編集に戻る'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('破棄'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final isFull = _pages.length >= widget.maxPages;

    return PopScope(
      canPop: _pages.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmDiscard();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('ページの確認'),
          actions: [
            TextButton(
              onPressed:
                  _pages.isEmpty ? null : () => Navigator.pop(context, _pages),
              child: const Text('保存'),
            ),
          ],
        ),
        body: _pages.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'ページがありません。\n「ページを追加」から読み込んでください。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              )
            : ReorderableListView.builder(
                padding: const EdgeInsets.only(bottom: 12),
                itemCount: _pages.length,
                onReorder: _reorder,
                itemBuilder: (context, index) {
                  return _PageTile(
                    // The position is not stable under reordering, so the
                    // image path is what identifies a row.
                    key: ValueKey(_pages[index].imagePath),
                    page: _pages[index],
                    pageNumber: index + 1,
                    onPreview: () => _preview(index),
                    onRotate: () => _rotate(index),
                    onDelete: () => _delete(index),
                  );
                },
              ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${_pages.length} / ${widget.maxPages} ページ',
                    style: const TextStyle(color: Colors.grey),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _isAdding || isFull ? null : _addPages,
                  icon: _isAdding
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add_a_photo_outlined),
                  label: Text(isFull ? '上限に達しました' : 'ページを追加'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PageTile extends StatelessWidget {
  const _PageTile({
    super.key,
    required this.page,
    required this.pageNumber,
    required this.onPreview,
    required this.onRotate,
    required this.onDelete,
  });

  final ScanPage page;
  final int pageNumber;
  final VoidCallback onPreview;
  final VoidCallback onRotate;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      onTap: onPreview,
      leading: SizedBox(
        width: 44,
        height: 60,
        child: ColoredBox(
          color: Colors.grey.shade200,
          child: RotatedBox(
            quarterTurns: page.quarterTurns,
            child: Image.file(File(page.imagePath), fit: BoxFit.contain),
          ),
        ),
      ),
      title: Text('$pageNumber'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.rotate_right),
            tooltip: '回転',
            visualDensity: VisualDensity.compact,
            onPressed: onRotate,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '削除',
            visualDensity: VisualDensity.compact,
            color: Theme.of(context).colorScheme.error,
            onPressed: onDelete,
          ),
          ReorderableDragStartListener(
            index: pageNumber - 1,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Icon(Icons.drag_handle),
            ),
          ),
        ],
      ),
    );
  }
}
