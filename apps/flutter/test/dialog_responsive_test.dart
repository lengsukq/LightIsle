import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/features/files/file_destination_dialog.dart';
import 'package:lightisle/features/media/photos_page.dart';
import 'package:lightisle/features/settings/account_security_page.dart';

import 'client_shell_test.dart' show FixtureApi;

void main() {
  for (final (size, scale) in <(Size, double)>[
    (const Size(320, 568), 2),
    (const Size(375, 812), 1),
    (const Size(1024, 700), 1),
  ]) {
    for (final (name, factory) in <(String, Widget Function(FixtureApi))>[
      (
        'Select destination',
        (api) => FileDestinationDialog(
          api: api,
          action: 'copy',
          sourceName: 'Family holiday photos and videos_2026',
          sourcePath: 'family/holiday',
        ),
      ),
      (
        'Choose grant folder',
        (api) => FileDestinationDialog(
          api: api,
          action: 'grant',
          sourceName: '',
          sourcePath: '',
          directoryOnly: true,
        ),
      ),
      ('Album name', (_) => const AlbumNameDialog(initialName: '家庭相册')),
      (
        'Reset member password',
        (api) => ResetMemberPasswordDialog(
          api: api,
          user: const {'id': 2, 'username': 'member'},
        ),
      ),
    ]) {
      testWidgets('$name dialog at $size and text ${scale}x', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final api = FixtureApi();
        addTearDown(api.close);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildIsleTheme(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: true,
              ),
              child: IsleCanvas(child: child!),
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: ElevatedButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => factory(api),
                    ),
                    child: const Text('Open dialog'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open dialog'));
        await tester.pump(const Duration(milliseconds: 450));
        expect(
          tester.takeException(),
          isNull,
          reason: '$name at $size / $scale',
        );
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
