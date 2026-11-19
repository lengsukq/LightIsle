import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'file_models.dart';

const int maxPdfPreviewSize = 64 * 1024 * 1024;

class FilePdfPreviewDialog extends StatefulWidget {
  const FilePdfPreviewDialog({
    super.key,
    required this.api,
    required this.item,
    required this.onOpenExternal,
    required this.onDownload,
    this.previewEndpoint = '/api/v2/files/preview',
  });

  final LightIsleApi api;
  final FileEntry item;
  final VoidCallback onOpenExternal;
  final VoidCallback onDownload;
  final String previewEndpoint;

  @override
  State<FilePdfPreviewDialog> createState() => _FilePdfPreviewDialogState();
}

class _FilePdfPreviewDialogState extends State<FilePdfPreviewDialog> {
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
        widget.previewEndpoint,
        query: {'path': widget.item.path},
        maxBytes: maxPdfPreviewSize,
      );
    } catch (error) {
      if (!_disposed && mounted) {
        setState(
          () => _error =
              '无法加载此 PDF（超过 64 MiB 预览上限或网络失败）：${userFacingError(error)}',
        );
      }
      return;
    }
    if (_disposed) return;
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
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = IsleGlass.rimBorderColor(isDark);
    final controller = _controller;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(
        horizontal: MediaQuery.sizeOf(context).width < 600 ? 8 : 20,
        vertical: MediaQuery.sizeOf(context).width < 600 ? 8 : 24,
      ),
      child: ClipRRect(
        borderRadius: IsleRadius.brCard,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: 860,
            minHeight: MediaQuery.sizeOf(context).height < 620 ? 160 : 340,
          ),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: IsleRadius.brCard,
            border: Border.all(color: borderColor, width: 1.0),
            boxShadow: IsleShadows.floating(isDark),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: borderColor, width: 1.0),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.picture_as_pdf_rounded,
                      size: 18,
                      color: colors.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '其他应用打开 PDF',
                      onPressed: () {
                        Navigator.of(context).pop();
                        widget.onOpenExternal();
                      },
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '保存 PDF 原件',
                      onPressed: () {
                        Navigator.of(context).pop();
                        widget.onDownload();
                      },
                      icon: const Icon(Icons.download_rounded, size: 18),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded, size: 19),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: switch ((_error, controller)) {
                  (String message, _) => SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          message,
                          style: TextStyle(fontSize: 13, color: colors.error),
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: _retry,
                          icon: const Icon(Icons.refresh_rounded, size: 17),
                          label: const Text('重新加载'),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '也可以通过右上角打开其他 PDF 阅读器或保存原件。',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  (null, null) => const IsleLoadingState(
                    compact: true,
                    label: '正在渲染 PDF…',
                  ),
                  (null, final PdfControllerPinch loaded) => PdfViewPinch(
                    controller: loaded,
                    onDocumentError: (error) {
                      if (mounted && !_disposed) {
                        setState(
                          () => _error = '无法解析此 PDF：${userFacingError(error)}',
                        );
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
