import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/features/files/file_models.dart';
import 'package:lightisle/features/files/file_text_preview_dialog.dart';

void main() {
  const item = FileEntry(
    name: 'file.txt',
    path: 'notes/file.txt',
    type: 'file',
    size: 32,
    modified: null,
    canWrite: false,
  );

  testWidgets('text QuickLook renders selectable content and actions', (
    tester,
  ) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FileTextPreviewDialog(
            item: item,
            text: 'Readable text',
            badge: const Icon(Icons.description),
            onOpenExternal: () => opened = true,
            onDownload: () {},
          ),
        ),
      ),
    );
    expect(find.text('file.txt'), findsOneWidget);
    expect(find.text('Readable text'), findsOneWidget);
    await tester.tap(find.byTooltip('其他应用打开'));
    await tester.pump();
    expect(opened, true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed encoding shows error without confusing it with text', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FileTextPreviewDialog(
            item: item,
            error: '无法识别文本编码',
            badge: const Icon(Icons.description),
            onOpenExternal: () {},
            onDownload: () {},
          ),
        ),
      ),
    );
    expect(find.textContaining('无法预览：'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
