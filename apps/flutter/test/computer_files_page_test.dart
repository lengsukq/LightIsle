import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/files/computer_files_page.dart';
import 'package:lightisle/features/media/photo_gallery_viewer.dart';

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
      final atRoot = selected.isEmpty || selected == '/';
      return {
        'path': atRoot ? '/' : selected,
        'entries': atRoot
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

  testWidgets(
    'system Back navigates back through folder history before popping page',
    (tester) async {
      final api = ComputerApi();
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(home: ComputerFilesPage(api: api, isAdmin: false)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Documents'));
      await tester.pumpAndSettle();
      expect(find.text('notes.txt'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Documents'), findsOneWidget);
      expect(find.text('notes.txt'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tapping image or video in computer files opens built-in PhotoGalleryViewer',
    (tester) async {
      final api = _MediaComputerApi();
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(home: ComputerFilesPage(api: api, isAdmin: false)),
      );
      await tester.pumpAndSettle();

      expect(find.text('sunset.jpg'), findsOneWidget);
      expect(find.text('vacation.mp4'), findsOneWidget);

      await tester.tap(find.text('sunset.jpg'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.byType(PhotoGalleryViewer), findsOneWidget);
      expect(find.byType(PhotoMediaImage), findsOneWidget);
      expect(find.text('sunset.jpg'), findsWidgets);

      await tester.tap(find.byTooltip('返回文件'));
      await tester.pumpAndSettle();
      expect(find.byType(PhotoGalleryViewer), findsNothing);

      await tester.tap(find.text('vacation.mp4'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.byType(PhotoGalleryViewer), findsOneWidget);
      expect(find.byType(PhotoMediaVideo), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

class _MediaComputerApi extends ComputerApi {
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/computer-files') {
      return {
        'path': '/Pictures',
        'entries': [
          {
            'name': 'sunset.jpg',
            'path': '/Pictures/sunset.jpg',
            'type': 'file',
            'size': 2048,
          },
          {
            'name': 'vacation.mp4',
            'path': '/Pictures/vacation.mp4',
            'type': 'file',
            'size': 8192,
          },
        ],
        'nextCursor': '',
      };
    }
    return super.get(path, query: query);
  }
}
