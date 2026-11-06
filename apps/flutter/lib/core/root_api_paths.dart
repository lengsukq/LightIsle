import 'api_models.dart';

/// Centralizes the v2 root-routing contract used by the authenticated API.
/// Public capabilities must be scoped independently from authenticated paths.
abstract final class RootApiPaths {
  static bool _isRootScoped(String path) {
    if (!path.startsWith('/api/v2/')) return false;
    final suffix = path.substring('/api/v2/'.length);
    return const <String>[
          'files/',
          'uploads/',
          'file-shares/',
          'photos/',
          'cinema/',
          'series/',
          'tasks/',
          'alerts/',
          'admin/uploads/',
          'missing-media/',
        ].any(suffix.startsWith) ||
        const <String>[
          'files',
          'uploads',
          'file-shares',
          'photos',
          'cinema',
          'series',
          'tasks',
          'alerts',
          'admin/uploads',
          'trash/retention',
        ].contains(suffix);
  }

  static String scopedPath(LightIsleRoot? root, String path) {
    if (root == null || !_isRootScoped(path)) return path;
    return '/api/v2/roots/${Uri.encodeComponent(root.id)}'
        '${path.substring('/api/v2'.length)}';
  }

  static String publicSharePath(LightIsleRoot? root, String token) {
    if (token.isEmpty || token.contains('/') || token.contains('\\')) {
      throw ArgumentError('无效的公开文件分享令牌');
    }
    final sharePath = '/public/file/${Uri.encodeComponent(token)}';
    return root == null
        ? '/api/v2$sharePath'
        : '/api/v2/roots/${Uri.encodeComponent(root.id)}$sharePath';
  }
}
