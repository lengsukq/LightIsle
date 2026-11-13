import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/settings/apps_center_page.dart';
import 'package:url_launcher/url_launcher.dart';

class _FakeAppsApi extends LightIsleApi {
  _FakeAppsApi({required this.isAdmin}) : super('http://127.0.0.1');

  final bool isAdmin;
  String defaultLocationId = 'internal';
  Map<String, dynamic>? externalStorageLocation;
  bool includeTemplates = false;
  final List<String> calls = <String>[];
  Map<String, dynamic>? lastPutBody;
  Map<String, dynamic>? lastStorageBody;
  String? lastDownloadedPath;
  String? lastDownloadSavePath;

  final List<Map<String, dynamic>> apps = <Map<String, dynamic>>[
    {
      'id': 'cpe-monitor',
      'name': 'CPE 流量与设备监控',
      'description': '监控 H153 5G CPE 流量套餐、信号质量与短信同步',
      'category': 'network',
      'revision': 'rev-1',
      'status': 'sleeping',
      'memoryBytes': 0,
      'access': <String, dynamic>{
        'policy': 'admin_only',
        'allowedUserIDs': <int>[],
      },
      'web': <String, dynamic>{
        'enabled': true,
        'mode': 'on-demand',
        'idleTimeoutSeconds': 900,
        'autoRestart': true,
      },
      'cron': <String, dynamic>{
        'hasCron': true,
        'enabled': true,
        'cron': '*/15 * * * *',
        'timezone': 'Asia/Shanghai',
        'events': <String>['failure', 'timeout'],
        'channels': <String>['bark'],
      },
    },
    {
      'id': 'network-pulse',
      'name': '轻屿网络脉搏',
      'description': '内置静态轻应用',
      'category': 'system',
      'revision': 'rev-static',
      'status': 'static',
      'access': <String, dynamic>{
        'policy': 'all_members',
        'allowedUserIDs': <int>[],
      },
      'web': <String, dynamic>{'enabled': true, 'mode': 'static'},
      'cron': <String, dynamic>{
        'hasCron': false,
        'enabled': false,
        'events': <String>[],
        'channels': <String>[],
      },
    },
  ];

