import '../../core/lightisle_api.dart';
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

final class FileBatchTransferResult {
  const FileBatchTransferResult({
    required this.completed,
    required this.failedPaths,
  });

  final int completed;
  final List<String> failedPaths;
}

final class FileBatchTrashResult {
  const FileBatchTrashResult({
    required this.failedPaths,
    required this.failureCount,
    required this.succeeded,
    required this.receivedCount,
  });

  final List<String> failedPaths;
  final int failureCount;
  final int succeeded;
  final int receivedCount;
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
  }) async {
    if (action != 'move' && action != 'copy') {
      throw ArgumentError.value(action, 'action', 'Unsupported batch action');
    }
    if (!plan.valid) throw StateError('Batch plan has invalid paths');
    var completed = 0;
    final failures = <String>[];
    for (var i = 0; i < plan.items.length; i++) {
      final item = plan.items[i];
      if (!stillCurrent()) {
        failures.addAll(plan.items.skip(i).map((entry) => entry.path));
        break;
      }
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
      } catch (_) {
        failures.add(item.path);
      }
    }
    return FileBatchTransferResult(
      completed: completed,
      failedPaths: List.unmodifiable(failures),
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
    );
  }
}
