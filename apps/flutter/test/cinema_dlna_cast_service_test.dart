import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/cinema_dlna_cast_service.dart';
import 'package:lightisle/features/media/dlna_cast.dart';

class _ShareApi extends LightIsleApi {
  _ShareApi(super.serverUrl) : super(allowInsecureHttp: true);

  final sent = <(String, String, Object?)>[];
  void Function()? onCreate;

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    sent.add((method, path, body));
    if (method == 'POST') {
      onCreate?.call();
      return {
        'token': 'temporary-token',
        'share': {'id': 'share-11'},
      };
    }
    return {};
  }
}

class _Cast extends DlnaCast {
  Uri? playingUrl;
  bool failPlayback = false;
  bool closed = false;
  int stopCalls = 0;

  @override
  Future<void> play(DlnaRenderer renderer, Uri shareUrl) async {
    playingUrl = shareUrl;
    if (failPlayback) throw StateError('TV is offline');
  }

  @override
  Future<void> stop(DlnaRenderer renderer) async {
    stopCalls++;
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  test('temporary share is held only until the session stops', () async {
    final api = _ShareApi('http://192.168.1.20:16666');
    addTearDown(api.close);
    final cast = _Cast();
    final session = await CinemaDlnaCastService(api).start(
      cast: cast,
      renderer: DlnaRenderer(
        name: 'LAN TV',
        controlUri: Uri(scheme: 'http', host: '192.168.1.50'),
      ),
      filmPath: 'Movies/a.mp4',
      stillCurrent: () => true,
    );
    expect(cast.playingUrl?.path, contains('/public/file/temporary-token'));
    expect(api.sent.single.$3, {'path': 'Movies/a.mp4', 'hours': 1});
    expect(cast.closed, false);
    await session.stop();
    expect(cast.stopCalls, 1);
    expect(session.revoked, true);
    expect(cast.closed, true);
    expect(api.sent.last.$2, '/api/v2/file-shares/share-11');
  });

  test('failed TV playback revokes the one-hour link', () async {
    final api = _ShareApi('http://192.168.1.20:16666');
    addTearDown(api.close);
    final cast = _Cast()..failPlayback = true;
    await expectLater(
      CinemaDlnaCastService(api).start(
        cast: cast,
        renderer: DlnaRenderer(
          name: 'LAN TV',
          controlUri: Uri.parse('http://192.168.1.50/ctl'),
        ),
        filmPath: 'Movies/a.mp4',
        stillCurrent: () => true,
      ),
      throwsStateError,
    );
    expect(api.sent.map((r) => r.$1), ['POST', 'DELETE']);
    expect(cast.closed, true);
  });

  test(
    'changing physical root before playback revokes created share',
    () async {
      final api = _ShareApi('http://192.168.1.20:16666');
      addTearDown(api.close);
      var current = true;
      api.onCreate = () => current = false;
      final cast = _Cast();
      await expectLater(
        CinemaDlnaCastService(api).start(
          cast: cast,
          renderer: DlnaRenderer(
            name: 'LAN TV',
            controlUri: Uri.parse('http://192.168.1.50/ctl'),
          ),
          filmPath: 'Movies/a.m4v',
          stillCurrent: () => current,
        ),
        throwsStateError,
      );
      expect(cast.playingUrl, isNull);
      expect(api.sent.map((r) => r.$1), ['POST', 'DELETE']);
      expect(cast.closed, true);
    },
  );

  test('loopback NAS URL never reaches the renderer', () async {
    final api = _ShareApi('http://127.0.0.1:16666');
    addTearDown(api.close);
    final cast = _Cast();
    await expectLater(
      CinemaDlnaCastService(api).start(
        cast: cast,
        renderer: DlnaRenderer(
          name: 'LAN TV',
          controlUri: Uri.parse('http://192.168.1.50/ctl'),
        ),
        filmPath: 'Movies/a.mp4',
        stillCurrent: () => true,
      ),
      throwsStateError,
    );
    expect(cast.playingUrl, isNull);
    expect(api.sent.map((r) => r.$1), ['POST', 'DELETE']);
  });
}
