import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/core/root_api_paths.dart';

void main() {
  const root = LightIsleRoot(
    id: 'disk@family',
    name: '家庭磁盘',
    generation: 8,
    online: true,
  );

  test(
    'scopes file and media routes but never auth or already scoped routes',
    () {
      expect(
        RootApiPaths.scopedPath(root, '/api/v2/files'),
        '/api/v2/roots/disk%40family/files',
      );
      expect(
        RootApiPaths.scopedPath(root, '/api/v2/photos/status'),
        '/api/v2/roots/disk%40family/photos/status',
      );
      expect(
        RootApiPaths.scopedPath(root, '/api/v2/roots/other/files'),
        '/api/v2/roots/other/files',
      );
      expect(
        RootApiPaths.scopedPath(root, '/api/v2/auth/login'),
        '/api/v2/auth/login',
      );
      expect(RootApiPaths.scopedPath(null, '/api/v2/files'), '/api/v2/files');
    },
  );

  test('public shares bind the physical root independently of auth routes', () {
    expect(
      RootApiPaths.publicSharePath(root, 'abc-123'),
      '/api/v2/roots/disk%40family/public/file/abc-123',
    );
    expect(
      RootApiPaths.publicSharePath(null, 'abc-123'),
      '/api/v2/public/file/abc-123',
    );
    expect(
      () => RootApiPaths.publicSharePath(root, '../bad'),
      throwsArgumentError,
    );
    expect(() => RootApiPaths.publicSharePath(root, ''), throwsArgumentError);
  });
}
