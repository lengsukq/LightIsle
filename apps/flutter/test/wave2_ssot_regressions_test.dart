import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/core/native_video_bridge.dart';
import 'package:lightisle/core/widgets.dart';
import 'package:lightisle/features/files/backup_status_pill.dart';
import 'package:lightisle/features/files/photo_backup_prefs_schema.dart';
import 'package:lightisle/features/media/media_ui.dart';
import 'package:lightisle/features/shell/client_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CountingFakeApi extends LightIsleApi {
  _CountingFakeApi() : super('http://127.0.0.1:16666');

  int rootsHits = 0;
  int meStorageHits = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    switch (path) {
      case '/api/v2/roots':
        rootsHits++;
        return {
          'roots': [
            {
              'rootID': 'r1',
              'name': '家用主盘',
              'generation': 1,
              'online': true,
              'isDefault': true,
            },
          ],
        };
      case '/api/v2/me/storage':
        meStorageHits++;
        return {
          'userId': 2,
          'role': 'user',
          'enforcement': 'pending',
          'locations': [
            {
              'category': 'files',
              'rootID': 'r1',
              'rootGeneration': 1,
              'relativePath': 'Users/u2/files',
            },
          ],
          'rootQuotas': <Map<String, dynamic>>[],
        };
      case '/api/v2/apps':
        return {'apps': <Map<String, dynamic>>[]};
      case '/api/v2/computer-files/status':
        return {'enabled': false, 'mode': 'none'};
      default:
        return {};
    }
  }
}

void main() {
  test('IsleRadius and IsleMotion stay aligned with generated IsleTokens', () {
    expect(IsleRadius.xs, IsleTokens.radiusXs);
    expect(IsleRadius.sm, IsleTokens.radiusSm);
    expect(IsleRadius.control, IsleTokens.controlRadius);
    expect(IsleRadius.md, IsleTokens.radiusMd);
    expect(IsleRadius.item, IsleTokens.itemRadius);
    expect(IsleRadius.lg, IsleTokens.radiusLg);
    expect(IsleRadius.card, IsleTokens.cardRadius);
    expect(IsleRadius.hero, IsleTokens.heroRadius);
    expect(IsleRadius.xl, IsleTokens.radiusXl);
    expect(IsleRadius.pill, IsleTokens.radiusPill);
    expect(IsleSpace.section, IsleTokens.space6);
    expect(IsleMotion.fast.inMilliseconds, IsleTokens.motionFastMs);
    expect(IsleMotion.normal.inMilliseconds, IsleTokens.motionNormalMs);
    expect(NativeVideoBridge.channelName, 'lightisle/native-video');
  });

  test('isle_formatters formats bytes and timestamps consistently', () {
    expect(formatBytes(null), '—');
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1536), '1.5 KiB');
    expect(formatUnixSeconds(0, emptyLabel: '未使用'), '未使用');
    expect(formatUnixMillis(0, emptyLabel: '尚未完成同步'), '尚未完成同步');
    final sample = DateTime(2026, 11, 21, 9, 5, 7);
    expect(formatDateOnly(sample), '2026-11-21');
    expect(formatDateTime(sample), '2026-11-21 09:05');
    expect(formatDateTime(sample, includeSeconds: true), '2026-11-21 09:05:07');
  });

  test(
    'PhotoBackupPrefsSchema stays aligned with PhotoBackupStatusPill',
    () async {
      const deviceId = '0123456789abcdef01234567';
      final root = LightIsleRoot.fromJson({
        'rootID': 'r1',
        'name': '主盘',
        'generation': 2,
        'online': true,
        'isDefault': true,
      });
      final api = _CountingFakeApi();
      addTearDown(api.close);
      api.selectRoot(root);

      final schema = PhotoBackupPrefsSchema(
        origin: api.uri('/api/v2/me/storage').origin,
        accountName: 'alice',
        deviceId: deviceId,
        rootIdentity: root.identity,
        baseDirectory: 'Users/u2/photos',
      );

      SharedPreferences.setMockInitialValues({
        PhotoBackupPrefsSchema.installationIdKey: deviceId,
        schema.albumScopeKey: PhotoBackupPrefsSchema.albumScopeCamera,
        schema.lastCompleteAtKey(PhotoBackupPrefsSchema.albumScopeCamera):
            DateTime(2026, 11, 21).millisecondsSinceEpoch,
      });
      final synced = await readMobilePhotoBackupSnapshot(
        api: api,
        accountName: 'alice',
        baseDirectory: 'Users/u2/photos',
        canBackup: true,
      );
      expect(synced.kind, MobileBackupBadgeKind.synced);

      final failKey = schema.failureStorageKey(
        PhotoBackupPrefsSchema.albumScopeCamera,
        includeVideos: false,
      );
      SharedPreferences.setMockInitialValues({
        PhotoBackupPrefsSchema.installationIdKey: deviceId,
        schema.albumScopeKey: PhotoBackupPrefsSchema.albumScopeCamera,
        failKey: jsonEncode([
          {'key': 'k1', 'reason': 'source_unreadable'},
        ]),
        PhotoBackupPrefsSchema.failureOmittedKey(failKey): 2,
      });
      final attention = await readMobilePhotoBackupSnapshot(
        api: api,
        accountName: 'alice',
        baseDirectory: 'Users/u2/photos',
        canBackup: true,
      );
      expect(attention.kind, MobileBackupBadgeKind.pendingAttention);
      expect(attention.label, '待处理 3');
    },
  );

  testWidgets('MediaPlaybackSpeedPicker selects speed via unified pill menu', (
    tester,
  ) async {
    double? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.dark),
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: MediaPlaybackSpeedPicker(
              value: 1.0,
              onChanged: (value) => picked = value,
            ),
          ),
        ),
      ),
    );
    expect(find.byTooltip('播放倍速'), findsOneWidget);
    expect(find.text('1.0x'), findsOneWidget);

    await tester.tap(find.byTooltip('播放倍速'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.5x'));
    await tester.pumpAndSettle();
    expect(picked, 1.5);
  });

  testWidgets(
    'ClientShell shares roots and personal storage with OverviewPage without duplicate startup polling',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = _CountingFakeApi();
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          home: ClientShell(
            api: api,
            identity: const {'id': 2, 'username': 'alice', 'role': 'user'},
            onLogout: () async {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(api.rootsHits, 1);
      expect(api.meStorageHits, 1);
      expect(find.textContaining('我的家庭空间'), findsWidgets);
    },
  );
}
