import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import 'file_models.dart';
import 'file_selection_snapshot.dart';

/// A validated immutable plan captured before asking for confirmation.
/// This never replaces the physical-root and selection recheck in the UI.
final class FileBatchTransferPlan {
  const FileBatchTransferPlan({
    required this.items,
    required this.invalidPaths,
  });

  final List<FileEntry> items;
  final List<String> invalidPaths;
  bool get valid => items.isNotEmpty && invalidPaths.isEmpty;
}

final class FileBatchFailure {
  const FileBatchFailure({
    required this.path,
    required this.reason,
    this.code,
  });

  final String path;
  final String reason;
  final String? code;
}

final class FileBatchProgress {
  const FileBatchProgress({
    required this.index,
    required this.total,
    required this.currentName,
  });

  final int index;
  final int total;
  final String currentName;
}

final class FileBatchTransferResult {
  const FileBatchTransferResult({
    required this.completed,
    required this.failedPaths,
    this.failures = const [],
    this.stoppedByUser = false,
  });

  final int completed;
  final List<String> failedPaths;
  final List<FileBatchFailure> failures;
  final bool stoppedByUser;
}

final class FileBatchTrashResult {
  const FileBatchTrashResult({
    required this.failedPaths,
    required this.failureCount,
    required this.succeeded,
    required this.receivedCount,
    this.needsRootCheck = false,
    this.needsTrashCheck = false,
  });

  final List<String> failedPaths;
  final int failureCount;
  final int succeeded;
  final int receivedCount;
  final bool needsRootCheck;
  final bool needsTrashCheck;
}

/// Executes bounded file operations; the caller owns user confirmation and
/// the server remains authoritative for identity, permissions and quotas.
class FileBatchOperations {
  const FileBatchOperations(this.api);

  final LightIsleApi api;

  static FileBatchTransferPlan planTransfer({
    required String action,
    required List<FileEntry> items,
    required String destination,
  }) {
    if (action != 'move' && action != 'copy') {
      throw ArgumentError.value(action, 'action', 'Unsupported batch action');
    }
    if (items.isEmpty || items.length > FileSelectionSnapshot.maxSelection) {
      throw ArgumentError('Select 1–50 items');
    }
    final invalid = <String>[];
    for (final item in items) {
      final target = destination == '.'
          ? item.name
          : '$destination/${item.name}';
      if ((action == 'move' && target == item.path) ||
          (item.isFolder &&
              (target == item.path || target.startsWith('${item.path}/')))) {
        invalid.add(item.path);
      }
    }
    return FileBatchTransferPlan(
      items: List.unmodifiable(items),
      invalidPaths: List.unmodifiable(invalid),
    );
  }

  Future<FileBatchTransferResult> transfer({
    required String action,
    required FileBatchTransferPlan plan,
    required String destination,
    required bool Function() stillCurrent,
    void Function(FileBatchProgress progress)? onProgress,
    bool Function()? stopRequested,
  }) async {
    if (action != 'move' && action != 'copy') {
      throw ArgumentError.value(action, 'action', 'Unsupported batch action');
    }
    if (!plan.valid) throw StateError('Batch plan has invalid paths');
    var completed = 0;
    var stoppedByUser = false;
    final failedPaths = <String>[];
    final failures = <FileBatchFailure>[];
    for (var i = 0; i < plan.items.length; i++) {
      final item = plan.items[i];
      if (stopRequested != null && stopRequested()) {
        stoppedByUser = true;
        for (final remaining in plan.items.skip(i)) {
          failedPaths.add(remaining.path);
          failures.add(
            FileBatchFailure(
              path: remaining.path,
              reason: '已由用户手动停止后续项',
              code: 'stopped_by_user',
            ),
          );
        }
        break;
      }
      if (!stillCurrent()) {
        for (final remaining in plan.items.skip(i)) {
          failedPaths.add(remaining.path);
          failures.add(
            FileBatchFailure(
              path: remaining.path,
              reason: '当前目录或存储根已变化，已中止后续项',
              code: 'context_changed',
            ),
          );
        }
        break;
      }
      onProgress?.call(
        FileBatchProgress(
          index: i + 1,
          total: plan.items.length,
          currentName: item.name,
        ),
      );
      final target = destination == '.'
          ? item.name
          : '$destination/${item.name}';
      try {
        await api.send(
          'POST',
          '/api/v2/files/operations',
          body: {
            'action': action,
            'from': item.path,
            'to': target,
            'conflict': 'rename',
          },
        );
        completed++;
      } catch (error) {
        failedPaths.add(item.path);
        failures.add(
          FileBatchFailure(
            path: item.path,
            reason: userFacingError(error),
            code: error is LightIsleApiException ? error.code : null,
          ),
        );
      }
    }
    return FileBatchTransferResult(
      completed: completed,
      failedPaths: List.unmodifiable(failedPaths),
      failures: List.unmodifiable(failures),
      stoppedByUser: stoppedByUser,
    );
  }

  Future<FileBatchTrashResult> trash(List<String> paths) async {
    if (paths.isEmpty ||
        paths.length > FileSelectionSnapshot.maxSelection ||
        paths.any((path) => path.isEmpty)) {
      throw ArgumentError('Batch trash requires 1–50 valid paths');
    }
    final response = await api.send(
      'POST',
      '/api/v2/files/batch',
      body: {'action': 'trash', 'paths': List<String>.of(paths)},
    );
    final raw = response['results'];
    final rows = raw is List
        ? raw
              .whereType<Map>()
              .map((row) => Map<String, dynamic>.from(row))
              .toList()
        : <Map<String, dynamic>>[];
    final failures = rows.where((row) => row['success'] != true).toList();
    return FileBatchTrashResult(
      failedPaths: List.unmodifiable(
        failures
            .map((row) => row['path']?.toString() ?? '')
            .where((path) => path.isNotEmpty),
      ),
      failureCount: failures.length,
      succeeded: rows.length - failures.length,
      receivedCount: rows.length,
      needsRootCheck: failures.any(
        (row) =>
            row['error'] == 'storage_operation_uncertain' ||
            row['error'] == 'root_unavailable',
      ),
      needsTrashCheck: failures.any(
        (row) => row['error'] == 'trash_item_changed',
      ),
    );
  }
}
