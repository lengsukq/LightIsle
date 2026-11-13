import '../../core/lightisle_api.dart';
import '../files/file_export_service.dart';

typedef MediaBatchItem = ({String path, String name, int size});
typedef MediaShareItem = ({String path, String label});

/// Result of a sequential batch. A change of account/root stops new actions;
/// already completed operations are explicitly counted rather than hidden.
class MediaBatchResult {
  const MediaBatchResult({
    required this.completed,
    required this.cancelled,
    this.error,
    this.links = const [],
    this.needsRootCheck = false,
  });

  final int completed;
  final bool cancelled;
  final Object? error;
  final List<String> links;
  final bool needsRootCheck;
}

/// NAS media actions shared by Photos and Cinema. Confirmation, clipboard,
/// and picker UI stay in the caller. The server is authoritative for access.
class MediaBatchOperations {
  const MediaBatchOperations(this.api);

  final LightIsleApi api;

  /// Photos and Cinema delete their original files through the same
  /// permission-checked trash endpoint as File Manager. Keep the paths and
  /// physical root frozen across a batch; never switch destinations mid-action.
  Future<MediaBatchResult> trashOriginals({
    required List<String> paths,
    required bool Function() stillCurrent,
  }) async {
    if (paths.isEmpty ||
        paths.length > 50 ||
        paths.any((path) => path.isEmpty) ||
        paths.toSet().length != paths.length) {
      throw ArgumentError('Select 1–50 unique original paths');
    }
    if (!stillCurrent()) {
      return const MediaBatchResult(completed: 0, cancelled: true);
    }
    final response = await api.send(
      'POST',
      '/api/v2/files/batch',
      body: {'action': 'trash', 'paths': List<String>.unmodifiable(paths)},
    );
    final results = response['results'];
    if (results is! List || results.length != paths.length) {
      return const MediaBatchResult(
        completed: 0,
        cancelled: false,
        error: FormatException('服务器未返回完整的删除结果，请刷新回收站核对'),
      );
    }
    final completed = results
        .where((result) => result is Map && result['success'] == true)
        .length;
    final needsRootCheck = results.any(
      (result) =>
          result is Map &&
          (result['error'] == 'storage_operation_uncertain' ||
              result['error'] == 'root_unavailable'),
    );
    return MediaBatchResult(
      completed: completed,
      cancelled: !stillCurrent(),
      needsRootCheck: needsRootCheck,
      error: completed == paths.length
          ? null
          : StateError('部分文件无写入权限或已变化，请在回收站与原目录确认'),
    );
  }

  Future<MediaBatchResult> createShares({
    required List<MediaShareItem> items,
    required bool Function() stillCurrent,
  }) async {
    if (items.isEmpty ||
        items.length > 10 ||
        items.any((item) => item.path.isEmpty)) {
      throw ArgumentError('Select 1–10 valid originals to share');
    }
    final links = <String>[];
    for (final item in List<MediaShareItem>.unmodifiable(items)) {
      if (!stillCurrent()) {
        return MediaBatchResult(
          completed: links.length,
          cancelled: true,
          links: List.unmodifiable(links),
        );
      }
      try {
        final response = await api.send(
          'POST',
          '/api/v2/file-shares',
          body: {'path': item.path, 'hours': 24},
        );
        // The URL must not be built from a newly selected physical root.
        if (!stillCurrent()) {
          return MediaBatchResult(
            completed: links.length,
            cancelled: true,
            links: List.unmodifiable(links),
          );
        }
        final token = response['token']?.toString() ?? '';
        if (token.isEmpty) {
          throw const FormatException('服务器未返回分享令牌');
        }
        links.add('${item.label}: ${api.publicFileShareUri(token)}');
      } catch (error) {
        return MediaBatchResult(
          completed: links.length,
          cancelled: false,
          error: error,
          links: List.unmodifiable(links),
        );
      }
    }
    return MediaBatchResult(
      completed: links.length,
      cancelled: false,
      links: List.unmodifiable(links),
    );
  }

  /// Desktop file picker is shown only once by the caller. Unlike the mobile
  /// system sheet, individual desktop originals are saved sequentially.
  Future<MediaBatchResult> exportToDirectory({
    required List<MediaBatchItem> items,
    required String directory,
    required bool Function() stillCurrent,
    Future<String> Function({
      required String path,
      required String name,
      required String directory,
    })?
    saveOriginal,
  }) async {
    if (directory.isEmpty ||
        items.isEmpty ||
        items.length > 50 ||
        items.any((item) => item.path.isEmpty)) {
      throw ArgumentError('Select 1–50 files and a destination directory');
    }
    final save =
        saveOriginal ??
        ({
          required String path,
          required String name,
          required String directory,
        }) => exportMediaFile(
          api,
          path: path,
          name: name,
          destinationDirectory: directory,
        );
    var saved = 0;
    for (final item in List<MediaBatchItem>.unmodifiable(items)) {
      if (!stillCurrent()) {
        return MediaBatchResult(completed: saved, cancelled: true);
      }
      try {
        await save(path: item.path, name: item.name, directory: directory);
        saved++;
      } catch (error) {
        return MediaBatchResult(
          completed: saved,
          cancelled: false,
          error: error,
        );
      }
    }
    return MediaBatchResult(completed: saved, cancelled: false);
  }

  /// Mobile uses the existing single native picker/share sheet and verified
  /// temporary downloads. The shared export service checks the frozen root
  /// before each download and before handing any files to the OS.
  Future<String> exportOnMobile({
    required List<MediaBatchItem> items,
    required bool Function() stillCurrent,
    void Function(int finished, int total, String name)? onProgress,
  }) => exportMediaFiles(
    api,
    items: List<MediaBatchItem>.unmodifiable(items),
    onProgress: onProgress,
    stillCurrent: stillCurrent,
  );
}
