import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/files/file_browser_repository.dart';

class _BrowserApi extends LightIsleApi {
  _BrowserApi() : super('http://localhost:16666');

  final requests = <(String, Map<String, String>?)>[];
  final responses = <String, Map<String, dynamic>>{};

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    requests.add((path, query));
    return responses[path] ?? {};
  }
}

void main() {
  test(
    'directory keeps server pagination and fail-closed write hint',
    () async {
      final api = _BrowserApi();
      addTearDown(api.close);
      api.responses['/api/v2/files/root'] = {'name': '家庭盘'};
      api.responses['/api/v2/files'] = {
        'entries': [
          {
            'name': 'notes.txt', 'path': 'Docs/notes.txt',
            'type': 'file', 'size': 123,
            // Unknown permissions must never grant member write access.
          },
        ],
        'nextCursor': 'next-42',
      };
      final result = await FileBrowserRepository(api).list(
        directory: 'Docs',
        limit: 100,
        cursor: 'cursor-1',
        sort: 'mtime',
        direction: 'desc',
      );
      expect(result.rootName, '家庭盘');
      expect(result.canWrite, false);
      expect(result.entries.single.canWrite, false);
      expect(result.nextCursor, 'next-42');
      expect(api.requests.last.$2, {
        'path': 'Docs',
        'limit': '100',
        'cursor': 'cursor-1',
        'sort': 'mtime',
        'dir': 'desc',
      });
      expect(() => result.entries.clear(), throwsUnsupportedError);
    },
  );

  test(
    'search keeps root-relative filtering and truncated indicator',
    () async {
      final api = _BrowserApi();
      addTearDown(api.close);
      api.responses['/api/v2/files/search'] = {
        'entries': [
          {
            'name': 'a.png',
            'path': 'Photos/a.png',
            'type': 'file',
            'canWrite': true,
          },
        ],
        'truncated': true,
        'canWrite': true,
      };
      final result = await FileBrowserRepository(api)
          .search(initialPath: 'Photos', term: 'a.png', limit: 100);
      expect(result.entries.single.name, 'a.png');
      expect(result.canWrite, true);
      expect(result.truncated, true);
      expect(api.requests.single.$2, {
        'path': 'Photos',
        'query': 'a.png',
        'limit': '100',
      });
    },
  );

  test(
    'trash excludes malformed items and sorts newest deletion first',
    () async {
      final api = _BrowserApi();
      addTearDown(api.close);
      api.responses['/api/v2/files/trash'] = {
        'entries': [
          {'id': 'old', 'name': 'Old', 'deletedAt': '2026-10-01T00:00:00Z'},
          4,
          {'id': 'new', 'name': 'New', 'deletedAt': '2026-11-01T00:00:00Z'},
        ],
      };
      final result = await FileBrowserRepository(api).trash();
      expect(result.map((entry) => entry.id), ['new', 'old']);
      expect(() => result.clear(), throwsUnsupportedError);
    },
  );
}
