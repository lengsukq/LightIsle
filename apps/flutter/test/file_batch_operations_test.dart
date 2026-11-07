import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/files/file_batch_operations.dart';
import 'package:lightisle/features/files/file_models.dart';

class _BatchApi extends LightIsleApi {
  _BatchApi() : super('http://127.0.0.1:16666');

  final sent = <(String, String, Object?)>[];
  Future<Map<String, dynamic>> Function(String, String, Object?)? onSend;

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    sent.add((method, path, body));
    return await onSend?.call(method, path, body) ?? {};
  }
}

FileEntry entry(String path, {bool folder = false}) => FileEntry(
  name: path.split('/').last,
  path: path,
  type: folder ? 'folder' : 'file',
  size: 12,
  modified: null,
  canWrite: true,
);

void main() {
  test('plan disallows moving a folder into itself or its children', () {
    final plan = FileBatchOperations.planTransfer(
      action: 'move',
      items: [entry('Photos', folder: true), entry('work.txt')],
      destination: 'Photos/archive',
    );
    expect(plan.valid, false);
    expect(plan.invalidPaths, ['Photos']);
    expect(() => plan.invalidPaths.clear(), throwsUnsupportedError);
    expect(() => plan.items.clear(), throwsUnsupportedError);
  });

  test('plan keeps copy-with-rename of same file valid but not move', () {
    final copied = FileBatchOperations.planTransfer(
      action: 'copy',
      items: [entry('Docs/a.txt')],
      destination: 'Docs',
    );
    expect(copied.valid, true);
    final moved = FileBatchOperations.planTransfer(
      action: 'move',
      items: [entry('Docs/a.txt')],
      destination: 'Docs',
    );
    expect(moved.invalidPaths, ['Docs/a.txt']);
  });

  test('transfer stops before next write when physical root changes', () async {
    final api = _BatchApi();
    addTearDown(api.close);
    var stillCurrent = true;
    api.onSend = (method, path, body) async {
      stillCurrent = false;
      return {};
    };
    final plan = FileBatchOperations.planTransfer(
      action: 'move',
      items: [entry('a.txt'), entry('b.txt'), entry('c.txt')],
      destination: 'Archive',
    );
    final result = await FileBatchOperations(api).transfer(
      action: 'move',
      plan: plan,
      destination: 'Archive',
      stillCurrent: () => stillCurrent,
    );
    expect(result.completed, 1);
    expect(result.failedPaths, ['b.txt', 'c.txt']);
    expect(api.sent, hasLength(1));
    expect(api.sent.single.$3, {
      'action': 'move',
      'from': 'a.txt',
      'to': 'Archive/a.txt',
      'conflict': 'rename',
    });
  });

  test('partial errors do not skip later files', () async {
    final api = _BatchApi();
    addTearDown(api.close);
    api.onSend = (method, path, body) async {
      if ((body as Map)['from'] == 'broken.txt') {
        throw StateError('server rejected');
      }
      return {};
    };
    final plan = FileBatchOperations.planTransfer(
      action: 'copy',
      items: [entry('ok.txt'), entry('broken.txt'), entry('after.txt')],
      destination: '.',
    );
    final result = await FileBatchOperations(api).transfer(
      action: 'copy',
      plan: plan,
      destination: '.',
      stillCurrent: () => true,
    );
    expect(result.completed, 2);
    expect(result.failedPaths, ['broken.txt']);
    expect(api.sent, hasLength(3));
  });

  test(
    'trash submits a bounded snapshot and reports partial failures',
    () async {
      final api = _BatchApi();
      addTearDown(api.close);
      api.onSend = (_, _, _) async => {
        'results': [
          {'success': true, 'path': 'a.txt'},
          {'success': false, 'path': 'b.txt'},
        ],
      };
      final result = await FileBatchOperations(api).trash(['a.txt', 'b.txt']);
      expect(result.succeeded, 1);
      expect(result.failureCount, 1);
      expect(result.failedPaths, ['b.txt']);
      expect(result.receivedCount, 2);
      expect(result.needsRootCheck, isFalse);
      expect(api.sent.single.$3, {
        'action': 'trash',
        'paths': ['a.txt', 'b.txt'],
      });
      expect(
        () => FileBatchOperations(api).trash(List.filled(51, 'file.txt')),
        throwsArgumentError,
      );
    },
  );

  test('trash reports that a disconnected disk needs checking', () async {
    final api = _BatchApi();
    addTearDown(api.close);
    api.onSend = (_, _, _) async => {
      'results': [
        {
          'success': false,
          'path': 'a.txt',
          'error': 'storage_operation_uncertain',
        },
        {'success': false, 'path': 'b.txt', 'error': 'root_unavailable'},
      ],
    };
    final result = await FileBatchOperations(api).trash(['a.txt', 'b.txt']);
    expect(result.needsRootCheck, isTrue);
    expect(result.succeeded, 0);
  });

  test('trash reports an identity change and unstarted items', () async {
    final api = _BatchApi();
    addTearDown(api.close);
    api.onSend = (_, _, _) async => {
      'results': [
        {'success': false, 'path': 'a.txt', 'error': 'trash_item_changed'},
        {'success': false, 'path': 'b.txt', 'error': 'operation_not_started'},
      ],
    };
    final result = await FileBatchOperations(api).trash(['a.txt', 'b.txt']);
    expect(result.needsTrashCheck, isTrue);
    expect(result.needsRootCheck, isFalse);
    expect(result.failedPaths, ['a.txt', 'b.txt']);
  });
}
