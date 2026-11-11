import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/settings/apps_center_page.dart';
import 'package:url_launcher/url_launcher.dart';

class _FakeAppsApi extends LightIsleApi {
  _FakeAppsApi({required this.isAdmin}) : super('http://127.0.0.1');

  final bool isAdmin;
  bool mcpEnabled = false;
  final List<String> calls = <String>[];
  Map<String, dynamic>? lastPutBody;
  Map<String, dynamic>? lastMcpDebugBody;
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
    'mcpEnabled': mcpEnabled,
    'mcpPrompt': 'lightisled mcp --data-dir /tmp/lightisle',
    'members': <Map<String, dynamic>>[
      {'id': 1, 'username': 'admin', 'role': 'admin'},
      {'id': 2, 'username': 'alice', 'role': 'member'},
    ],
    'configuredChannels': <String>['bark', 'email'],
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
    if (method == 'PUT' && path == '/api/v2/apps/mcp') {
      final map = Map<String, dynamic>.from(body as Map);
      mcpEnabled = map['enabled'] == true;
      return {
        'mcpEnabled': mcpEnabled,
        'mcpPrompt': 'lightisled mcp --data-dir /tmp/lightisle',
      };
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
    if (method == 'POST' && path == '/api/v2/apps/mcp/debug') {
      lastMcpDebugBody = Map<String, dynamic>.from(body as Map);
      return {
        'responseJson': '{"uri":"${lastMcpDebugBody?['uri']}"}',
        'logs': <Map<String, dynamic>>[],
      };
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
    'Admin AppsCenterPage toggles MCP, updates member ACL, views logs, and launches app',
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
      expect(find.byKey(const ValueKey('adminMcpControlCard')), findsOneWidget);
      expect(find.text('CPE 流量与设备监控'), findsOneWidget);
      expect(find.text('按需休眠 0 MB'), findsOneWidget);
      expect(find.text('仅管理员'), findsOneWidget);
      expect(find.text('定时 */15 * * * *'), findsOneWidget);

      // Toggle MCP enable switch
      await tester.tap(find.byKey(const ValueKey('mcpEnableSwitch')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('PUT /api/v2/apps/mcp'));
      expect(api.mcpEnabled, isTrue);

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
      expect(find.byKey(const ValueKey('adminMcpControlCard')), findsOneWidget);
      expect(find.text('运行中 24 MB'), findsOneWidget);
    },
  );

  testWidgets(
    'Member AppsCenterPage hides admin MCP controls and opens authorized app',
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
    'AppsCenterPage surfaces launch failure, respects cancelled backup picker, and supports resources/read in MCP debug sheet',
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

      // MCP Debug Sheet supports resources/read with the 3 exact spec URIs.
      await tester.tap(find.byKey(const ValueKey('openMcpDebugSheetButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mcpDebugMethodDropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('resources/read (读取规范资源)').last);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('mcpDebugResourceUriDropdown')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('mcpDebugResourceUriDropdown')),
      );
      await tester.pumpAndSettle();
      expect(find.text('lightisle://specs/plugin-v2'), findsWidgets);
      expect(find.text('lightisle://specs/ui-theme'), findsWidgets);
      expect(find.text('lightisle://specs/automation-v1'), findsWidgets);
      await tester.tap(find.text('lightisle://specs/ui-theme').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('runMcpDebugButton')));
      await tester.pumpAndSettle();
      expect(api.lastMcpDebugBody, {
        'method': 'resources/read',
        'tool': '',
        'uri': 'lightisle://specs/ui-theme',
        'args': <String, dynamic>{},
      });
    },
  );
}
