import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/dlna_cast.dart';

class _RevokeApi extends LightIsleApi {
  _RevokeApi() : super('http://127.0.0.1');

  int revokeCount = 0;
  bool failFirstRevoke = false;

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    if (method == 'DELETE' && path == '/api/v2/file-shares/test-id') {
      revokeCount++;
      if (failFirstRevoke && revokeCount == 1) {
        throw StateError('NAS temporarily disconnected');
      }
      return {};
    }
    throw StateError('unexpected request');
  }
}

void main() {
  test('only normal numeric private IPv4 device descriptions are accepted', () {
    for (final good in [
      'http://192.168.31.5:1400/desc.xml',
      'http://10.8.1.2/desc.xml',
      'http://172.16.0.1/device',
      'http://172.31.255.255/device',
    ]) {
      expect(
        DlnaRenderer.isLocalDeviceUri(Uri.parse(good)),
        isTrue,
        reason: good,
      );
    }
    for (final bad in [
      'http://127.0.0.1:1400/',
      'http://169.254.1.5/',
      'http://8.8.8.8/',
      'http://172.32.0.5/',
      'http://192.168.1.1.evil.com/',
      'http://2130706433/',
      'http://0x7f000001/',
      'http://user:pass@192.168.1.10/',
      'https://192.168.1.20/',
      'http://[::1]/',
    ]) {
      expect(
        DlnaRenderer.isLocalDeviceUri(Uri.parse(bad)),
        isFalse,
        reason: bad,
      );
    }
  });

  test(
    'UPnP SOAP control path cannot redirect to a different host or port',
    () {
      final source = Uri.parse('http://192.168.31.12:1400/root/desc.xml');
      expect(
        DlnaRenderer.safeControlUri(source, '/upnp/AVTransport').toString(),
        'http://192.168.31.12:1400/upnp/AVTransport',
      );
      expect(DlnaRenderer.safeControlUri(source, 'http://8.8.8.8:80/'), isNull);
      expect(
        DlnaRenderer.safeControlUri(source, 'http://192.168.31.12:9000/api'),
        isNull,
      );
      expect(DlnaRenderer.safeControlUri(source, '../../admin'), isNull);
    },
  );

  test('stopping cast revokes share even when device is unreachable', () async {
    final api = _RevokeApi();
    final dlna = DlnaCast();
    final session = DlnaCastSession(
      api: api,
      cast: dlna,
      renderer: DlnaRenderer(
        name: 'untrusted test device',
        controlUri: Uri.parse('http://127.0.0.1/'),
      ),
      shareId: 'test-id',
    );
    await expectLater(session.stop(), throwsStateError);
    expect(api.revokeCount, 1);
    await session.stop();
    expect(api.revokeCount, 1);
    api.close();
  });

  test(
    'failed revoke keeps DLNA session retryable, later retry invalidates link',
    () async {
      final api = _RevokeApi()..failFirstRevoke = true;
      final session = DlnaCastSession(
        api: api,
        cast: DlnaCast(),
        renderer: DlnaRenderer(
          name: 'offline TV',
          controlUri: Uri.parse('http://127.0.0.1/'),
        ),
        shareId: 'test-id',
      );
      await expectLater(session.stop(), throwsStateError);
      expect(session.revoked, isFalse);
      expect(api.revokeCount, 1);
      await expectLater(
        session.stop(),
        throwsStateError,
        reason: 'TV still rejects Stop but server revoke must succeed',
      );
      expect(session.revoked, isTrue);
      expect(api.revokeCount, 2);
      await session.stop();
      expect(api.revokeCount, 2);
      api.close();
    },
  );
}
