import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/features/files/android_photo_backup_page.dart';
import 'package:lightisle/features/files/downloads_page.dart';
import 'package:lightisle/features/files/file_shares_page.dart';
import 'package:lightisle/features/overview/overview_page.dart';
import 'package:lightisle/features/media/offline_photos_page.dart';
import 'package:lightisle/features/media/offline_videos_page.dart';
import 'package:lightisle/features/media/photo_map_page.dart';
import 'package:lightisle/features/media/local_video_page.dart';
import 'package:lightisle/features/settings/account_security_page.dart';
import 'package:lightisle/features/settings/admin_activity_page.dart';
import 'package:lightisle/features/settings/dav_page.dart';
import 'package:lightisle/features/settings/settings_page.dart';
import 'package:lightisle/features/settings/storage_page.dart';

import 'client_shell_test.dart' show FixtureApi;
import 'responsive_shell_test.dart' show visualTheme;

void main() {
  setUpAll(() async {
    if (!const bool.fromEnvironment('LIGHTISLE_CAPTURE_VISUALS')) return;
    await (FontLoader('IsleVisualBody')..addFont(
          File('/System/Library/Fonts/Supplemental/Arial Unicode.ttf')
              .readAsBytes()
              .then(ByteData.sublistView),
        ))
        .load();
    final flutterRoot = File('/opt/homebrew/bin/flutter')
        .resolveSymbolicLinksSync()
        .replaceFirst(RegExp(r'/bin/flutter$'), '');
    await (FontLoader('MaterialIcons')..addFont(
          File(
            '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });
  final cases = <(String, Widget Function(FixtureApi))>[
    ('Downloads', (api) => DownloadsPage(api: api)),
    ('My shares', (api) => FileSharesPage(api: api)),
    ('Task history', (api) => TaskHistoryPage(api: api)),
    (
      'Account security',
      (api) => AccountSecurityPage(api: api, onSignedOut: () async {}),
    ),
    (
      'Admin alerts',
      (api) => AdminActivityPage(api: api, kind: AdminActivity.alerts),
    ),
    (
      'Admin audit',
      (api) => AdminActivityPage(api: api, kind: AdminActivity.audit),
    ),
    ('WebDAV', (api) => DavPage(api: api)),
    ('Accounts', (api) => AccountsPage(api: api, currentUsername: 'owner')),
    (
      'Grants',
      (api) => GrantsPage(
        api: api,
        user: const {
          'id': 8,
          'username': 'member',
          'role': 'member',
          'enabled': true,
        },
      ),
    ),
    ('Storage', (api) => StoragePage(api: api, isAdmin: true)),
    ('Upload maintenance', (api) => UploadMaintenancePage(api: api)),
    (
      'Offline photos',
      (api) => OfflinePhotosPage(api: api, accountId: 'uid:1'),
    ),
    (
      'Offline videos',
      (api) => OfflineVideosPage(api: api, accountName: 'uid:1'),
    ),
    ('Photo map', (api) => PhotoMapPage(api: api)),
    (
      'Photo backup',
      (api) => AndroidPhotoBackupPage(
        api: api,
        accountName: 'uid:1',
        androidPlatformOverride: false,
        iosPlatformOverride: false,
      ),
    ),
    ('Local video', (_) => const LocalVideoPage(path: '/nonexistent.mp4')),
  ];

  for (final (name, factory) in cases) {
    for (final (size, scale) in <(Size, double)>[
      (const Size(320, 568), 1),
      (const Size(320, 568), 2),
      (const Size(375, 812), 1),
      (const Size(600, 840), 1),
      (const Size(1024, 700), 1),
    ]) {
      testWidgets('$name lays out at $size and text scale $scale', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final api = FixtureApi();
        final captureKey = GlobalKey();
        addTearDown(api.close);
        await tester.pumpWidget(
          RepaintBoundary(
            key: captureKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: const bool.fromEnvironment('LIGHTISLE_CAPTURE_VISUALS')
                  ? visualTheme()
                  : buildIsleTheme(Brightness.light),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: IsleCanvas(child: child!),
              ),
              home: factory(api),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 450));
        expect(
          tester.takeException(),
          isNull,
          reason: '$name at $size, $scale',
        );
        if (name == 'Photo map' && size.width == 320) {
          await tester.tap(find.text('地图选项'));
          await tester.pump(const Duration(milliseconds: 300));
          expect(
            tester.takeException(),
            isNull,
            reason: 'Map options expanded at $size / $scale',
          );
        }
        if (const bool.fromEnvironment('LIGHTISLE_CAPTURE_VISUALS')) {
          final boundary =
              captureKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final img = await boundary.toImage();
            final data = await img.toByteData(format: ui.ImageByteFormat.png);
            final out = Directory('../../build/flutter-page-audit');
            await out.create(recursive: true);
            await File('${out.path}/${size.width.toInt()}-${scale}x-$name.png')
                .writeAsBytes(data!.buffer.asUint8List());
            img.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
