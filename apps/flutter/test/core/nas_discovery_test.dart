import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/core/nas_discovery.dart';

const _channel = MethodChannel('test/lightisle-discovery');

Map<String, Object?> _candidate({
  String name = 'Living Room NAS',
  String host = '192.168.1.24',
  int port = 8443,
  String? url,
}) => {
  'name': name,
  'host': host,
  'port': port,
  'url': url ?? 'https://$host:$port',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  group('NasDiscoveryService', () {
    test('returns only validated local HTTPS candidates', () async {
      messenger.setMockMethodCallHandler(_channel, (call) async {
        expect(call.method, 'discover');
        final arguments = call.arguments as Map<Object?, Object?>;
        expect(arguments['timeoutMs'], 10000);
        expect(
          (arguments['requestId'] as String).length,
          greaterThanOrEqualTo(16),
        );
        return {
          'servers': [
            _candidate(name: '  NAS\nOne  '),
            _candidate(
              name: 'IPv6 NAS',
              host: 'fd00::24',
              url: 'https://[fd00::24]:8443',
            ),
            _candidate(
              name: 'Link-local NAS',
              host: 'fe80::24%wlan0',
              url: 'https://[fe80::24%25wlan0]:8443',
            ),
            _candidate(name: 'Remote', host: '203.0.113.9'),
            _candidate(
              name: 'DNS',
              host: 'nas.example.com',
              url: 'https://nas.example.com:8443',
            ),
            _candidate(name: 'HTTP', url: 'http://192.168.1.24:8443'),
            _candidate(name: 'Path', url: 'https://192.168.1.24:8443/login'),
          ],
        };
      });

      final servers = await NasDiscoveryService(channel: _channel).discover();

      expect(servers, hasLength(3));
      expect(servers.first.name, 'NASOne');
      expect(servers.first.address, 'https://192.168.1.24:8443');
      expect(servers.last.address, 'https://[fe80::24%25wlan0]:8443');
    });

    test('returns an empty list when no service is discovered', () async {
      messenger.setMockMethodCallHandler(
        _channel,
        (_) async => {'servers': <Object?>[]},
      );

      expect(await NasDiscoveryService(channel: _channel).discover(), isEmpty);
    });

    test('caps discovery results at 16 candidates', () async {
      messenger.setMockMethodCallHandler(
        _channel,
        (_) async => {
          'servers': List.generate(20, (index) {
            final host = '10.0.0.${index + 1}';
            return _candidate(host: host, url: 'https://$host:8443');
          }),
        },
      );

      final servers = await NasDiscoveryService(channel: _channel).discover();

      expect(servers, hasLength(16));
    });

    test('scoped IPv6 origin is accepted by LightIsleApi', () {
      final uri = Uri.tryParse('https://[fe80::24%25wlan0]:8443');
      expect(uri, isNotNull);

      final api = LightIsleApi('https://[fe80::24%25wlan0]:8443');
      addTearDown(api.close);
      expect(api.uri('/api/v1/auth/status').origin, uri!.origin);
    });

    test('maps native discovery failures to a user-readable error', () async {
      messenger.setMockMethodCallHandler(_channel, (_) async {
        throw PlatformException(code: 'discovery_timeout');
      });

      await expectLater(
        NasDiscoveryService(channel: _channel).discover(),
        throwsA(
          isA<NasDiscoveryException>().having(
            (error) => error.message,
            'message',
            contains('10 秒内'),
          ),
        ),
      );
    });

    test('maps local-network permission denial without a platform-specific message', () async {
      messenger.setMockMethodCallHandler(_channel, (_) async {
        throw PlatformException(code: 'discovery_permission_denied');
      });

      await expectLater(
        NasDiscoveryService(channel: _channel).discover(),
        throwsA(
          isA<NasDiscoveryException>().having(
            (error) => error.message,
            'message',
            contains('系统未允许局域网发现'),
          ),
        ),
      );
    });

    test('cancel invalidates a late native result', () async {
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

      final service = NasDiscoveryService(channel: _channel);
      final discovery = service.discover();
      await discoverStarted.future;
      await service.cancel();
      response.complete({
        'servers': [_candidate()],
      });

      expect(cancelCalled, isTrue);
      await expectLater(discovery, throwsA(isA<NasDiscoveryCancelled>()));
    });
  });
}
