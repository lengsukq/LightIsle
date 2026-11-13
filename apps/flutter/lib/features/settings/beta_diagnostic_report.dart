import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/lightisle_api.dart';
import '../files/file_export_service.dart';

Future<void> showBetaDiagnosticReport(
  BuildContext context,
  LightIsleApi api,
) async {
  final report = await api.betaDiagnosticReport();
  if (!context.mounted) return;
  final save = await showDialog<bool>(
    context: context,
    builder: (dialog) {
      var copied = false;
      return StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Beta 故障报告'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(child: SelectableText(report)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(false),
              child: const Text('关闭'),
            ),
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: report));
                if (dialogContext.mounted) {
                  setDialogState(() => copied = true);
                }
              },
              icon: Icon(
                copied ? Icons.check_rounded : Icons.copy_rounded,
                size: 16,
              ),
              label: Text(copied ? '已复制报告' : '复制报告'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialog).pop(true),
              child: const Text('导出报告'),
            ),
          ],
        ),
      );
    },
  );
  if (save != true || !context.mounted) return;
  Directory? staging;
  try {
    staging = await (await getTemporaryDirectory()).createTemp(
      'lightisle-diagnostics-',
    );
    final file = File('${staging.path}/lightisle-flutter-diagnostics.json');
    await file.writeAsString(report, flush: true);
    await exportOfflineMediaFile(file, 'lightisle-flutter-diagnostics.json');
  } on Object {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('无法保存报告，请使用「复制报告」重试。')));
    }
  } finally {
    try {
      await staging?.delete(recursive: true);
    } on FileSystemException {
      /* Best effort. */
    }
  }
}
