import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

import '../../core/lightisle_api.dart';
import 'file_models.dart';

const int maxPdfPreviewSize = 64 * 1024 * 1024;

class FilePdfPreviewDialog extends StatefulWidget {
  const FilePdfPreviewDialog({
    super.key,
    required this.api,
    required this.item,
    required this.onOpenExternal,
    required this.onDownload,
  });

  final LightIsleApi api;
  final FileEntry item;
  final VoidCallback onOpenExternal;
  final VoidCallback onDownload;

  @override
  State<FilePdfPreviewDialog> createState() => FilePdfPreviewDialogState();
}

class FilePdfPreviewDialogState extends State<FilePdfPreviewDialog> {
  PdfControllerPinch? _controller;
  String? _error;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted && !_disposed) setState(() => _error = null);
    Uint8List data;
    try {
      data = await widget.api.bytes(
        '/api/v2/files/preview',
        query: {'path': widget.item.path},
        maxBytes: maxPdfPreviewSize,
      );
    } catch (error) {
      if (!_disposed && mounted) {
        setState(() => _error = '无法加载此 PDF（超过 64 MiB 预览上限或网络失败）：$error');
      }
      return;
    }
    if (_disposed) return;
    // Pinch-zoom re-renders pages at an appropriate resolution, important for
    // phone readers. pdfx owns the native PDF document lifecycle.
    setState(() {
      _controller = PdfControllerPinch(document: PdfDocument.openData(data));
    });
  }

  Future<void> _retry() async {
    final old = _controller;
    _controller = null;
    old?.dispose();
    if (mounted && !_disposed) await _load();
  }

  @override
  void dispose() {
    _disposed = true;
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(
        horizontal: MediaQuery.sizeOf(context).width < 600 ? 6 : 20,
        vertical: MediaQuery.sizeOf(context).width < 600 ? 6 : 24,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Container(
          constraints: BoxConstraints(
            maxWidth: 860,
            minHeight: MediaQuery.sizeOf(context).height < 620 ? 160 : 350,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
              width: 0.85,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 10, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '其他应用打开 PDF',
                      onPressed: () {
                        Navigator.of(context).pop();
                        widget.onOpenExternal();
                      },
                      icon: const Icon(Icons.open_in_new_rounded),
                    ),
                    IconButton(
                      tooltip: '保存 PDF 原件',
                      onPressed: () {
                        Navigator.of(context).pop();
                        widget.onDownload();
                      },
                      icon: const Icon(Icons.download_rounded),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: switch ((_error, controller)) {
                  (String message, _) => SingleChildScrollView(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          message,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: _retry,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('重新加载'),
                        ),
                        const Text('也可以通过右上角打开其他 PDF 阅读器或保存原件。'),
                      ],
                    ),
                  ),
                  (null, null) => const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  (null, final PdfControllerPinch loaded) => PdfViewPinch(
                    controller: loaded,
                    onDocumentError: (error) {
                      if (mounted && !_disposed) {
                        setState(() => _error = '无法解析此 PDF：$error');
                      }
                    },
                  ),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
