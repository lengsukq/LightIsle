import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/core/widgets.dart';
import 'package:lightisle/features/overview/overview_page.dart';
import 'package:lightisle/features/settings/apps_center_helpers.dart';
import 'package:lightisle/features/settings/settings_page.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import 'client_shell_test.dart' show FixtureApi;

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'four dashboard metrics share identical card heights at ${scale}x',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildIsleTheme(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Center(
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final (title, progress) in <(String, double?)>[
                      ('处理器', .42),
                      ('内存', .27),
                      ('系统磁盘', .36),
                      ('网络', null),
                    ])
                      SizedBox(
                        width: 155,
                        child: IsleBentoStatCard(
                          title: title,
                          value: '12.5 GiB 可用',
                          detail: '实时占用与吞吐速率',
                          icon: Icons.speed_rounded,
                          color: Colors.blue,
                          progress: progress,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final cards = find.byType(IsleBentoStatCard);
        expect(cards, findsNWidgets(4));
        final heights = [
          for (var index = 0; index < 4; index++)
            tester.getSize(cards.at(index)).height,
        ];
        expect(
          heights.every((height) => (height - heights.first).abs() < .5),
          isTrue,
          reason:
              'Network card should align without a fabricated usage gauge: $heights',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final (size, scale) in <(Size, double)>[
    (const Size(320, 568), 2),
    (const Size(1024, 800), 1),
  ]) {
    for (final admin in [false, true]) {
      testWidgets(
        '${admin ? 'admin' : 'member'} sees only role-specific settings at $size',
        (tester) async {
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
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: IsleCanvas(child: child!),
              ),
              home: SettingsPage(
                api: api,
                identity: {
                  'username': admin ? 'owner' : 'member',
                  'role': admin ? 'admin' : 'member',
                },
                onLogout: () async {},
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text(admin ? '家庭与存储' : '我的空间'), findsOneWidget);
          expect(find.text('账号与目录授权'), admin ? findsOneWidget : findsNothing);
          expect(find.text('高级排障'), admin ? findsOneWidget : findsNothing);
          expect(find.text('设备诊断与 Key 状态'), findsNothing);
          expect(find.text('安全审计'), findsNothing);
          expect(find.text('上传维护'), findsNothing);
          expect(find.text('我的存储空间'), admin ? findsNothing : findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('连接详情'));
          await tester.pumpAndSettle();
          expect(find.text('当前服务器'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('关闭'));
          await tester.pumpAndSettle();
          if (admin) {
            await tester.scrollUntilVisible(
              find.byKey(const ValueKey('adminTroubleshootingToggle')),
              160,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
            await tester.tap(
              find.byKey(const ValueKey('adminTroubleshootingToggle')),
            );
            await tester.pumpAndSettle();
            expect(find.text('设备诊断与 Key 状态'), findsOneWidget);
            expect(find.text('安全审计'), findsOneWidget);
            expect(find.text('上传维护'), findsOneWidget);
          } else {
            expect(find.text('高级排障'), findsNothing);
            expect(find.text('安全审计'), findsNothing);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
      testWidgets(
        '${admin ? 'admin' : 'member'} dashboard uses role-specific data at $size',
        (tester) async {
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
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: IsleCanvas(child: child!),
              ),
              home: Scaffold(
                body: OverviewPage(
                  api: api,
                  isAdmin: admin,
                  onNavigate: (_) {},
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text(admin ? '这台 Mac' : '我的家庭空间'), findsOneWidget);
          if (admin) {
            expect(api.calls, contains('/api/v2/system'));
            expect(api.calls, contains('/api/v2/tasks'));
            expect(api.calls, isNot(contains('/api/v2/me/storage')));
            expect(
              find.byKey(const ValueKey('dashboardDownloadsEntry')),
              findsNothing,
            );
            expect(
              find.byKey(const ValueKey('dashboardComputerFilesEntry')),
              findsOneWidget,
            );
          } else {
            expect(api.calls, contains('/api/v2/me/storage'));
            expect(api.calls, contains('/api/v2/computer-files/status'));
            expect(api.calls, isNot(contains('/api/v2/system')));
            expect(api.calls, isNot(contains('/api/v2/tasks')));
            expect(
              find.byKey(const ValueKey('dashboardDownloadsEntry')),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('dashboardComputerFilesEntry')),
              findsNothing,
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets(
    'member dashboard shows computer-files entry only when enabled and granted',
    (tester) async {
      final api = _ComputerStatusApi(enabled: true, mode: 'granted');
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          home: Scaffold(
            body: OverviewPage(api: api, isAdmin: false, onNavigate: (_) {}),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('dashboardComputerFilesEntry')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  addHomeAppTileTests();
}

class _ComputerStatusApi extends FixtureApi {
  _ComputerStatusApi({required this.enabled, required this.mode});

  final bool enabled;
  final String mode;

  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query}) {
    if (path == '/api/v2/computer-files/status') {
      calls.add(path);
      return Future.value({'enabled': enabled, 'mode': mode});
    }
    return super.get(path, query: query);
  }
}

class _AppsDashboardApi extends FixtureApi {
  _AppsDashboardApi({required this.appsPayload});

  final List<Map<String, dynamic>> appsPayload;
  final List<String> launchedIds = <String>[];

  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query}) {
    if (path == '/api/v2/apps') {
      calls.add(path);
      return Future.value({'apps': appsPayload});
    }
    return super.get(path, query: query);
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    calls.add('$method $path');
    final match = RegExp(r'^/api/v2/apps/([^/]+)/launch$').firstMatch(path);
    if (method == 'POST' && match != null) {
      final id = Uri.decodeComponent(match.group(1)!);
      launchedIds.add(id);
      return {'launchUrl': '/apps/$id/?ticket=t1', 'launchPath': '/apps/$id/'};
    }
    return const {};
  }
}

void addHomeAppTileTests() {
  test('filterHomeLaunchableApps excludes cron-only apps and sorts ready apps first', () {
    final filtered = filterHomeLaunchableApps([
      {
        'id': 'pending-app',
        'pendingActivation': true,
        'web': {'enabled': true, 'mode': 'on-demand'},
      },
      {
        'id': 'cron-only',
        'web': {'enabled': false, 'mode': 'none'},
      },
      {
        'id': 'network-pulse',
        'web': {'enabled': true, 'mode': 'static'},
      },
    ]);
    expect(filtered.map((e) => e['id']).toList(), [
      'network-pulse',
      'pending-app',
    ]);
  });

  for (final (size, scale) in <(Size, double)>[
    (const Size(320, 568), 2),
    (const Size(1024, 800), 1),
  ]) {
    testWidgets(
      'overview home light-apps adapt role empty states without overflow at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final memberEmptyApi = _AppsDashboardApi(appsPayload: const []);
        addTearDown(memberEmptyApi.close);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildIsleTheme(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: IsleCanvas(child: child!),
            ),
            home: Scaffold(
              body: OverviewPage(
                api: memberEmptyApi,
                isAdmin: false,
                onNavigate: (_) {},
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('家庭轻应用'), findsNothing);
        expect(
          find.byKey(const ValueKey('homeAppsAdminGuideTile')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());

        final adminEmptyApi = _AppsDashboardApi(appsPayload: const []);
        addTearDown(adminEmptyApi.close);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildIsleTheme(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: IsleCanvas(child: child!),
            ),
            home: Scaffold(
              body: OverviewPage(
                api: adminEmptyApi,
                isAdmin: true,
                onNavigate: (_) {},
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('homeAppsAdminGuideTile')),
          150,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(find.text('家庭轻应用'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('homeAppsAdminGuideTile')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'tapping a home light-app tile launches ready apps and guards pending apps',
    (tester) async {
      final memberApi = _AppsDashboardApi(
        appsPayload: [
          {
            'id': 'cron-only',
            'name': '纯定时脚本',
            'web': {'enabled': false, 'mode': 'none'},
          },
          {
            'id': 'network-pulse',
            'name': '轻屿网络脉搏',
            'description': '内置静态轻应用',
            'category': 'network',
            'status': 'static',
            'web': {'enabled': true, 'mode': 'static'},
          },
        ],
      );
      addTearDown(memberApi.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          home: Scaffold(
            body: OverviewPage(
              api: memberApi,
              isAdmin: false,
              onNavigate: (_) {},
              appUrlLauncher: (_, {mode = LaunchMode.platformDefault}) async =>
                  true,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('homeAppTile_cron-only')), findsNothing);
      final tile = find.byKey(const ValueKey('homeAppTile_network-pulse'));
      expect(tile, findsOneWidget);
      expect(find.text('纯静态 0 MB'), findsNothing);
      expect(find.text('网络监控'), findsOneWidget);

      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(memberApi.launchedIds, ['network-pulse']);
      expect(find.byKey(const ValueKey('workbenchBackButton')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());

      final adminApi = _AppsDashboardApi(
        appsPayload: [
          {
            'id': 'pending-app',
            'name': '待激活应用',
            'pendingActivation': true,
            'web': {'enabled': true, 'mode': 'on-demand'},
          },
        ],
      );
      addTearDown(adminApi.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          home: Scaffold(
            body: OverviewPage(
              api: adminApi,
              isAdmin: true,
              onNavigate: (_) {},
              appUrlLauncher: (_, {mode = LaunchMode.platformDefault}) async =>
                  true,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final pendingTile = find.byKey(const ValueKey('homeAppTile_pending-app'));
      expect(pendingTile, findsOneWidget);
      expect(find.text('待首次激活'), findsOneWidget);
      await tester.ensureVisible(pendingTile);
      await tester.tap(pendingTile);
      await tester.pumpAndSettle();
      expect(adminApi.launchedIds, isEmpty);
      expect(find.byKey(const ValueKey('workbenchBackButton')), findsNothing);
      expect(find.byKey(const ValueKey('appCard_pending-app')), findsOneWidget);
      expect(find.text('待首次激活'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
