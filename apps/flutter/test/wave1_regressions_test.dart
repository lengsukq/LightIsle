import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/core/user_facing_error.dart';
import 'package:lightisle/features/files/desktop_backup_models.dart';
import 'package:lightisle/features/overview/overview_page.dart';
import 'package:lightisle/features/settings/cache_management_page.dart';
import 'package:lightisle/features/settings/dav_page.dart';
import 'package:lightisle/features/settings/storage_page.dart';
import 'package:lightisle/features/shell/client_shell.dart';

class _Wave1Api extends LightIsleApi {
  _Wave1Api({this.memberOffline = false}) : super('http://127.0.0.1:16666');

  final bool memberOffline;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    return switch (path) {
      '/api/v2/roots' => {
        'roots': [
          {
            'rootID': 'drive-main',
            'name': '家庭数据盘',
            'generation': 2,
            'online': !memberOffline,
            'isDefault': true,
          },
        ],
      },
      '/api/v2/me/storage' => {
        'userId': 7,
        'enforcement': 'pending',
        'usageComplete': false,
        'locations': [
          {
            'category': 'photos',
            'rootID': 'drive-main',
            'rootGeneration': 2,
            'relativePath': 'Users/u7/photos',
          },
        ],
        'rootQuotas': [
          {
            'rootID': 'drive-main',
            'rootGeneration': 2,
            'name': '家庭数据盘',
            'quotaBytes': 100 * (1 << 30),
            'accountedBytes': 10 * (1 << 30),
            'reservedBytes': 0,
          },
        ],
      },
      '/api/v2/computer-files/status' => {'enabled': false, 'mode': 'none'},
      '/api/v2/apps' => {'apps': <Object>[]},
      '/api/v2/tasks' => {'tasks': <Object>[]},
      '/api/v2/users' => {
        'users': [
          {'id': 1, 'username': 'admin', 'role': 'admin'},
        ],
      },
      '/api/v2/users/1/storage' => {
        'userId': 1,
        'unlimited': true,
        'enforcement': 'pending',
        'locations': <Object>[],
        'rootQuotas': <Object>[],
      },
      '/api/v2/system' => {
        'hostname': 'Mac mini',
        'cpuPercent': 14.0,
        'memoryUsed': 4 << 30,
        'memoryTotal': 16 << 30,
        'volumes': <Object>[],
      },
      '/api/v2/dav/credentials' => {'credentials': <Object>[]},
      '/api/v2/admin/cache/status' => {
        'thumbnails': {'bytes': 0, 'entries': 0, 'maxBytes': 100 << 20},
        'mapTiles': {'bytes': 0, 'entries': 0, 'maxBytes': 100 << 20},
      },
      '/api/v2/files' => {'entries': <Object>[], 'canWrite': true},
      _ => <String, dynamic>{},
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('userFacingError maps new drive/cinema codes and drops dead codes', () {
    expect(knownLightIsleErrorMessage('cinema_volume_offline'), isNotNull);
    expect(knownLightIsleErrorMessage('drive_discovery_unavailable'), isNotNull);
    expect(knownLightIsleErrorMessage('drive_in_use_or_protected'), isNotNull);
    expect(knownLightIsleErrorMessage('diskutil_operation_failed'), isNotNull);
    expect(knownLightIsleErrorMessage('apps_unavailable'), isNull);
    expect(
      knownLightIsleErrorMessage('storage_quota_is_per_disk_upgrade_client'),
      isNull,
    );
  });

  test('DesktopBackupStore surfaces honest loadError on corrupted JSON', () async {
    final store = DesktopBackupStore(
      serverOrigin: 'http://127.0.0.1:16666',
      userId: 7,
      accountName: 'alice',
    );
    await store.saveTasks(const []);
    final prefs = await SharedPreferences.getInstance();
    final tasksKey = prefs.getKeys().firstWhere((k) => k.endsWith('.tasks'));
    await prefs.setString(tasksKey, '{broken-json');
    final tasks = await store.loadTasks();
    expect(tasks, isEmpty);
    expect(store.lastLoadError, isNotNull);
    expect(store.lastLoadError, contains('读取失败'));
  });

  testWidgets('DavPage copies valid interpolated WebDAV path without .path bug', (
    tester,
  ) async {
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map?)?['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final api = _Wave1Api();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.light),
        home: DavPage(api: api, accountId: 'uid:7'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final infuseBtn = find.text('Infuse 参数');
    expect(infuseBtn, findsOneWidget);
    await tester.tap(infuseBtn);
    await tester.pump();
    expect(copiedText, isNotNull);
    expect(copiedText, contains('路径：/dav-roots/drive-main/2/'));
    expect(copiedText, isNot(contains('.path')));
  });

  testWidgets('StoragePage forwards accountId to CacheManagementPage', (
    tester,
  ) async {
    final api = _Wave1Api();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.light),
        home: StoragePage(api: api, isAdmin: true, accountId: 'uid:1'),
      ),
    );
    await tester.pumpAndSettle();

    final cacheBtn = find.text('本地缓存管理');
    await tester.scrollUntilVisible(cacheBtn, 200);
    await tester.ensureVisible(cacheBtn);
    await tester.pumpAndSettle();
    await tester.tap(cacheBtn);
    await tester.pumpAndSettle();

    final cachePage = tester.widget<CacheManagementPage>(
      find.byType(CacheManagementPage),
    );
    expect(cachePage.accountId, 'uid:1');
  });

  testWidgets('Member OverviewPage shows top offline reminder when drive is offline', (
    tester,
  ) async {
    final api = _Wave1Api(memberOffline: true);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.light),
        home: Scaffold(
          body: OverviewPage(api: api, isAdmin: false, accountId: 'uid:7'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('overviewAttentionBanner')), findsOneWidget);
    expect(find.textContaining('个人存储硬盘当前离线或已变更'), findsOneWidget);
    expect(find.text('查看我的空间'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Desktop sidebar keeps Files Workbench entry in both collapsed and expanded states', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final api = _Wave1Api();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.light),
        home: ClientShell(
          api: api,
          identity: const {'id': 1, 'username': 'admin', 'role': 'admin'},
          onLogout: () async {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const ValueKey('railFilesWorkbenchButton')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('macSidebarToggle')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('railFilesWorkbenchButton')),
      findsOneWidget,
    );
    expect(find.text('文件工作台'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Mobile shell removes duplicate AppBar account button and uses compact file header', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final api = _Wave1Api();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.light),
        home: ClientShell(
          api: api,
          identity: const {'id': 1, 'username': 'admin', 'role': 'admin'},
          onLogout: () async {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('macAccountButton')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('dashboardFilesEntry')));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byKey(const ValueKey('backToDashboardFromFiles')),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });
}
