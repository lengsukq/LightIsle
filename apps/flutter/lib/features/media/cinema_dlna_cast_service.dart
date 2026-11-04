import '../../core/lightisle_api.dart';
import 'dlna_cast.dart';

/// Manages the security-sensitive transition from an authenticated NAS file to
/// a temporary public DLNA URL. Device discovery and user consent stay in UI.
/// The returned session owns the temporary link until stop() revokes it.
class CinemaDlnaCastService {
  const CinemaDlnaCastService(this.api);

  final LightIsleApi api;

  Future<DlnaCastSession> start({
    required DlnaCast cast,
    required DlnaRenderer renderer,
    required String filmPath,
    required bool Function() stillCurrent,
  }) async {
    if (!RegExp(r'\.(mp4|m4v)$', caseSensitive: false).hasMatch(filmPath)) {
      throw StateError('DLNA 目前仅支持 MP4/M4V 原始文件。');
    }
    if (!stillCurrent()) {
      throw StateError('影片或存储目录已变化，投屏已取消。');
    }

    String? shareId;
    var retained = false;
    try {
      final share = await api.send(
        'POST',
        '/api/v2/file-shares',
        body: {'path': filmPath, 'hours': 1},
      );
      final token = share['token']?.toString() ?? '';
      final payload = share['share'];
      shareId = payload is Map ? payload['id']?.toString() : null;
      if (token.isEmpty || shareId == null || shareId.isEmpty) {
        throw const FormatException('服务器未返回可撤销的分享链接');
      }
      final url = api.publicFileShareUri(token);
      if (url.host == '127.0.0.1' ||
          url.host == 'localhost' ||
          url.host == '::1') {
        throw StateError('需要使用电视能够访问的 NAS 局域网地址登录。');
      }
      if (!stillCurrent()) {
        throw StateError('影片或存储目录已变化，投屏已取消。');
      }
      await cast.play(renderer, url);
      if (!stillCurrent()) {
        throw StateError('影片或存储目录已变化，投屏已取消。');
      }
      final session = DlnaCastSession(
        api: api,
        cast: cast,
        renderer: renderer,
        shareId: shareId,
      );
      retained = true;
      return session;
    } finally {
      if (!retained) {
        if (shareId != null && shareId.isNotEmpty) {
          try {
            await api.send(
              'DELETE',
              '/api/v2/file-shares/${Uri.encodeComponent(shareId)}',
            );
          } on Object {
            // Best-effort rollback; the share also expires in at most 1 hour.
          }
        }
        cast.close();
      }
    }
  }
}
