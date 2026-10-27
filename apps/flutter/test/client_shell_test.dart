import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/main.dart';
import 'package:lightisle/features/overview/overview_page.dart';
import 'package:lightisle/features/settings/settings_page.dart';

const _discoveryChannel = MethodChannel('lightisle/discovery');

class FixtureApi extends LightIsleApi {
  FixtureApi() : super('http://127.0.0.1:16666');
  final calls = <String>[];
  bool failSystem = false;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    calls.add(path);
    return switch (path) {
      '/api/v2/system' =>
        failSystem
            ? throw const LightIsleApiException(
                code: 'network_error',
                message: '连接失败',
              )
            : {
                'hostname': '我的 Mac NAS',
                'architecture': 'arm64',
                'cpuCount': 8,
                'cpuPercent': null,
                'memoryTotal': 16000000000,
                'memoryUsed': 8000000000,
                'diskTotal': 1000000000000,
                'diskFree': 500000000000,
                'volumes': [],
              },
      '/api/v2/roots' => {'roots': []},
      '/api/v2/me/storage' => {
        'userId': 7,
        'locations': [],
        'enforcement': 'pending',
        'usageComplete': false,
      },
      '/api/v2/photos/private-albums' => {'albums': []},
      '/api/v2/files/root' => {'name': '共享文件'},
      '/api/v2/files' => {'entries': [], 'nextCursor': '', 'canWrite': false},
      '/api/v2/photos' => {'assets': [], 'nextCursor': 0},
      '/api/v2/photos/albums' => {'albums': []},
      '/api/v2/cinema' => {'films': [], 'nextCursor': 0},
      '/api/v2/photos/status' || '/api/v2/cinema/status' => {
        'status': {'running': false},
        'count': 0,
      },
      '/api/v2/tasks' => {'tasks': []},
      '/api/v2/tasks/history' => {'runs': [], 'nextCursor': ''},
      '/api/v2/users' => {
        'users': [
          {'id': 1, 'username': 'owner', 'role': 'admin', 'enabled': true},
        ],
      },
      _ => {},
    };
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'discovery only fills the address and keeps certificate pins scoped by port',
    (tester) async {
      const oldOrigin = 'https://192.168.1.31:8443';
      const discoveredOrigin = 'https://192.168.1.31:9443';
      final oldPin = List.filled(64, 'a').join();
      SharedPreferences.setMockInitialValues({
        'lightisle.server': oldOrigin,
        'lightisle.certificatePin.$oldOrigin': oldPin,
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_discoveryChannel, (call) async {
        expect(call.method, 'discover');
        return {
          'servers': [
            {
              'name': 'Office NAS',
              'host': '192.168.1.31',
              'port': 9443,
              'url': discoveredOrigin,
            },
          ],
        };
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(_discoveryChannel, null),
      );

      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = previousPlatform);

      final httpOverrides = _CountingHttpOverrides();
      HttpOverrides.global = httpOverrides;
      addTearDown(() => HttpOverrides.global = null);

      var signedIn = false;
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: isleTheme(Brightness.light),
          home: LoginPage(
            onSignedIn: (_, _) {
              signedIn = true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('nasDiscoveryButton')));
      await tester.pumpAndSettle();
      expect(signedIn, isFalse);
      expect(find.text('Office NAS'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('nasDiscoveryResult_0')));
      await tester.tap(find.byKey(const Key('nasDiscoveryResult_0')));
      await tester.pumpAndSettle();
      expect(find.text('Office NAS'), findsNothing);

      final fields = find.byType(TextFormField);
      expect(
        tester.widget<TextFormField>(fields.at(0)).controller!.text,
        discoveredOrigin,
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const Key('certificateFingerprint')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(find.byKey(const Key('requireHttpsSwitch')), findsNothing);
      expect(find.textContaining('支持 HTTPS 与可信局域网 HTTP'), findsOneWidget);
      expect(signedIn, isFalse);
      expect(httpOverrides.clientCreations, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = previousPlatform;
      HttpOverrides.global = null;
    },
  );
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('login stays usable 320×480, scale $scale, $brightness', (
        tester,
      ) async {
        tester.view.reset();
        tester.view.physicalSize = const Size(320, 480);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: isleTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: LoginPage(onSignedIn: (_, _) {}),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('连接并登录'));
        await tester.tap(find.text('连接并登录'));
        await tester.pumpAndSettle();
        expect(find.text('请输入 Mac 管理端显示的连接地址'), findsOneWidget);
        expect(find.text('请输入用户名'), findsOneWidget);
        expect(find.text('请输入密码'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('certificate fingerprint stays scoped to its HTTPS origin', (
    tester,
  ) async {
    final fingerprint = List.filled(64, 'a').join();
    SharedPreferences.setMockInitialValues({
      'lightisle.server': 'https://192.168.1.4:8443',
      'lightisle.certificatePin.https://192.168.1.4:8443': fingerprint,
    });
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: isleTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: LoginPage(onSignedIn: (_, _) {}),
      ),
    );
    await tester.pumpAndSettle();
    final security = find.text('连接安全设置 · 已记住证书指纹');
    await tester.ensureVisible(security);
    await tester.tap(security);
    await tester.pumpAndSettle();
    final pin = find.byKey(const Key('certificateFingerprint'));
    expect(tester.widget<TextFormField>(pin).controller!.text, fingerprint);
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'https://192.168.1.5:8443',
    );
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(pin).controller!.text, isEmpty);
    await tester.enterText(find.byType(TextFormField).at(1), 'owner');
    await tester.enterText(find.byType(TextFormField).at(2), 'a test password');
    await tester.enterText(pin, 'abcd');
    await tester.ensureVisible(find.text('连接并登录'));
    await tester.tap(find.text('连接并登录'));
    await tester.pumpAndSettle();
    expect(find.text('请输入完整的 64 位 SHA-256 指纹'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'member can reach all five sections without admin requests at 2× text',
    (tester) async {
      final api = FixtureApi();
      addTearDown(api.close);
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: isleTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: ClientShell(
            api: api,
            identity: const {'username': 'viewer', 'role': 'member'},
            onLogout: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final label in ['文件', '图库', '影视', '设置', '概览']) {
        await tester.tap(find.widgetWithText(NavigationDestination, label));
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: 'Overflow or lifecycle error in $label',
        );
      }
      expect(
        api.calls.where(
          (p) =>
              p.contains('/tasks') ||
              p.contains('/users') ||
              p.contains('/admin/'),
        ),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
  testWidgets('desktop uses rail and administrator can read task history', (
    tester,
  ) async {
    final api = FixtureApi();
    addTearDown(api.close);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: isleTheme(Brightness.dark),
        home: ClientShell(
          api: api,
          identity: const {'username': 'owner', 'role': 'admin'},
          onLogout: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('查看历史'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(OverviewPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看历史'));
    await tester.pumpAndSettle();
    expect(find.text('还没有任务历史。'), findsOneWidget);
    expect(api.calls, contains('/api/v2/tasks/history'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets('new account rejects passwords shorter than backend minimum', (
    tester,
  ) async {
    final api = FixtureApi();
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(home: AccountsPage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建账号'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'new.member');
    await tester.enterText(find.byType(TextFormField).at(1), '12345678901');
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '创建账号'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('密码需为 12–256 位'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _CountingHttpOverrides extends HttpOverrides {
  var clientCreations = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    clientCreations++;
    return super.createHttpClient(context);
  }
}
