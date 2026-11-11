import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/files/file_browser_preferences.dart';
import 'package:lightisle/features/files/file_shares_page.dart';
import 'package:lightisle/features/files/files_page.dart';
import 'package:lightisle/features/files/file_text_preview_dialog.dart';
import 'package:lightisle/features/media/photo_gallery_viewer.dart';

part 'files_test_fakes.dart';
part 'files_preview_export_cases.dart';

class _UnavailableFilesApi extends _FilesTestApi {
  bool failDirectory = true;

  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query}) {
    if (failDirectory && path == '/api/v2/files') {
      return Future.error(
        const LightIsleApiException(
          code: 'default_root_not_configured',
          statusCode: 503,
          message: '服务器暂时无法完成请求，请稍后重试。',
        ),
      );
    }
    return super.get(path, query: query);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'unavailable directory shows root setup and diagnostic, not readonly',
    (tester) async {
      final api = _UnavailableFilesApi();
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FilesPage(api: api, isAdmin: false)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('尚未设置默认 NAS 存储目录'), findsOneWidget);
      expect(
        find.text('HTTP 503 · default_root_not_configured'),
        findsOneWidget,
      );
      expect(find.textContaining('当前目录为只读'), findsNothing);

      api.failDirectory = false;
      await tester.tap(find.widgetWithText(OutlinedButton, '重试'));
      await tester.pumpAndSettle();
      expect(find.textContaining('读取目录失败'), findsNothing);
      expect(find.text('HTTP 503 · default_root_not_configured'), findsNothing);
      expect(find.textContaining('当前目录为只读'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'read-only files can be selected without granting write actions',
    (tester) async {
      final api = _FilesTestApi(writable: false);
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FilesPage(api: api, isAdmin: false)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('files-select-toggle')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('计划说明.txt').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('计划说明.txt').last);
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项 · 每次最多 50 项'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '批量移到回收站'))
            .onPressed,
        isNull,
      );

      await tester.tap(find.widgetWithText(OutlinedButton, '全选当前页'));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 项 · 每次最多 50 项'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '完成'));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 项 · 每次最多 50 项'), findsNothing);
      expect(api.batchBody, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'file browser preferences are stored locally and isolated by identity',
    () async {
      final origin = Uri.parse('http://127.0.0.1:1');
      String scope(String account) => FileBrowserPreferences.scope(
        server: origin,
        account: account,
        rootIdentity: 'disk-a:1',
        initialPath: '.',
      );
      expect(scope('a'), isNot(scope('b')));
      expect(
        scope('a'),
        isNot(
          FileBrowserPreferences.scope(
            server: origin,
            account: 'a',
            rootIdentity: 'disk-b:1',
            initialPath: '.',
          ),
        ),
      );
      const stored = FileBrowserPreferences(
        view: 'grid',
        sort: 'mtime',
        direction: 'desc',
        autoRename: true,
      );
      await stored.save(scope('a'));
      final restored = await FileBrowserPreferences.load(scope('a'));
      expect(restored.view, 'grid');
      expect(restored.sort, 'mtime');
      expect(restored.direction, 'desc');
      expect(restored.autoRename, isTrue);
      expect((await FileBrowserPreferences.load(scope('b'))).view, 'list');
    },
  );

  testWidgets('file card layout and sort persist after reopening the page', (
    tester,
  ) async {
    final api = _FilesTestApi(writable: true);
    addTearDown(api.close);
    Widget createPage() => MaterialApp(
      home: Scaffold(
        body: FilesPage(api: api, isAdmin: false, accountName: 'alice'),
      ),
    );
    await tester.pumpWidget(createPage());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('files-card-grid')), findsNothing);
    expect(find.text('共享盘'), findsOneWidget);
    await tester.tap(find.byTooltip('切换卡片视图'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('files-card-grid')), findsOneWidget);
    expect(find.byKey(const ValueKey('file-card-资料夹')), findsOneWidget);
    await tester.tap(find.byTooltip('文件排序方式'));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .ancestor(
            of: find.text('修改时间 · 最新优先'),
            matching: find.byType(CheckedPopupMenuItem<String>),
          )
          .last,
    );
    await tester.pumpAndSettle();
    expect(
      api.requests
          .lastWhere((r) => r.path == '/api/v2/files')
          .queryParameters['sort'],
      'mtime',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(createPage());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('files-card-grid')), findsOneWidget);
    expect(find.byTooltip('切换列表视图'), findsOneWidget);
    expect(
      api.requests
          .lastWhere((r) => r.path == '/api/v2/files')
          .queryParameters['dir'],
      'desc',
    );
    await tester.tap(find.byKey(const ValueKey('file-card-资料夹')));
    await tester.pumpAndSettle();
    expect(
      api.requests
          .lastWhere((r) => r.path == '/api/v2/files')
          .queryParameters['path'],
      '资料夹',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('card grid fits a 320px phone with 200% text', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final api = _FilesTestApi(writable: true);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 720),
              textScaler: TextScaler.linear(2),
            ),
            child: FilesPage(api: api, isAdmin: false),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.ancestor(of: find.text('共享盘'), matching: find.byType(TextButton)),
      findsNothing,
    );
    await tester.tap(find.byTooltip('切换卡片视图'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('files-card-grid')), findsOneWidget);
    expect(find.byKey(const ValueKey('file-card-计划说明.txt')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('upload duplicate-name preference shows feedback and persists', (
    tester,
  ) async {
    final api = _FilesTestApi(writable: true);
    addTearDown(api.close);
    Widget page() => MaterialApp(
      home: Scaffold(body: FilesPage(api: api, isAdmin: false)),
    );
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多文件操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, '上传时同名自动改名'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已保存到本机'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多文件操作'));
    await tester.pumpAndSettle();
    final preference = find.widgetWithText(PopupMenuItem<String>, '上传时同名自动改名');
    expect(
      find.descendant(
        of: preference,
        matching: find.byIcon(Icons.check_rounded),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('account and physical-root changes restore isolated layouts', (
    tester,
  ) async {
    final api = _FilesTestApi();
    addTearDown(api.close);
    final firstRoot = LightIsleRoot(
      id: 'disk-a',
      name: 'Disk A',
      generation: 1,
      online: true,
    );
    final nextRoot = LightIsleRoot(
      id: 'disk-b',
      name: 'Disk B',
      generation: 1,
      online: true,
    );
    api.selectRoot(firstRoot);
    Widget app(String account) => MaterialApp(
      home: Scaffold(
        body: FilesPage(api: api, isAdmin: false, accountName: account),
      ),
    );
    await tester.pumpWidget(app('alice'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('切换卡片视图'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('files-card-grid')), findsOneWidget);

    await tester.pumpWidget(app('bob'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('files-card-grid')), findsNothing);

    await tester.pumpWidget(app('alice'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('files-card-grid')), findsOneWidget);

    api.selectRoot(nextRoot);
    await tester.pumpWidget(app('alice'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('files-card-grid')), findsNothing);

    api.selectRoot(firstRoot);
    await tester.pumpWidget(app('alice'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('files-card-grid')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('file path validation', () {
    test('accepts ordinary names and paths', () {
      expect(validateFileName('Quarterly report.pdf'), isNull);
      expect(validateRelativePath('Documents/Quarterly report.pdf'), isNull);
    });

    test('rejects names that can escape or collide with internal storage', () {
      expect(validateFileName(''), isNotNull);
      expect(validateFileName('..'), isNotNull);
      expect(validateFileName('folder/file.txt'), isNotNull);
      expect(validateFileName('.lightisle-trash'), isNotNull);
    });

    test('rejects absolute, traversing, ambiguous, and reserved paths', () {
      for (final path in [
        '.',
        '/outside/file.txt',
        r'folder\file.txt',
        'folder/../file.txt',
        'folder//file.txt',
        'folder/.lightisle-parts/item',
      ]) {
        expect(validateRelativePath(path), isNotNull, reason: path);
      }
    });
  });

  testWidgets('batch copy chooses a writable folder and avoids overwriting', (
    tester,
  ) async {
    final api = _FilesTestApi(writable: true);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FilesPage(api: api, isAdmin: false)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('计划说明.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '复制到'));
    await tester.pumpAndSettle();
    expect(find.text('选择批量复制目录'), findsOneWidget);
    await tester.tap(find.text('资料夹').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '使用此目录'));
    await tester.pumpAndSettle();
    expect(
      api.requests.where((r) => r.path == '/api/v2/files/operations'),
      isEmpty,
    );
    await tester.tap(find.widgetWithText(FilledButton, '开始复制'));
    await tester.pumpAndSettle();
    final operations = api.requests
        .where((r) => r.path == '/api/v2/files/operations')
        .toList();
    expect(operations, hasLength(1));
    expect(operations.single.body, {
      'action': 'copy',
      'from': '计划说明.txt',
      'to': '资料夹/计划说明.txt',
      'conflict': 'rename',
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'sort and folder picker use server ordering and safe conflict policy',
    (tester) async {
      final api = _FilesTestApi(writable: true);
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(body: FilesPage(api: api, isAdmin: false)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('文件排序方式'));
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .ancestor(
              of: find.text('修改时间 · 最新优先'),
              matching: find.byType(CheckedPopupMenuItem<String>),
            )
            .last,
      );
      await tester.pumpAndSettle();
      expect(
        api.requests.any(
          (request) =>
              request.path == '/api/v2/files' &&
              request.queryParameters['sort'] == 'mtime' &&
              request.queryParameters['dir'] == 'desc',
        ),
        isTrue,
      );

      // The second item is a file. Copy it using a browsable folder picker,
      // not a typed relative path, with collision-safe auto-rename by default.
      await tester.tap(find.byTooltip('文件操作').at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制').last);
      await tester.pumpAndSettle();
      expect(find.text('目标文件名'), findsOneWidget);
      await tester.tap(find.text('资料夹').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '复制').last);
      await tester.pumpAndSettle();

      expect(
        api.requests.any((request) {
          if (request.path != '/api/v2/files/operations' ||
              request.method != 'POST') {
            return false;
          }
          final body = request.body as Map;
          return body['action'] == 'copy' &&
              body['from'] == '计划说明.txt' &&
              body['to'] == '资料夹/计划说明.txt' &&
              body['conflict'] == 'rename';
        }),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rename stays in the same folder and refuses replacement', (
    tester,
  ) async {
    final api = _FilesTestApi(writable: true);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FilesPage(api: api, isAdmin: false)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('文件操作').at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '../escape.txt');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('名称不能包含路径分隔符。'), findsOneWidget);
    expect(api.requests.where((r) => r.method == 'POST'), isEmpty);
    await tester.enterText(find.byType(TextField).last, '新计划.txt');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(api.requests.lastWhere((r) => r.method == 'POST').body, {
      'action': 'move',
      'from': '计划说明.txt',
      'to': '新计划.txt',
      'conflict': '',
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'system Back opens the parent folder before leaving file management',
    (tester) async {
      final api = _FilesTestApi();
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FilesPage(api: api, isAdmin: false)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('资料夹'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('计划说明.txt'), findsOneWidget);
      expect(api.requests.last.queryParameters['path'], '.');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('browses folders and keeps read-only actions unavailable', (
    tester,
  ) async {
    final api = _FilesTestApi();
    addTearDown(api.close);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
            child: FilesPage(api: api, isAdmin: false),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('共享盘'), findsOneWidget);
    expect(find.text('只读'), findsNothing);
    expect(find.textContaining('当前目录为只读'), findsOneWidget);
    expect(find.text('新建文件夹'), findsNothing);
    expect(find.text('上传文件'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('资料夹'));
    await tester.pumpAndSettle();
    expect(
      api.requests.any(
        (request) =>
            request.path == '/api/v2/files' &&
            request.queryParameters['path'] == '资料夹',
      ),
      isTrue,
    );
    expect(find.text('此文件夹目前是空的。'), findsOneWidget);

    await tester.tap(find.text('共享盘'));
    await tester.pumpAndSettle();
    expect(find.text('资料夹'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('searches authorized names and reports a truncated result set', (
    tester,
  ) async {
    final api = _FilesTestApi();
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(body: FilesPage(api: api, isAdmin: false)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'plan');
    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();

    expect(find.text('搜索结果'), findsOneWidget);
    expect(find.text('计划说明.txt'), findsOneWidget);
    expect(find.textContaining('达到服务端上限'), findsOneWidget);
    expect(
      api.requests.any(
        (request) =>
            request.path == '/api/v2/files/search' &&
            request.queryParameters['query'] == 'plan',
      ),
      isTrue,
    );
  });

  testWidgets('admin purge asks for confirmation before permanent deletion', (
    tester,
  ) async {
    final api = _FilesTestApi();
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(body: FilesPage(api: api, isAdmin: true)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多文件操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('回收站'));
    await tester.pumpAndSettle();
    expect(find.text('待清理.txt'), findsOneWidget);

    await tester.tap(find.byTooltip('永久删除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('此操作无法撤销。'), findsOneWidget);
    expect(
      api.requests.where((request) => request.path.contains('/trash/')),
      isEmpty,
    );

    await tester.tap(find.widgetWithText(FilledButton, '永久删除'));
    await tester.pumpAndSettle();
    expect(
      api.requests.any(
        (request) =>
            request.method == 'DELETE' &&
            request.path ==
                '/api/v2/files/trash/0123456789abcdef0123456789abcdef',
      ),
      isTrue,
    );
  });

  testWidgets('batch trash validates and submits selected writable paths', (
    tester,
  ) async {
    final api = _FilesTestApi(writable: true);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(body: FilesPage(api: api, isAdmin: false)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('资料夹'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.bySemanticsLabel('选择 资料夹'));
    await tester.pumpAndSettle();

    expect(find.text('已选 1 项 · 每次最多 50 项'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '批量移到回收站'));
    await tester.pumpAndSettle();
    expect(find.textContaining('将选中的 1 项移到回收站？'), findsOneWidget);
    expect(api.batchBody, isNull);

    await tester.tap(find.widgetWithText(FilledButton, '移入回收站'));
    await tester.pumpAndSettle();

    expect(api.batchBody, {
      'action': 'trash',
      'paths': ['资料夹'],
    });
    expect(find.text('已选 1 项 · 每次最多 50 项'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'batch trash confirmation cannot act after physical root changes',
    (tester) async {
      final api = _FilesTestApi(writable: true);
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FilesPage(api: api, isAdmin: false)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.longPress(find.text('资料夹'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '批量移到回收站'));
      await tester.pumpAndSettle();
      expect(api.batchBody, isNull);

      // The root can change while a native confirmation dialog is on screen.
      // Never send the old selected paths to the newly selected physical disk.
      api.selectRoot(
        const LightIsleRoot(
          id: 'another_disk',
          name: '其他硬盘',
          generation: 4,
          online: true,
        ),
      );
      await tester.tap(find.widgetWithText(FilledButton, '移入回收站'));
      await tester.pumpAndSettle();

      expect(api.batchBody, isNull);
      expect(find.text('共享目录或选择已变化，未执行批量删除。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pull-to-refresh inside trash stays in trash and reloads trash entries',
    (tester) async {
      final api = _FilesTestApi(writable: true);
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FilesPage(api: api, isAdmin: true)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多文件操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('回收站'));
      await tester.pumpAndSettle();
      expect(find.text('待清理.txt'), findsOneWidget);

      final trashCallsBefore = api.requests
          .where((r) => r.path == '/api/v2/files/trash')
          .length;
      final refresh = tester.widget<RefreshIndicator>(
        find.byType(RefreshIndicator),
      );
      await refresh.onRefresh();
      await tester.pumpAndSettle();

      final trashCallsAfter = api.requests
          .where((r) => r.path == '/api/v2/files/trash')
          .length;
      expect(trashCallsAfter, greaterThan(trashCallsBefore));
      expect(find.text('待清理.txt'), findsOneWidget);
    },
  );

  testWidgets(
    'clearing search restores the directory active before searching',
    (tester) async {
      final api = _FilesTestApi(writable: true);
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FilesPage(api: api, isAdmin: false)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('资料夹'));
      await tester.pumpAndSettle();
      expect(api.requests.last.queryParameters['path'], '资料夹');

      await tester.enterText(find.byType(TextField).first, '计划');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(api.requests.any((r) => r.path == '/api/v2/files/search'), isTrue);

      await tester.tap(find.byTooltip('清除搜索'));
      await tester.pumpAndSettle();
      expect(api.requests.last.path, '/api/v2/files');
      expect(api.requests.last.queryParameters['path'], '资料夹');
    },
  );

  testWidgets(
    'destination dialog allows creating a new folder in place when writable',
    (tester) async {
      final api = _FilesTestApi(writable: true);
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FilesPage(api: api, isAdmin: false)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('文件操作').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('移动到…').last);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('destination-new-folder')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('destination-new-folder')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '归档目录');
      await tester.tap(find.widgetWithText(FilledButton, '创建'));
      await tester.pumpAndSettle();

      expect(
        api.requests.any(
          (r) =>
              r.method == 'POST' &&
              r.path == '/api/v2/files/folders' &&
              (r.body as Map?)?['path'] == '归档目录',
        ),
        isTrue,
      );
      await tester.tap(find.widgetWithText(TextButton, '取消').last);
      await tester.pumpAndSettle();
    },
  );

  testWidgets('rename dialog preselects file stem without extension', (
    tester,
  ) async {
    final api = _FilesTestApi(writable: true);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FilesPage(api: api, isAdmin: false)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('文件操作').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名').last);
    await tester.pumpAndSettle();

    final textField = tester.widget<TextField>(
      find.descendant(
        of: find.widgetWithText(AlertDialog, '重命名'),
        matching: find.byType(TextField),
      ),
    );
    expect(textField.controller?.text, '计划说明.txt');
    expect(textField.controller?.selection.baseOffset, 0);
    expect(textField.controller?.selection.extentOffset, 4);
    await tester.tap(find.widgetWithText(TextButton, '取消').last);
    await tester.pumpAndSettle();
  });

  _registerFilesPreviewExportTests();
}