  Map<String, dynamic> _snapshot() => {
    'apps': apps.map((e) => Map<String, dynamic>.from(e)).toList(),
    'isAdmin': isAdmin,
    if (includeTemplates)
      'templates': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'home-notes',
          'name': '家庭记事本',
          'description': '静态记事应用',
          'installed': false,
        },
      ],
    'members': <Map<String, dynamic>>[
      {'id': 1, 'username': 'admin', 'role': 'admin'},
      {'id': 2, 'username': 'alice', 'role': 'member'},
    ],
    'configuredChannels': <String>['bark', 'email'],
    'appStorage': <String, dynamic>{
      'defaultLocationId': defaultLocationId,
      'maxInternal': 1,
      'maxExternal': 1,
      'maxLocations': 2,
      'hasExternal': externalStorageLocation != null,
      'locations': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'internal',
          'kind': 'internal',
          'name': 'Mac 内置盘',
          'path': '/Users/admin/Library/Application Support/LightIsle',
          'pluginsDir':
              '/Users/admin/Library/Application Support/LightIsle/plugins',
          'pluginDataDir':
              '/Users/admin/Library/Application Support/LightIsle/plugin-data',
          'isDefault': defaultLocationId == 'internal',
          'isCustomPath': false,
          'online': true,
          'writable': true,
          'freeBytes': 21474836480,
          'totalBytes': 107374182400,
          'appCount': 2,
        },
        ?externalStorageLocation,
      ],
      'availableVolumes': <Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'ExtSSD',
          'mount': '/Volumes/ExtSSD',
          'suggestedPath': '/Volumes/ExtSSD/LightIsleApps',
          'totalBytes': 1000000000000,
          'freeBytes': 500000000000,
          'readOnly': false,
        },
      ],
    },
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    calls.add('GET $path');
    if (path == '/api/v2/apps') {
      return _snapshot();
    }
    if (path == '/api/v2/apps/cpe-monitor/logs') {
      return {
        'id': 'cpe-monitor',
        'webOutput': 'Listening on 127.0.0.1:49152',
        'cronRuns': <Map<String, dynamic>>[
          {
            'state': 'success',
            'exitCode': 0,
            'output': 'Collected 5G signal RSRP -82 dBm',
          },
        ],
      };
    }
    throw StateError('unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    calls.add('$method $path');
    if (method == 'POST' && path == '/api/v2/apps/refresh') {
      return _snapshot();
    }
    if (method == 'PUT' && path == '/api/v2/apps/storage') {
      final map = Map<String, dynamic>.from(body as Map);
      lastStorageBody = map;
      final act = map['action']?.toString() ?? '';
      if (act == 'add' || act == 'set') {
        if (map['kind'] == 'external') {
          externalStorageLocation = <String, dynamic>{
            'id': 'external',
            'kind': 'external',
            'name': (map['name']?.toString().isNotEmpty ?? false)
                ? map['name'].toString()
                : 'ExtSSD',
            'path': map['path'].toString(),
            'pluginsDir': '${map['path']}/plugins',
            'pluginDataDir': '${map['path']}/plugin-data',
            'isDefault':
                map['setDefault'] == true || defaultLocationId == 'external',
            'isCustomPath': true,
            'online': true,
            'writable': true,
            'freeBytes': 500000000000,
            'totalBytes': 1000000000000,
            'appCount': 0,
          };
          if (map['setDefault'] == true) defaultLocationId = 'external';
        }
      } else if (act == 'remove_external') {
        externalStorageLocation = null;
        defaultLocationId = 'internal';
      } else if (act == 'set_default') {
        defaultLocationId = map['defaultLocationId']?.toString() ?? 'internal';
      }
      return _snapshot();
    }
    if (method == 'POST' && path == '/api/v2/apps/cpe-monitor/launch') {
      apps[0]['status'] = 'running';
      apps[0]['memoryMB'] = 24;
      return {
        'id': 'cpe-monitor',
        'status': 'running',
        'ticket': 'tk-123',
        'launchUrl': '/apps/cpe-monitor/?__li_ticket=tk-123',
      };
    }
    if (method == 'PUT' &&
        (path == '/api/v2/apps/cpe-monitor' ||
            path == '/api/v2/apps/network-pulse')) {
      final map = Map<String, dynamic>.from(body as Map);
      lastPutBody = map;
      final idx = path.endsWith('/network-pulse') ? 1 : 0;
      if (map['access'] is Map) {
        apps[idx]['access'] = Map<String, dynamic>.from(map['access'] as Map);
      }
      if (map['web'] is Map) {
        apps[idx]['web'] = Map<String, dynamic>.from(map['web'] as Map);
      }
      if (map['cron'] is Map) {
        apps[idx]['cron'] = Map<String, dynamic>.from(map['cron'] as Map);
      }
      return _snapshot();
    }
    throw StateError('unexpected $method $path');
  }

  @override
  Future<void> download(
    String path,
    String savePath, {
    Map<String, String>? query,
    void Function(int received, int total)? onProgress,
  }) async {
    calls.add('DOWNLOAD $path');
    lastDownloadedPath = path;
    lastDownloadSavePath = savePath;
  }
}

