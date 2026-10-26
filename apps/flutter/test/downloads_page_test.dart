import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/files/downloads_page.dart';

class DownloadApi extends LightIsleApi {
  DownloadApi() : super('http://127.0.0.1:16666');
  bool available = true, fail = false;
  Future<Map<String, dynamic>>? heldStatus;
  int statusReads = 0;
  final writes = <({String method, String path, Object? body})>[];
  List<Map<String, dynamic>> tasks = [];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path.endsWith('/status')) {
      statusReads++;
      if (heldStatus != null) return heldStatus!;
      if (fail) throw StateError('离线');
      return {
        'available': available,
        'reason': available ? '' : 'aria2_not_installed',
      };
    }
    if (path == '/api/v1/downloads') return {'tasks': tasks};
    if (path == '/api/v1/files') {
      if (query?['path'] == 'Photos') return {'entries': [], 'canWrite': true};
      return {
        'entries': [
          {'type': 'folder', 'name': 'Photos', 'path': 'Photos'},
        ],
        'canWrite': false,
      };
    }
    throw StateError('Unexpected read $path');
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    writes.add((method: method, path: path, body: body));
    if (path.endsWith('/actions')) {
      tasks = [
        for (final t in tasks) {...t, 'status': 'paused'},
      ];
    }
    return {};
  }
}

Map<String, dynamic> task(String status) => {
  'id': 'task-1',
  'url': 'https://example.invalid/archive.zip',
  'destination': 'Photos',
  'status': status,
  'totalBytes': 100,
  'completedBytes': 50,
};

Future<void> showPage(
  WidgetTester tester,
  DownloadApi api, {
  String destination = '.',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: DownloadsPage(api: api, initialDestination: destination),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('local publication can retry without the network component', (
    tester,
  ) async {
    final api = DownloadApi()
      ..available = false
      ..tasks = [
        {...task('failed'), 'phase': 'publishing', 'partialPublish': true},
      ];
    addTearDown(api.close);
    await showPage(tester, api);
    expect(find.text('新建下载'), findsNothing);
    final retry = find.widgetWithText(TextButton, '重试');
    expect(tester.widget<TextButton>(retry).onPressed, isNotNull);
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(api.writes.single.body, {'action': 'retry'});
  });

  testWidgets(
    'bounded publication details show the real total and truncation',
    (tester) async {
      final api = DownloadApi()
        ..tasks = [
          {
            ...task('failed'),
            'publishedFilesTotal': 200,
            'publishedFilesTruncated': true,
            'publishedFiles': [
              {'target': 'Photos/a.jpg', 'status': 'published', 'size': 1},
            ],
          },
        ];
      addTearDown(api.close);
      await showPage(tester, api);
      await tester.tap(find.text('文件处理记录（200 项）'));
      await tester.pumpAndSettle();
      expect(find.textContaining('这里只显示前 1 项'), findsOneWidget);
    },
  );

  testWidgets(
    'missing component retains history without showing an empty active center',
    (tester) async {
      final api = DownloadApi()
        ..available = false
        ..tasks = [task('completed')];
      addTearDown(api.close);
      await showPage(tester, api);
      expect(find.textContaining('Mac 尚未安装'), findsOneWidget);
      expect(find.text('新建下载'), findsNothing);
      expect(find.textContaining('已完成 · 保存到 Photos'), findsOneWidget);
      expect(find.textContaining('还没有下载任务'), findsNothing);
    },
  );

  testWidgets(
    'initial connection failure is retryable and distinct from unavailable',
    (tester) async {
      final api = DownloadApi()..fail = true;
      addTearDown(api.close);
      await showPage(tester, api);
      expect(find.textContaining('读取下载中心失败'), findsOneWidget);
      expect(find.textContaining('Mac 尚未安装'), findsNothing);
      api.fail = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.textContaining('还没有下载任务'), findsOneWidget);
    },
  );

  testWidgets(
    'create preserves the selected folder and validates the size budget',
    (tester) async {
      final api = DownloadApi();
      addTearDown(api.close);
      await showPage(tester, api, destination: 'Incoming');
      await tester.tap(find.text('新建下载'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'https://example.invalid/file.iso',
      );
      await tester.enterText(find.byType(TextField).last, '1025');
      await tester.tap(find.text('开始下载'));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      expect(find.textContaining('大小上限请输入'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, '2');
      await tester.tap(find.text('开始下载'));
      await tester.pumpAndSettle();
      expect(api.writes.single.path, '/api/v1/downloads');
      expect(api.writes.single.body, {
        'url': 'https://example.invalid/file.iso',
        'destination': 'Incoming',
        'maxBytes': 2 * 1024 * 1024 * 1024,
      });
    },
  );

  testWidgets(
    'folder picker traverses read-only ancestors and selects a writable folder',
    (tester) async {
      final api = DownloadApi();
      addTearDown(api.close);
      await showPage(tester, api);
      await tester.tap(find.text('新建下载'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择文件夹'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存到这里'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Photos'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存到这里'));
      await tester.pumpAndSettle();
      expect(find.text('保存到：Photos'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField).first,
        'https://example.invalid/file',
      );
      await tester.tap(find.text('开始下载'));
      await tester.pumpAndSettle();
      expect((api.writes.single.body as Map)['destination'], 'Photos');
    },
  );

  testWidgets(
    'partial publication and recovery stay visible; pause refreshes real state',
    (tester) async {
      final api = DownloadApi()
        ..tasks = [
          {
            ...task('running'),
            'partialPublish': true,
            'recoveryRequired': true,
            'publishedFiles': [
              {'target': 'Photos/a.jpg', 'status': 'published', 'size': 50},
            ],
          },
        ];
      addTearDown(api.close);
      await showPage(tester, api);
      expect(find.textContaining('部分文件已保存'), findsOneWidget);
      expect(find.textContaining('已有文件与任务记录不一致'), findsOneWidget);
      await tester.tap(find.text('暂停'));
      await tester.pumpAndSettle();
      expect(api.writes.single.body, {'action': 'pause'});
      expect(find.textContaining('已暂停 ·'), findsOneWidget);
    },
  );

  testWidgets('delete record confirms that published files are retained', (
    tester,
  ) async {
    final api = DownloadApi()..tasks = [task('completed')];
    addTearDown(api.close);
    await showPage(tester, api);
    await tester.tap(find.text('删除记录'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已保存到共享目录的文件会保留'), findsOneWidget);
    expect(api.writes, isEmpty);
    await tester.tap(find.widgetWithText(FilledButton, '删除记录'));
    await tester.pumpAndSettle();
    expect(api.writes.single.method, 'DELETE');
  });

  testWidgets(
    'late results from a previous server cannot replace the new server',
    (tester) async {
      final held = Completer<Map<String, dynamic>>();
      final old = DownloadApi()..heldStatus = held.future;
      final fresh = DownloadApi()..available = false;
      addTearDown(old.close);
      addTearDown(fresh.close);
      await tester.pumpWidget(MaterialApp(home: DownloadsPage(api: old)));
      await tester.pump(const Duration(seconds: 10));
      expect(old.statusReads, 1);
      await showPage(tester, fresh);
      held.complete({'available': true});
      await tester.pumpAndSettle();
      expect(find.textContaining('Mac 尚未安装'), findsOneWidget);
      expect(find.text('新建下载'), findsNothing);
    },
  );

  testWidgets('narrow screen and large text keep task actions accessible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = DownloadApi()..tasks = [task('failed')];
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: DownloadsPage(api: api),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('重试'), 150);
    expect(tester.takeException(), isNull);
  });
}
