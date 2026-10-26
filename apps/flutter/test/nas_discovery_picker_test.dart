import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/nas_discovery.dart';
import 'package:lightisle/features/auth/nas_discovery_picker.dart';

const _channel = MethodChannel('test/lightisle-discovery-picker');

Map<String, Object?> _candidate() => {
  'name': 'Office NAS',
  'host': '192.168.1.31',
  'port': 8443,
  'url': 'https://192.168.1.31:8443',
};

Map<String, Object?> _httpCandidate() => {
  'name': 'HTTP-only Home NAS',
  'host': '192.168.1.42',
  'port': 16666,
  'scheme': 'http',
  'url': 'http://192.168.1.42:16666',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  testWidgets('selection only returns the address to the caller', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(
      _channel,
      (_) async => {
        'servers': [_candidate()],
      },
    );
    NasDiscoveryServer? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NasDiscoveryPicker(
            service: NasDiscoveryService(channel: _channel),
            platformOverride: TargetPlatform.android,
            onSelected: (server) => selected = server,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('nasDiscoveryButton')));
    await tester.pumpAndSettle();

    expect(selected, isNull);
    expect(find.textContaining('选择不会自动登录'), findsOneWidget);
    await tester.tap(find.byKey(const Key('nasDiscoveryResult_0')));
    await tester.pumpAndSettle();

    expect(selected?.address, 'https://192.168.1.31:8443');
    expect(selected?.name, 'Office NAS');
  });

  testWidgets('explicitly advertised private HTTP is displayed as unencrypted', (tester) async {
    messenger.setMockMethodCallHandler(
      _channel, (_) async => {'servers': [_httpCandidate()]},
    );
    NasDiscoveryServer? selected;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: NasDiscoveryPicker(
        service: NasDiscoveryService(channel: _channel),
        platformOverride: TargetPlatform.android,
        onSelected: (server) => selected = server,
      )),
    ));
    await tester.tap(find.byKey(const Key('nasDiscoveryButton')));
    await tester.pumpAndSettle();
    expect(find.text('未加密'), findsOneWidget);
    await tester.tap(find.byKey(const Key('nasDiscoveryResult_0')));
    await tester.pumpAndSettle();
    expect(selected?.address, 'http://192.168.1.42:16666');
  });

  testWidgets('forged insecure URL and public HTTP are never suggested', (tester) async {
    messenger.setMockMethodCallHandler(
      _channel,
      (_) async => {
        'servers': [
          {..._httpCandidate(), 'scheme': 'https'},
          {..._httpCandidate(), 'host': '8.8.8.8', 'url': 'http://8.8.8.8:16666'},
        ],
      },
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: NasDiscoveryPicker(
        service: NasDiscoveryService(channel: _channel),
        platformOverride: TargetPlatform.android,
        onSelected: (_) {},
      )),
    ));
    await tester.tap(find.byKey(const Key('nasDiscoveryButton')));
    await tester.pumpAndSettle();
    expect(find.textContaining('发现结果不是可用'), findsOneWidget);
  });

  testWidgets('shows an empty result and keeps manual address entry possible', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(
      _channel,
      (_) async => {'servers': <Object?>[]},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NasDiscoveryPicker(
            service: NasDiscoveryService(channel: _channel),
            platformOverride: TargetPlatform.android,
            onSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('nasDiscoveryButton')));
    await tester.pumpAndSettle();

    expect(find.text('没有发现 LightIsle NAS。你仍可手动输入服务器地址。'), findsOneWidget);
    expect(find.text('重新搜索'), findsOneWidget);
  });

  testWidgets('shows a native failure in the picker', (tester) async {
    messenger.setMockMethodCallHandler(_channel, (_) async {
      throw PlatformException(code: 'discovery_timeout');
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NasDiscoveryPicker(
            service: NasDiscoveryService(channel: _channel),
            platformOverride: TargetPlatform.android,
            onSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('nasDiscoveryButton')));
    await tester.pumpAndSettle();

    expect(find.textContaining('10 秒内没有发现'), findsOneWidget);
    expect(find.text('重新搜索'), findsOneWidget);
  });

  testWidgets('cancel ignores a later discovery result', (tester) async {
    final response = Completer<Object?>();
    final discoverStarted = Completer<void>();
    var cancelCalled = false;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'discover') {
        discoverStarted.complete();
        return response.future;
      }
      if (call.method == 'cancel') {
        cancelCalled = true;
        return true;
      }
      fail('Unexpected method ${call.method}');
    });
    NasDiscoveryServer? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NasDiscoveryPicker(
            service: NasDiscoveryService(channel: _channel),
            platformOverride: TargetPlatform.android,
            onSelected: (server) => selected = server,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('nasDiscoveryButton')));
    await tester.pump();
    await discoverStarted.future;
    await tester.tap(find.byKey(const Key('nasDiscoveryCancel')));
    await tester.pumpAndSettle();
    response.complete({
      'servers': [_candidate()],
    });
    await tester.pump();

    expect(cancelCalled, isTrue);
    expect(selected, isNull);
  });

  testWidgets(
    'shows discovery on iOS and fills the address without logging in',
    (tester) async {
      messenger.setMockMethodCallHandler(
        _channel,
        (_) async => {
          'servers': [_candidate()],
        },
      );
      NasDiscoveryServer? selected;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NasDiscoveryPicker(
              service: NasDiscoveryService(channel: _channel),
              platformOverride: TargetPlatform.iOS,
              onSelected: (server) => selected = server,
            ),
          ),
        ),
      );

      expect(find.byKey(const Key('nasDiscoveryButton')), findsOneWidget);
      await tester.tap(find.byKey(const Key('nasDiscoveryButton')));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      await tester.tap(find.byKey(const Key('nasDiscoveryResult_0')));
      await tester.pumpAndSettle();
      expect(selected?.address, 'https://192.168.1.31:8443');
    },
  );

  testWidgets('does not show the entry on non-mobile platforms', (
    tester,
  ) async {
    var discoverCalls = 0;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      discoverCalls++;
      return {'servers': <Object?>[]};
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NasDiscoveryPicker(
            service: NasDiscoveryService(channel: _channel),
            platformOverride: TargetPlatform.macOS,
            onSelected: (_) {},
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('nasDiscoveryButton')), findsNothing);
    expect(discoverCalls, 0);
  });

  testWidgets('disables discovery while login is busy', (tester) async {
    var discoverCalls = 0;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      discoverCalls++;
      return {'servers': <Object?>[]};
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NasDiscoveryPicker(
            service: NasDiscoveryService(channel: _channel),
            platformOverride: TargetPlatform.android,
            enabled: false,
            onSelected: (_) {},
          ),
        ),
      ),
    );

    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('nasDiscoveryButton')))
          .onPressed,
      isNull,
    );
    expect(discoverCalls, 0);
  });

  testWidgets('dialog fits a narrow, short viewport at 200 percent text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    messenger.setMockMethodCallHandler(
      _channel,
      (_) async => {
        'servers': List.generate(5, (index) {
          final host = '192.168.1.${31 + index}';
          return {
            'name': 'Office NAS $index',
            'host': host,
            'port': 8443,
            'url': 'https://$host:8443',
          };
        }),
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: NasDiscoveryPicker(
            service: NasDiscoveryService(channel: _channel),
            platformOverride: TargetPlatform.android,
            onSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('nasDiscoveryButton')));
    await tester.pumpAndSettle();

    expect(find.text('Office NAS 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
