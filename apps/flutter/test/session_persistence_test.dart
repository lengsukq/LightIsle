import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lightisle/core/background_photo_backup_session.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/core/secure_session_store.dart';
import 'package:lightisle/main.dart';

import 'client_shell_test.dart' show FixtureApi;

const _token = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';
Map<String, dynamic> _snapshot({DateTime? expires}) => {
  'version': 1,
  'server': 'http://127.0.0.1',
  'cookie': _token,
  'expiresAt': (expires ?? DateTime.now().add(const Duration(days: 1)))
      .millisecondsSinceEpoch,
  'certificateFingerprint': null,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('session snapshots are origin, certificate, expiry and token bound', () {
    final snapshot = _snapshot();
    final api = LightIsleApi.fromSessionSnapshot(snapshot);
    addTearDown(api.close);
    expect(api.mediaHeaders['cookie'], 'lightisle_session=$_token');
    expect(api.sessionSnapshot, snapshot);
    expect(api.sessionSnapshot!.containsKey('password'), isFalse);
    expect(
      () =>
          api.restoreSession({...snapshot, 'server': 'http://127.0.0.1:9999'}),
      throwsFormatException,
    );
    expect(
      () =>
          api.restoreSession({...snapshot, 'certificateFingerprint': 'a' * 64}),
      throwsFormatException,
    );
    expect(
      () => api.restoreSession({...snapshot, 'cookie': 'wrong\r\nheader'}),
      throwsFormatException,
    );
    expect(
      () => LightIsleApi.fromSessionSnapshot({
        ...snapshot,
        'server': 'http://public.example.com',
      }),
      throwsArgumentError,
    );
    expect(
      () => LightIsleApi.fromSessionSnapshot(
        _snapshot(expires: DateTime.now().subtract(const Duration(seconds: 1))),
      ),
      throwsA(isA<SavedSessionExpired>()),
    );
  });

  test(
    'vault serializes a delayed clear before the next account save',
    () async {
      const channel = MethodChannel('lightisle/session-vault-test');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final clearGate = Completer<void>();
      final calls = <String>[];
      String? value = 'old';
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'clear') {
          await clearGate.future;
          value = null;
        }
        if (call.method == 'write') {
          value = (call.arguments as Map)['value'] as String;
        }
        if (call.method == 'read') return value;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final store = SecureSessionStore(channel: channel);
      final clear = store.clear();
      final write = store.write(_snapshot());
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['clear']);
      clearGate.complete();
      await Future.wait([clear, write]);
      expect(calls, ['clear', 'write']);
      expect((jsonDecode(value!) as Map)['cookie'], _token);
    },
  );

  test(
    'vault recovers after an operation fails and rejects oversized records',
    () async {
      const channel = MethodChannel('lightisle/session-vault-failure-test');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var fail = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (fail) {
          fail = false;
          throw PlatformException(code: 'locked');
        }
        return call.method == 'read' ? 'x' * 9000 : null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final store = SecureSessionStore(channel: channel);
      await expectLater(store.clear(), throwsA(isA<PlatformException>()));
      await store.clear();
      await expectLater(store.read(), throwsFormatException);
    },
  );

  testWidgets('a new login is saved and restored after the app is recreated', (
    tester,
  ) async {
    final store = _Store(null);
    await tester.pumpWidget(_app(store, (_) => _RestoredApi()));
    await tester.pumpAndSettle();
    await tester.widget<LoginPage>(find.byType(LoginPage)).onSignedIn(
      _RestoredApi(),
      {'username': 'owner', 'role': 'member'},
    );
    await tester.pumpAndSettle();
    expect(store.value?['cookie'], _token);
    expect(find.byType(ClientShell), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app(store, (_) => _RestoredApi()));
    await tester.pumpAndSettle();
    expect(find.byType(ClientShell), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'restart validates saved login with NAS and restores the current account',
    (tester) async {
      final store = _Store(_snapshot());
      final api = _RestoredApi();
      await tester.pumpWidget(_app(store, (_) => api));
      await tester.pumpAndSettle();
      expect(find.byType(ClientShell), findsOneWidget);
      expect(
        tester
            .widget<ClientShell>(find.byType(ClientShell))
            .identity['username'],
        'fresh_name',
      );
      expect(api.calls.where((p) => p == '/api/v2/auth/me').length, 1);
      expect(store.value, isNotNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('offline NAS retains saved login and retry restores it', (
    tester,
  ) async {
    final store = _Store(_snapshot());
    final apis = <_RestoredApi>[];
    var offline = true;
    await tester.pumpWidget(
      _app(store, (_) {
        final api = _RestoredApi()..offline = offline;
        apis.add(api);
        return api;
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('重试连接'), findsOneWidget);
    expect(find.byType(ClientShell), findsNothing);
    expect(store.value, isNotNull);
    offline = false;
    await tester.tap(find.text('重试连接'));
    await tester.pumpAndSettle();
    expect(find.byType(ClientShell), findsOneWidget);
    expect(apis.length, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('revoked session is cleared and returns to login', (
    tester,
  ) async {
    final store = _Store(_snapshot());
    await tester.pumpWidget(
      _app(store, (_) => _RestoredApi()..unauthorized = true),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.text('登录已过期或失效，请重新登录。'), findsOneWidget);
    expect(store.value, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('expired local session is rejected before a request', (
    tester,
  ) async {
    final store = _Store(
      _snapshot(expires: DateTime.now().subtract(const Duration(days: 1))),
    );
    await tester.pumpWidget(
      LightIsleApp(
        sessionStore: store,
        photoBackupSession: BackgroundPhotoBackupSession(enabled: false),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);
    expect(store.value, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('logout clears the vault even when NAS cannot acknowledge it', (
    tester,
  ) async {
    final store = _Store(_snapshot());
    final api = _RestoredApi()..failLogout = true;
    await tester.pumpWidget(_app(store, (_) => api));
    await tester.pumpAndSettle();
    await tester.widget<ClientShell>(find.byType(ClientShell)).onLogout();
    await tester.pumpAndSettle();
    expect(store.value, isNull);
    expect(find.byType(LoginPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      _app(
        store,
        (_) => throw StateError('Must not restore a signed-out account'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('protected request invalidation clears the saved session', (
    tester,
  ) async {
    final store = _Store(_snapshot());
    final api = _RestoredApi();
    await tester.pumpWidget(_app(store, (_) => api));
    await tester.pumpAndSettle();
    api.onUnauthorized!();
    await tester.pumpAndSettle();
    expect(store.value, isNull);
    expect(find.byType(LoginPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('vault write failure while restoring has a recovery screen', (
    tester,
  ) async {
    final store = _Store(_snapshot())..failWrite = true;
    await tester.pumpWidget(_app(store, (_) => _RestoredApi()));
    await tester.pumpAndSettle();
    expect(find.text('重试连接'), findsOneWidget);
    expect(find.byType(ClientShell), findsNothing);
    store.failWrite = false;
    await tester.tap(find.text('重试连接'));
    await tester.pumpAndSettle();
    expect(find.byType(ClientShell), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed native binding rolls back a newly saved login', (
    tester,
  ) async {
    final store = _Store(null);
    await tester.pumpWidget(
      LightIsleApp(
        sessionStore: store,
        restoreApiFactory: (_) => throw StateError('Must not restore a failed login'),
        photoBackupSession: _FailingPhotoBackupSession(),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      tester.widget<LoginPage>(find.byType(LoginPage)).onSignedIn(
        _RestoredApi(),
        {'username': 'owner', 'role': 'member'},
      ),
      throwsA(isA<PlatformException>()),
    );
    await tester.pumpAndSettle();
    expect(store.value, isNull);
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.byType(ClientShell), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed native rebind preserves an existing session for retry', (
    tester,
  ) async {
    final store = _Store(_snapshot());
    await tester.pumpWidget(
      LightIsleApp(
        sessionStore: store,
        restoreApiFactory: (_) => _RestoredApi(),
        photoBackupSession: _FailingPhotoBackupSession(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('重试连接'), findsOneWidget);
    expect(store.value?['cookie'], _token);
    expect(find.byType(ClientShell), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('switching accounts clears previous-process backup even offline', (
    tester,
  ) async {
    final store = _Store(_snapshot());
    final backup = _ForgetPhotoBackupSession();
    await tester.pumpWidget(
      LightIsleApp(
        sessionStore: store,
        restoreApiFactory: (_) => _RestoredApi()..offline = true,
        photoBackupSession: backup,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('使用其他账号或服务器'), findsOneWidget);
    await tester.tap(find.text('使用其他账号或服务器'));
    await tester.pumpAndSettle();
    expect(backup.forgetCalls, 1);
    expect(store.value, isNull);
    expect(find.byType(LoginPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sign-out is not shown as successful if native revocation fails', (
    tester,
  ) async {
    final store = _Store(_snapshot());
    final backup = _ForgetPhotoBackupSession()..failForget = true;
    await tester.pumpWidget(
      LightIsleApp(
        sessionStore: store,
        restoreApiFactory: (_) => _RestoredApi(),
        photoBackupSession: backup,
      ),
    );
    await tester.pumpAndSettle();
    await tester.widget<ClientShell>(find.byType(ClientShell)).onLogout();
    await tester.pumpAndSettle();
    expect(find.byType(ClientShell), findsOneWidget);
    expect(store.value, isNotNull);
    backup.failForget = false;
    await tester.widget<ClientShell>(find.byType(ClientShell)).onLogout();
    await tester.pumpAndSettle();
    expect(store.value, isNull);
    expect(find.byType(LoginPage), findsOneWidget);
    expect(backup.forgetCalls, 2);
    await tester.pumpWidget(const SizedBox());
  });
}

class _ForgetPhotoBackupSession extends BackgroundPhotoBackupSession {
  _ForgetPhotoBackupSession() : super(enabled: false);
  bool failForget = false;
  int forgetCalls = 0;

  @override
  Future<void> forgetLocalSession() async {
    forgetCalls++;
    if (failForget) {
      throw PlatformException(code: 'background_session_end_failed');
    }
  }
}

class _FailingPhotoBackupSession extends BackgroundPhotoBackupSession {
  _FailingPhotoBackupSession() : super(enabled: false);

  @override
  Future<String?> replaceSession({
    required String server,
    required String cookie,
    required String username,
  }) async {
    throw PlatformException(code: 'background_session_bind_failed');
  }
}

LightIsleApp _app(
  _Store store,
  LightIsleApi Function(Map<String, dynamic>) factory,
) => LightIsleApp(
  sessionStore: store,
  restoreApiFactory: factory,
  photoBackupSession: BackgroundPhotoBackupSession(enabled: false),
);

class _Store extends SecureSessionStore {
  _Store(this.value);
  Map<String, dynamic>? value;
  bool failWrite = false;
  @override
  Future<Map<String, dynamic>?> read() async => value;
  @override
  Future<void> write(Map<String, dynamic> snapshot) async {
    if (failWrite) throw PlatformException(code: 'locked');
    value = snapshot;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

class _RestoredApi extends FixtureApi {
  bool offline = false, unauthorized = false, failLogout = false;
  @override
  bool get authenticated => true;
  @override
  Map<String, dynamic> get sessionSnapshot => _snapshot();
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/auth/me') {
      calls.add(path);
      if (offline) {
        throw const LightIsleApiException(
          code: 'network_error',
          message: '无法连接服务器。',
        );
      }
      if (unauthorized) {
        throw const LightIsleApiException(
          code: 'authentication_required',
          statusCode: 401,
          message: '登录已失效。',
        );
      }
      return {'id': 7, 'username': 'fresh_name', 'role': 'member'};
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
    if (failLogout) {
      throw const LightIsleApiException(
        code: 'network_error',
        message: '无法连接服务器。',
      );
    }
    return {};
  }
}
