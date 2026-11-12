import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/files/computer_files_page.dart';

class ComputerApi extends LightIsleApi {
  ComputerApi({this.enabled = true, this.mode = 'all'})
    : super('http://127.0.0.1:1');
  bool enabled;
  String mode;
  final calls = <String>[];
  Object? savedGrant;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    calls.add('$path:${query?['path'] ?? ''}');
    if (path.endsWith('/status')) return {'enabled': enabled, 'mode': mode};
    if (path == '/api/v2/users') {
      return {
        'users': [
          {'id': 2, 'username': 'family', 'role': 'member'},
        ],
      };
    }
    if (path.endsWith('/grants/2')) return {'mode': 'none', 'folders': []};
    if (path == '/api/v2/computer-files') {
      final selected = query?['path'] ?? '';
      return {
        'path': selected.isEmpty ? '/' : selected,
        'entries': selected.isEmpty
            ? [
                {
                  'name': 'Documents',
                  'path': '/Documents',
                  'type': 'folder',
                  'size': 0,
                },
              ]
            : [
                {
                  'name': 'notes.txt',
                  'path': '/Documents/notes.txt',
                  'type': 'file',
                  'size': 5,
                },
              ],
        'nextCursor': '',
      };
    }
    throw StateError(path);
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    savedGrant = body;
    return {};
  }
}

void main() {
  testWidgets('disabled state explains that the Mac controls the switch', (
    tester,
  ) async {
    final api = ComputerApi(enabled: false);
    await tester.pumpWidget(
      MaterialApp(home: ComputerFilesPage(api: api, isAdmin: true)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('此功能未开启'), findsOneWidget);
    expect(
      api.calls.where((c) => c.startsWith('/api/v2/computer-files:')),
      isEmpty,
    );
    api.close();
  });
  testWidgets('member can browse directories without write controls', (
    tester,
  ) async {
    final api = ComputerApi();
    await tester.pumpWidget(
      MaterialApp(home: ComputerFilesPage(api: api, isAdmin: false)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Documents'));
    await tester.pumpAndSettle();
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('成员访问权限'), findsNothing);
    expect(find.text('上传文件'), findsNothing);
    expect(find.byTooltip('下载'), findsWidgets);
    api.close();
  });
  testWidgets('administrator can grant the selected folder', (tester) async {
    final api = ComputerApi();
    await tester.pumpWidget(
      MaterialApp(home: ComputerFilesPage(api: api, isAdmin: true)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Documents'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('选择成员'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('family').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('无权限'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('指定文件夹').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('将当前文件夹加入授权'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('将当前文件夹加入授权'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存权限'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存权限'));
    await tester.pumpAndSettle();
    expect(api.savedGrant, {
      'mode': 'folders',
      'paths': ['/Documents'],
    });
    api.close();
  });
}
