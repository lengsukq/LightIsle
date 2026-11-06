import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/folder_albums_page.dart';
import 'package:lightisle/features/media/media_models.dart';

class _FolderApi extends LightIsleApi {
  _FolderApi() : super('http://127.0.0.1:16666');
  final calls = <(String, String, Object?)>[];
  final folders = <Map<String, dynamic>>[
    {'name': '家庭', 'path': 'Users/u2/photos/家庭'},
  ];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async => {'albums': List.of(folders), 'nextCursor': ''};
  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    calls.add((method, path, body));
    if (path == '/api/v2/photos/folder-albums' && body is Map) {
      folders.add({
        'name': body['name'],
        'path': 'Users/u2/photos/${body['name']}',
      });
    }
    return {};
  }
}

const _rootA = LightIsleRoot(
  id: 'root-a',
  name: 'A',
  generation: 1,
  online: true,
);
const _rootB = LightIsleRoot(
  id: 'root-b',
  name: 'B',
  generation: 1,
  online: true,
);
const _photo = PhotoAsset(
  id: 1,
  path: 'Users/u2/photos/a.jpg',
  name: 'a.jpg',
  type: 'photo',
  size: 10,
  takenAt: 0,
  favorite: false,
  canWrite: true,
);

void main() {
  testWidgets('creates an actual folder album through the root API', (
    tester,
  ) async {
    final api = _FolderApi()..selectRoot(_rootA);
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(home: FolderAlbumsPage(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('家庭'), findsOneWidget);
    await tester.tap(find.text('新建相册'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '旅行');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(api.calls.single.$1, 'POST');
    expect(api.calls.single.$2, '/api/v2/photos/folder-albums');
    expect(api.calls.single.$3, {'name': '旅行'});
    expect(find.text('旅行'), findsOneWidget);
  });

  testWidgets('copy uses the selected disk and a real destination path', (
    tester,
  ) async {
    final api = _FolderApi()..selectRoot(_rootA);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: FolderAlbumsPage(api: api, source: _photo, canMove: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('家庭'));
    await tester.pumpAndSettle();
    expect(api.calls, isEmpty);
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(api.calls.single.$1, 'POST');
    expect(api.calls.single.$2, '/api/v2/files/operations');
    expect(api.calls.single.$3, {
      'action': 'copy',
      'from': 'Users/u2/photos/a.jpg',
      'to': 'Users/u2/photos/家庭/a.jpg',
      'conflict': '',
    });
  });

  testWidgets('a root switch during selection stops a move', (tester) async {
    final api = _FolderApi()..selectRoot(_rootA);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: FolderAlbumsPage(api: api, source: _photo, canMove: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('家庭'));
    await tester.pumpAndSettle();
    api.selectRoot(_rootB);
    await tester.tap(find.text('移动'));
    await tester.pumpAndSettle();
    expect(api.calls, isEmpty);
  });
}
