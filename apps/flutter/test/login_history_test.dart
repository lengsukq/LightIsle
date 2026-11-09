import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/core/login_history_store.dart';
import 'package:lightisle/features/auth/login_page.dart';
import 'package:lightisle/features/settings/settings_page.dart';

import 'client_shell_test.dart' show FixtureApi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'LoginHistoryStore deduplicates by normalized server + username key and caps entries',
    () async {
      const channel = MethodChannel('lightisle/login-history-test');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      String? storedJson;
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        switch (call.method) {
          case 'history.read':
            return storedJson;
          case 'history.write':
            storedJson = (call.arguments as Map)['value'] as String;
            return null;
          case 'history.clear':
            storedJson = null;
            return null;
          default:
            throw PlatformException(code: 'unexpected_method');
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final store = LoginHistoryStore(channel: channel);
      expect(await store.readAll(), isEmpty);

      await store.upsert(
        const LoginHistoryEntry(
          server: 'http://192.168.1.100:16666/',
          username: 'Admin',
          password: 'first-password-123',
          role: 'admin',
          updatedAt: 1000,
        ),
      );
      await store.upsert(
        const LoginHistoryEntry(
          server: 'https://nas.example.com',
          username: 'alice',
          password: 'alice-password-123',
          role: 'member',
          updatedAt: 2000,
        ),
      );
      // Same server + username (different case and trailing slash) updates in place and moves to top.
      final afterUpdate = await store.upsert(
        const LoginHistoryEntry(
          server: 'HTTP://192.168.1.100:16666',
          username: 'admin',
          password: 'updated-password-456',
          role: 'admin',
          updatedAt: 3000,
        ),
      );

      expect(afterUpdate, hasLength(2));
      expect(afterUpdate.first.server, 'http://192.168.1.100:16666');
      expect(afterUpdate.first.username, 'admin');
      expect(afterUpdate.first.password, 'updated-password-456');
      expect(afterUpdate.last.server, 'https://nas.example.com');
      expect(afterUpdate.last.username, 'alice');

      // Updating password via updatePassword preserves entry and updates secret.
      final afterPwdChange = await store.updatePassword(
        'https://nas.example.com/',
        'ALICE',
        'alice-new-password-789',
      );
      expect(afterPwdChange.first.username, 'alice');
      expect(afterPwdChange.first.password, 'alice-new-password-789');

      // Remove one entry, then remove the remaining entry (triggers history.clear).
      final afterRemoveOne = await store.remove(
        'http://192.168.1.100:16666',
        'admin',
      );
      expect(afterRemoveOne, hasLength(1));
      expect(afterRemoveOne.single.username, 'alice');

      final afterRemoveAll = await store.remove(
        'https://nas.example.com',
        'alice',
      );
      expect(afterRemoveAll, isEmpty);
      expect(storedJson, isNull);
      expect(methods, contains('history.clear'));
    },
  );

  testWidgets(
    'LoginPage displays login history with server latency, fills form on tap, and supports one-click login & deletion',
    (tester) async {
      final store = _MemoryLoginHistoryStore([
        const LoginHistoryEntry(
          server: 'http://192.168.1.100:16666',
          username: 'admin',
          password: 'admin-password-123',
          role: 'admin',
          updatedAt: 2000,
        ),
        const LoginHistoryEntry(
          server: 'https://nas.example.com:8443',
          username: 'family',
          password: 'family-password-456',
          role: 'member',
          certificateFingerprint:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          updatedAt: 1000,
        ),
      ]);

      var lanLatencyMs = 9;
      final probedServers = <String>[];
      Future<ServerLatencyResult> fakeProber(
        String serverUrl, {
        String? certificateFingerprint,
      }) async {
        probedServers.add(serverUrl);
        if (serverUrl.contains('192.168.1.100')) {
          return ServerLatencyResult.online(lanLatencyMs);
        }
        return ServerLatencyResult.online(148);
      }

      Map<String, dynamic>? signedInIdentity;
      String? connectedServer;

      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: LoginPage(
            historyStore: store,
            latencyProber: fakeProber,
            apiFactory: (serverUrl, {certificateFingerprint}) {
              connectedServer = serverUrl;
              return _FakeLoginApi(
                serverUrl: serverUrl,
                certificateFingerprint: certificateFingerprint,
              );
            },
            onSignedIn: (api, identity) {
              signedInIdentity = identity;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Both history items and their latency badges are shown.
      expect(find.byKey(const Key('loginHistorySection')), findsOneWidget);
      expect(find.text('admin'), findsOneWidget);
      expect(find.text('family'), findsOneWidget);
      expect(find.text('9 ms'), findsOneWidget);
      expect(find.text('148 ms'), findsOneWidget);

      // Tapping the second entry fills server + username + password + fingerprint.
      const familyKey = 'https://nas.example.com:8443|family';
      await tester.tap(find.byKey(const Key('loginHistoryItem_$familyKey')));
      await tester.pumpAndSettle();

      final fields = find.byType(TextFormField);
      expect(
        tester.widget<TextFormField>(fields.at(0)).controller!.text,
        'https://nas.example.com:8443',
      );
      expect(
        tester.widget<TextFormField>(fields.at(1)).controller!.text,
        'family',
      );
      expect(
        tester.widget<TextFormField>(fields.at(2)).controller!.text,
        'family-password-456',
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const Key('certificateFingerprint')),
            )
            .controller!
            .text,
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      expect(
        find.byKey(const Key('currentServerLatencyBadge')),
        findsOneWidget,
      );

      // Refreshing latencies updates the displayed ms badge.
      lanLatencyMs = 5;
      await tester.tap(find.byKey(const Key('refreshHistoryLatenciesButton')));
      await tester.pumpAndSettle();
      expect(find.text('5 ms'), findsOneWidget);

      // Removing the second entry deletes it from the list.
      await tester.tap(find.byKey(const Key('loginHistoryRemove_$familyKey')));
      await tester.pumpAndSettle();
      expect(find.text('family'), findsNothing);

      // Clicking the quick-login button on the first entry logs in directly.
      const adminKey = 'http://192.168.1.100:16666|admin';
      await tester.tap(
        find.byKey(const Key('loginHistoryQuickLogin_$adminKey')),
      );
      await tester.pumpAndSettle();

      expect(connectedServer, 'http://192.168.1.100:16666');
      expect(signedInIdentity?['username'], 'admin');
    },
  );

  testWidgets(
    'SettingsPage account switcher shows server latencies and switches accounts in one click',
    (tester) async {
      final store = _MemoryLoginHistoryStore([
        const LoginHistoryEntry(
          server: 'http://127.0.0.1:16666',
          username: 'admin',
          password: 'admin-password-123',
          role: 'admin',
          updatedAt: 2000,
        ),
        const LoginHistoryEntry(
          server: 'https://remote.example.com',
          username: 'bob',
          password: 'bob-password-456',
          role: 'member',
          updatedAt: 1000,
        ),
      ]);

      final currentApi = FixtureApi();
      addTearDown(currentApi.close);
      Map<String, dynamic>? switchedIdentity;
      LightIsleApi? switchedApi;
      addTearDown(() => switchedApi?.close());

      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(
            body: SettingsPage(
              api: currentApi,
              identity: const {'id': 1, 'username': 'admin', 'role': 'admin'},
              onLogout: () async {},
              historyStore: store,
              latencyProber: (serverUrl, {certificateFingerprint}) async {
                return serverUrl.contains('127.0.0.1')
                    ? ServerLatencyResult.online(4)
                    : ServerLatencyResult.online(92);
              },
              switchApiFactory: (serverUrl, {certificateFingerprint}) {
                return _FakeLoginApi(
                  serverUrl: serverUrl,
                  certificateFingerprint: certificateFingerprint,
                );
              },
              onSwitchAccount: (api, identity) {
                switchedApi = api;
                switchedIdentity = identity;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('settingsSwitchAccountButton')));
      await tester.pumpAndSettle();

      expect(find.text('切换服务器与账号'), findsOneWidget);
      expect(find.text('当前使用'), findsOneWidget);
      expect(find.text('4 ms'), findsOneWidget);
      expect(find.text('92 ms'), findsOneWidget);

      const bobKey = 'https://remote.example.com|bob';
      await tester.tap(find.byKey(const Key('switchAccountButton_$bobKey')));
      await tester.pumpAndSettle();

      expect(switchedIdentity?['username'], 'bob');
      expect(switchedApi, isNotNull);
    },
  );
}

class _MemoryLoginHistoryStore extends LoginHistoryStore {
  _MemoryLoginHistoryStore(List<LoginHistoryEntry> initial)
    : _items = List<LoginHistoryEntry>.from(initial);

  final List<LoginHistoryEntry> _items;

  @override
  Future<List<LoginHistoryEntry>> readAll() async =>
      List<LoginHistoryEntry>.unmodifiable(_items);

  @override
  Future<List<LoginHistoryEntry>> upsert(LoginHistoryEntry entry) async {
    _items.removeWhere((item) => item.key == entry.key);
    _items.insert(0, entry);
    return List<LoginHistoryEntry>.unmodifiable(_items);
  }

  @override
  Future<List<LoginHistoryEntry>> remove(String server, String username) async {
    final targetKey = LoginHistoryEntry.buildKey(server, username);
    _items.removeWhere((item) => item.key == targetKey);
    return List<LoginHistoryEntry>.unmodifiable(_items);
  }
}

class _FakeLoginApi extends FixtureApi {
  _FakeLoginApi({required this.serverUrl, String? certificateFingerprint})
    : _pin = certificateFingerprint;

  final String serverUrl;
  final String? _pin;

  @override
  bool get authenticated => true;

  @override
  String? get certificateFingerprint => _pin;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/auth/status') {
      return {'configured': true};
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
    if (path == '/api/v2/auth/login' && body is Map) {
      final username = body['username']?.toString() ?? 'user';
      return {
        'id': username == 'admin' ? 1 : 2,
        'username': username,
        'role': username == 'admin' ? 'admin' : 'member',
      };
    }
    return super.send(method, path, body: body, query: query);
  }
}
