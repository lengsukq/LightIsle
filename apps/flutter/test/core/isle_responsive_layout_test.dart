import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';

void main() {
  for (final width in <double>[320, 390, 820, 1180]) {
    testWidgets(
      'page heading, description and actions remain accessible at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        var activated = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildIsleTheme(Brightness.light),
            home: Scaffold(
              body: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: IslePageHeader(
                    title: '个人空间',
                    subtitle: '管理文件、照片和视频',
                    trailing: TextButton(
                      onPressed: () => activated = true,
                      child: const Text('刷新'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.text('个人空间'), findsOneWidget);
        expect(find.text('管理文件、照片和视频'), findsOneWidget);
        await tester.tap(find.text('刷新'));
        expect(activated, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
