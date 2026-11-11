import '../../core/lightisle_api.dart';
import 'file_models.dart';

/// Immutable directory result; never bind it to a different physical root.
final class FileDirectoryPage {
  const FileDirectoryPage({
    required this.rootName,
    required this.entries,
    required this.nextCursor,
    required this.canWrite,
  });

  final String rootName;
  final List<FileEntry> entries;
  final String nextCursor;
  final bool canWrite;
}

final class FileSearchPage {
  const FileSearchPage({
    required this.entries,
    required this.canWrite,
    required this.truncated,
  });

  final List<FileEntry> entries;
  final bool canWrite;
  final bool truncated;
}

/// One place for the file browser's list/search/trash API contracts. Authorization
/// is enforced by the server; callers must still reject responses from an
/// obsolete account, directory, or root generation before presenting them.
class FileBrowserRepository {
  const FileBrowserRepository(this.api);

  final LightIsleApi api;

  static List<Map<String, dynamic>> _rows(Object? value) => value is List
      ? value.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
      : const <Map<String, dynamic>>[];

  Future<FileDirectoryPage> list({
    required String directory,
    required int limit,
    required String cursor,
    required String sort,
    required String direction,
  }) async {
    final root = await api.get('/api/v2/files/root');
    final response = await api.get(
      '/api/v2/files',
      query: {
        'path': directory,
        'limit': '$limit',
        'cursor': cursor,
        'sort': sort,
        'dir': direction,
      },
    );
    final rootName = root['name']?.toString().trim() ?? '';
    return FileDirectoryPage(
      rootName: rootName.isEmpty ? '共享文件' : rootName,
      entries: List.unmodifiable(
        _rows(response['entries']).map(FileEntry.fromJson),
      ),
      nextCursor: response['nextCursor']?.toString() ?? '',
      canWrite: response['canWrite'] == true,
    );
  }

  Future<FileSearchPage> search({
    required String initialPath,
    required String term,
    required int limit,
    String kind = '',
  }) async {
    final query = <String, String>{
      'path': initialPath,
      'query': term,
      'limit': '$limit',
    };
    if (kind.isNotEmpty && kind != 'all') {
      query['kind'] = kind;
    }
    final response = await api.get('/api/v2/files/search', query: query);
    return FileSearchPage(
      entries: List.unmodifiable(
        _rows(response['entries']).map(FileEntry.fromJson),
      ),
      canWrite: response['canWrite'] == true,
      truncated: response['truncated'] == true,
    );
  }

  Future<List<TrashEntry>> trash() async {
    final response = await api.get('/api/v2/files/trash');
    final entries = _rows(response['entries']).map(TrashEntry.fromJson).toList()
      ..sort(
        (a, b) =>
            (b.deletedAt ?? DateTime(0)).compareTo(a.deletedAt ?? DateTime(0)),
      );
    return List.unmodifiable(entries);
  }
}