void main() {
  testWidgets(
    'Admin AppsCenterPage updates member ACL, views logs, and launches app without MCP controls',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = _FakeAppsApi(isAdmin: true);
      addTearDown(api.close);

      final launchedUris = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          home: AppsCenterPage(
            api: api,
            isAdmin: true,
            urlLauncher: (uri, {mode = LaunchMode.platformDefault}) async {
              launchedUris.add(uri);
              return true;
            },
            pickBackupSavePath: (defaultName) async => '/tmp/$defaultName',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(api.calls, contains('GET /api/v2/apps'));
      expect(find.byKey(const ValueKey('adminMcpControlCard')), findsNothing);
      expect(find.text('AI Agent (MCP) 服务'), findsNothing);
      expect(find.text('CPE 流量与设备监控'), findsOneWidget);
      expect(find.text('按需休眠 0 MB'), findsOneWidget);
      expect(find.text('仅管理员'), findsOneWidget);
      expect(find.text('定时 */15 * * * *'), findsOneWidget);

      // Open Member Access Sheet and grant access to alice (id: 2)
      await tester.tap(find.byKey(const ValueKey('accessApp_cpe-monitor')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('accessPolicy_selected_members')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('memberAccess_2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('saveMemberAccessButton')));
      await tester.pumpAndSettle();

      expect(api.calls, contains('PUT /api/v2/apps/cpe-monitor'));
      expect(
        (api.lastPutBody?['access'] as Map?)?['policy'],
        equals('selected_members'),
      );
      expect(
        (api.lastPutBody?['access'] as Map?)?['allowedUserIDs'],
        equals(<int>[2]),
      );
      expect(api.lastPutBody?.containsKey('web'), isFalse);
      expect(api.lastPutBody?.containsKey('cron'), isFalse);
      expect(find.text('指定成员'), findsOneWidget);

      // P1-3: Open Lifecycle/Cron Sheet on static app (network-pulse with hasCron: false, enabled: false)
      // and verify saving config omits the absent 'cron' module from PUT payload
      await tester.tap(find.byKey(const ValueKey('configApp_network-pulse')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cronEnableSwitch')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('saveLifecycleCronButton')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('PUT /api/v2/apps/network-pulse'));
      expect(api.lastPutBody?.containsKey('web'), isTrue);
      expect(api.lastPutBody?.containsKey('cron'), isFalse);

      // Open Logs Sheet
      await tester.tap(find.byKey(const ValueKey('logsApp_cpe-monitor')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('GET /api/v2/apps/cpe-monitor/logs'));
      expect(
        find.textContaining('Listening on 127.0.0.1:49152'),
        findsOneWidget,
      );
      Navigator.of(tester.element(find.byType(AppsCenterPage))).pop();
      await tester.pumpAndSettle();

      // P1-2: Export plugin data backup via authenticated LightIsleApi.download (not external browser)
      await tester.tap(
        find.byKey(const ValueKey('moreActionsApp_cpe-monitor')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出应用数据 (.tar.gz)'));
      await tester.pumpAndSettle();
      expect(
        api.calls,
        contains('DOWNLOAD /api/v2/apps/cpe-monitor/data-backup'),
      );
      expect(
        api.lastDownloadSavePath,
        equals('/tmp/cpe-monitor-data-backup.tar.gz'),
      );
      expect(launchedUris, isEmpty);

      // Launch App into Workbench Session
      await tester.tap(find.byKey(const ValueKey('launchApp_cpe-monitor')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('POST /api/v2/apps/cpe-monitor/launch'));
      expect(
        launchedUris.single.toString(),
        equals('http://127.0.0.1/apps/cpe-monitor/?__li_ticket=tk-123'),
      );
      expect(find.byKey(const ValueKey('workbenchBackButton')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('workbenchRefreshButton')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('workbenchFullscreenButton')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('workbenchExternalButton')),
        findsOneWidget,
      );
      expect(find.text('轻应用运行会话 · CPE 流量与设备监控'), findsOneWidget);
      expect(find.text('http://127.0.0.1/apps/cpe-monitor/'), findsOneWidget);
      expect(find.text('运行中 24 MB'), findsOneWidget);

      // Return to App Center list from Embedded Workbench
      await tester.tap(find.byKey(const ValueKey('workbenchBackButton')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('adminMcpControlCard')), findsNothing);
      expect(find.text('运行中 24 MB'), findsOneWidget);
    },
  );

  testWidgets(
    'Member AppsCenterPage hides admin controls and opens authorized app',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = _FakeAppsApi(isAdmin: false);
      addTearDown(api.close);

      final launchedUris = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          home: AppsCenterPage(
            api: api,
            isAdmin: false,
            urlLauncher: (uri, {mode = LaunchMode.platformDefault}) async {
              launchedUris.add(uri);
              return true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('adminMcpControlCard')), findsNothing);
      expect(find.byKey(const ValueKey('accessApp_cpe-monitor')), findsNothing);
      expect(find.byKey(const ValueKey('configApp_cpe-monitor')), findsNothing);
      expect(find.byKey(const ValueKey('logsApp_cpe-monitor')), findsNothing);
      expect(find.text('CPE 流量与设备监控'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('launchApp_cpe-monitor')));
      await tester.pumpAndSettle();
      expect(
        launchedUris.single.toString(),
        equals('http://127.0.0.1/apps/cpe-monitor/?__li_ticket=tk-123'),
      );
    },
  );

  testWidgets(
    'AppsCenterPage surfaces launch failure and respects cancelled backup picker',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = _FakeAppsApi(isAdmin: true);
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: AppsCenterPage(
            api: api,
            isAdmin: true,
            urlLauncher: (uri, {mode = LaunchMode.platformDefault}) async =>
                false,
            pickBackupSavePath: (_) async => null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Failed browser launch must show error instead of opening workbench false-positively.
      await tester.tap(find.byKey(const ValueKey('launchApp_cpe-monitor')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('workbenchBackButton')), findsNothing);
      expect(find.textContaining('打开应用失败'), findsOneWidget);

      // Cancelled directory picker must return silently without dumping to systemTemp.
      await tester.tap(
        find.byKey(const ValueKey('moreActionsApp_cpe-monitor')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出应用数据 (.tar.gz)'));
      await tester.pumpAndSettle();
      expect(api.lastDownloadedPath, isNull);
    },
  );

  testWidgets(
    'app storage locations card supports 1 internal + 1 external slot lifecycle',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = _FakeAppsApi(isAdmin: true);
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(home: AppsCenterPage(api: api, isAdmin: true)),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('appStorageLocationsCard')),
        findsOneWidget,
      );
      expect(find.text('已配置 1/2（1 内置盘 + 1 其他盘）'), findsOneWidget);
      expect(find.text('内置盘 1/1'), findsOneWidget);
      expect(find.text('其他盘 0/1'), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const ValueKey('addExternalAppStorageButton')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('addExternalAppStorageButton')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('appStoragePathField')), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('confirmAppStorageDialogButton')),
      );
      await tester.pumpAndSettle();

      expect(api.lastStorageBody?['action'], 'add');
      expect(api.lastStorageBody?['kind'], 'external');
      expect(api.lastStorageBody?['path'], '/Volumes/ExtSSD/LightIsleApps');
      expect(find.text('已配置 2/2（1 内置盘 + 1 其他盘）'), findsOneWidget);
      expect(find.text('其他盘 1/1'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('addExternalAppStorageButton')),
        findsNothing,
      );

      await tester.ensureVisible(
        find.byKey(const ValueKey('removeExternalAppStorageButton')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('removeExternalAppStorageButton')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认移除'));
      await tester.pumpAndSettle();

      expect(api.lastStorageBody?['action'], 'remove_external');
      expect(find.text('其他盘 0/1'), findsOneWidget);
    },
  );

  testWidgets(
    '320px workbench exits via Back without overflow, hides member runtime badges, filters static menus, and validates empty storage path',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final adminApi = _FakeAppsApi(isAdmin: true)
        ..includeTemplates = true
        ..externalStorageLocation = <String, dynamic>{
          'id': 'external',
          'kind': 'external',
          'name': 'ExtSSD',
          'path': '/Volumes/ExtSSD/LightIsleApps',
          'isDefault': false,
          'isCustomPath': true,
          'online': true,
          'writable': true,
          'freeBytes': 500000000000,
          'totalBytes': 1000000000000,
          'appCount': 0,
        };
      addTearDown(adminApi.close);

      await tester.pumpWidget(
        MaterialApp(
          home: AppsCenterPage(
            api: adminApi,
            isAdmin: true,
            urlLauncher: (_, {mode = LaunchMode.platformDefault}) async => true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Select external slot, mark offline on reload -> resets cleanly to default ('').
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('templateInstallLocationDropdown')),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('templateInstallLocationDropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('其他盘 · ExtSSD').last);
      await tester.pumpAndSettle();
      adminApi.externalStorageLocation!['online'] = false;
      await tester.tap(find.byKey(const ValueKey('refreshAppsIconButton')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('跟随默认位置'), findsOneWidget);

      // Static + no-cron app filters out process & cron actions in popup menu.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('moreActionsApp_network-pulse')),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('moreActionsApp_network-pulse')),
      );
      await tester.pumpAndSettle();
      expect(find.text('启动 Web 进程'), findsNothing);
      expect(find.text('立即执行定时任务'), findsNothing);
      expect(find.text('导出应用数据 (.tar.gz)'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      // Launch workbench at 320px -> zero overflow and system Back exits workbench.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('launchApp_cpe-monitor')),
        -150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('launchApp_cpe-monitor')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('workbenchBackButton')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('workbenchBackButton')), findsNothing);

      // Member workbench hides admin runtime & storage badges.
      final memberApi = _FakeAppsApi(isAdmin: false);
      addTearDown(memberApi.close);
      await tester.pumpWidget(
        MaterialApp(
          home: AppsCenterPage(
            key: const ValueKey('memberAppsCenterPage'),
            api: memberApi,
            isAdmin: false,
            urlLauncher: (_, {mode = LaunchMode.platformDefault}) async => true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('launchApp_cpe-monitor')),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('launchApp_cpe-monitor')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('workbenchBackButton')), findsOneWidget);
      expect(find.text('运行中 24 MB'), findsNothing);
      expect(find.textContaining('内置盘'), findsNothing);

      // Storage path dialog validates empty path inline without calling API.
      adminApi.externalStorageLocation = null;
      await tester.pumpWidget(
        MaterialApp(home: AppsCenterPage(api: adminApi, isAdmin: true)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('addExternalAppStorageButton')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('addExternalAppStorageButton')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('appStoragePathField')),
        '   ',
      );
      await tester.tap(
        find.byKey(const ValueKey('confirmAppStorageDialogButton')),
      );
      await tester.pumpAndSettle();
      expect(find.text('请填写 Mac 本机目录路径'), findsOneWidget);
      expect(adminApi.lastStorageBody, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
