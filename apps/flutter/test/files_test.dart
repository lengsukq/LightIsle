import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/files/file_shares_page.dart';
import 'package:lightisle/features/files/files_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  testWidgets('sort and folder picker use server ordering and safe conflict policy', (
    tester,
  ) async {
    final api = _FilesTestApi(writable: true);
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: FilesPage(api: api, isAdmin: false)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('文件排序方式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改时间 · 最新优先').last);
    await tester.pumpAndSettle();
    expect(api.requests.any((request) =>
        request.path == '/api/v2/files' &&
        request.queryParameters['sort'] == 'mtime' &&
        request.queryParameters['dir'] == 'desc'), isTrue);

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

    expect(api.requests.any((request) {
      if (request.path != '/api/v2/files/operations' ||
          request.method != 'POST') {
        return false;
      }
      final body = request.body as Map;
      return body['action'] == 'copy' &&
          body['from'] == '计划说明.txt' &&
          body['to'] == '资料夹/计划说明.txt' &&
          body['conflict'] == 'rename';
    }), isTrue);
    expect(tester.takeException(), isNull);
  });

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
    await tester.tap(find.text('搜索'));
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
    await tester.ensureVisible(find.bySemanticsLabel('选择 资料夹 移入回收站'));
    await tester.tap(find.bySemanticsLabel('选择 资料夹 移入回收站'));
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

  testWidgets('files layout fits narrow, tablet, wide, and 200% text sizes', (
    tester,
  ) async {
    final api = _FilesTestApi(writable: true);
    addTearDown(api.close);
    const viewports = [
      (width: 320.0, scale: 1.0, select: true),
      (width: 600.0, scale: 1.0, select: false),
      (width: 1280.0, scale: 1.0, select: false),
      (width: 320.0, scale: 2.0, select: true),
    ];
    var hasSelected = false;

    for (final viewport in viewports) {
      tester.view.physicalSize = Size(viewport.width, 900);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(
                size: Size(viewport.width, 900),
                textScaler: TextScaler.linear(viewport.scale),
              ),
              child: FilesPage(api: api, isAdmin: false),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // At 200% text the responsive toolbar is taller than the initial
      // viewport. A lazily-built ListView child is not mounted until the
      // user scrolls to it; ensure the file list is actually reachable.
      if (find.text('计划说明.txt').evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          find.text('计划说明.txt'),
          160,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 20,
        );
        await tester.pumpAndSettle();
      }
      expect(
        find.text('计划说明.txt'),
        findsOneWidget,
        reason: 'width=${viewport.width} scale=${viewport.scale}',
      );
      if (viewport.select && !hasSelected) {
        await tester.ensureVisible(find.bySemanticsLabel('选择 资料夹 移入回收站'));
        await tester.pumpAndSettle();
        await tester.tap(find.bySemanticsLabel('选择 资料夹 移入回收站'));
        await tester.pumpAndSettle();
        hasSelected = true;
      }
      if (viewport.select) {
        expect(find.text('批量移到回收站'), findsOneWidget);
      }
      expect(
        tester.takeException(),
        isNull,
        reason: '${viewport.width}px at ${viewport.scale}x text',
      );
    }
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  });

  testWidgets('mobile export streams to temporary storage and cleans it up', (
    tester,
  ) async {
    final tempRoot = Directory.systemTemp.createTempSync(
      'lightisle-files-test-',
    );
    final exportDirectory = Directory('${tempRoot.path}/export')..createSync();
    final api = _DownloadTestApi();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    const exportChannel = MethodChannel('lightisle/export');
    addTearDown(api.close);
    addTearDown(() {
      messenger.setMockMethodCallHandler(pathProviderChannel, null);
      messenger.setMockMethodCallHandler(exportChannel, null);
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });
    messenger.setMockMethodCallHandler(pathProviderChannel, (call) async {
      expect(call.method, 'getTemporaryDirectory');
      return tempRoot.path;
    });

    String? exportedPath;
    messenger.setMockMethodCallHandler(exportChannel, (call) async {
      expect(call.method, 'exportFile');
      final arguments = Map<String, Object?>.from(call.arguments as Map);
      exportedPath = arguments['path'] as String;
      expect(arguments['name'], '说明.txt');
      expect(File(exportedPath!).readAsStringSync(), 'test bytes');
      return 'content://downloads/document/1';
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: FilesPage(
            api: api,
            isAdmin: false,
            mobileExportOverride: true,
            exportDirectoryFactory: (_) async => exportDirectory,
            exportDirectoryCleanup: (directory) async {
              directory.deleteSync(recursive: true);
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('说明.txt'), findsOneWidget);

    await tester.tap(find.byTooltip('文件操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('已保存到所选位置：content://downloads/document/1'),
      findsOneWidget,
    );
    expect(exportedPath, isNotNull);
    expect(File(exportedPath!).existsSync(), isFalse);
    expect(tempRoot.listSync(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('folder download uses the archive endpoint and exports a ZIP', (
    tester,
  ) async {
    final tempRoot = Directory.systemTemp.createTempSync(
      'lightisle-archive-test-',
    );
    final exportDirectory = Directory('${tempRoot.path}/export')..createSync();
    final api = _FilesParityTestApi();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    const exportChannel = MethodChannel('lightisle/export');
    addTearDown(api.close);
    addTearDown(() {
      messenger.setMockMethodCallHandler(pathProviderChannel, null);
      messenger.setMockMethodCallHandler(exportChannel, null);
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });
    messenger.setMockMethodCallHandler(pathProviderChannel, (call) async {
      return tempRoot.path;
    });
    String? exportedName;
    messenger.setMockMethodCallHandler(exportChannel, (call) async {
      final arguments = Map<String, Object?>.from(call.arguments as Map);
      exportedName = arguments['name'] as String;
      expect(File(arguments['path'] as String).readAsStringSync(), 'zip bytes');
      return 'saved.zip';
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: FilesPage(
            api: api,
            isAdmin: false,
            mobileExportOverride: true,
            exportDirectoryFactory: (_) async => exportDirectory,
            exportDirectoryCleanup: (directory) async {
              directory.deleteSync(recursive: true);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('文件操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载文件夹 ZIP'));
    await tester.pumpAndSettle();

    expect(api.downloads.single.path, '/api/v2/files/archive');
    expect(api.downloads.single.queryParameters, {'path': '资料夹'});
    expect(exportedName, '资料夹.zip');
    expect(find.textContaining('已保存到所选位置：saved.zip'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'file share creates a one-time public link with selected expiry',
    (tester) async {
      final api = _FilesParityTestApi();
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(body: FilesPage(api: api, isAdmin: false)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('文件操作').at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('分享文件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成分享链接'));
      await tester.pumpAndSettle();

      final request = api.sent.single;
      expect(request.method, 'POST');
      expect(request.path, '/api/v2/file-shares');
      expect(request.body, {'path': '说明.txt', 'hours': 24});
      final linkField = tester.widget<TextField>(find.byType(TextField).last);
      expect(
        linkField.controller!.text,
        'http://127.0.0.1:1/api/v2/public/file/demo-token',
      );
      expect(find.text('复制分享链接'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('my shares page lists and revokes the current user link', (
    tester,
  ) async {
    final api = _FilesParityTestApi(withShare: true);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: FileSharesPage(api: api),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Docs/说明.txt'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, '撤销链接'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '撤销链接'));
    await tester.pumpAndSettle();

    expect(api.sent.single.method, 'DELETE');
    expect(api.sent.single.path, '/api/v2/file-shares/share-id');
    expect(find.text('当前没有有效的分享链接。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('video preview asks the API for its authenticated media URI', (
    tester,
  ) async {
    final api = _FilesParityTestApi(withVideo: true);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(body: FilesPage(api: api, isAdmin: false)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('clip.mp4'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('clip.mp4'));
    await tester.pumpAndSettle();

    expect(api.mediaRequests, hasLength(1));
    expect(api.mediaRequests.single.path, '/api/v2/files/preview');
    expect(api.mediaRequests.single.queryParameters, {'path': 'clip.mp4'});
    expect(find.text('关闭'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _RecordedRequest {
  const _RecordedRequest(
    this.method,
    this.path,
    this.queryParameters, [
    this.body,
  ]);

  final String method;
  final String path;
  final Map<String, String> queryParameters;
  final Object? body;
}

class _FilesTestApi extends LightIsleApi {
  _FilesTestApi({this.writable = false})
    : super('http://127.0.0.1:1', httpClient: _NoopHttpClient());

  final bool writable;
  final List<_RecordedRequest> requests = [];
  Object? batchBody;
  final List<Map<String, Object?>> trash = [
    {
      'id': '0123456789abcdef0123456789abcdef',
      'name': '待清理.txt',
      'originalPath': 'Docs/待清理.txt',
      'deletedAt': '2026-10-20T12:00:00Z',
    },
  ];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    requests.add(_RecordedRequest('GET', path, query ?? const {}));
    if (path == '/api/v2/files/root') return {'name': '共享盘'};
    if (path == '/api/v2/files/search') {
      return {
        'entries': [_entry('计划说明.txt', '计划说明.txt', 'file', 128)],
        'truncated': true,
        'canWrite': writable,
      };
    }
    if (path == '/api/v2/files/trash') return {'entries': trash};
    if (path == '/api/v2/files') {
      final directory = query?['path'] ?? '.';
      return {
        'path': directory,
        'entries': directory == '.'
            ? [
                _entry('资料夹', '资料夹', 'folder', 0),
                _entry('计划说明.txt', '计划说明.txt', 'file', 128),
              ]
            : <Map<String, Object?>>[],
        'nextCursor': '',
        'canWrite': writable,
      };
    }
    throw StateError('Unexpected API request: $path');
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    requests.add(_RecordedRequest(method, path, query ?? const {}, body));
    if (method == 'POST' && path == '/api/v2/files/batch') {
      batchBody = body;
      final paths = (body as Map)['paths'] as List;
      return {
        'results': [
          for (final item in paths) {'path': item, 'success': true},
        ],
      };
    }
    if (method == 'DELETE' && path.startsWith('/api/v2/files/trash/')) {
      final id = path.split('/').last;
      trash.removeWhere((entry) => entry['id'] == id);
      return {'deleted': true};
    }
    if (method == 'POST' && path.endsWith('/restore')) {
      return {'restored': true};
    }
    return {};
  }

  Map<String, Object?> _entry(
    String name,
    String path,
    String type,
    int size,
  ) => {
    'name': name,
    'path': path,
    'type': type,
    'size': size,
    'modified': '2026-10-21T10:30:00Z',
    'canWrite': writable,
  };
}

class _DownloadTestApi extends LightIsleApi {
  _DownloadTestApi()
    : super('http://127.0.0.1:1', httpClient: _NoopHttpClient());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/files/root') return {'name': '共享盘'};
    if (path == '/api/v2/files') {
      return {
        'entries': [
          {
            'name': '说明.txt',
            'path': '说明.txt',
            'type': 'file',
            'size': 10,
            'canWrite': false,
          },
        ],
        'nextCursor': '',
        'canWrite': false,
      };
    }
    throw StateError('Unexpected API request: $path');
  }

  @override
  Future<void> download(
    String path,
    String destination, {
    Map<String, String>? query,
    void Function(int, int)? onProgress,
  }) async {
    File(destination).writeAsStringSync('test bytes');
    onProgress?.call(10, 10);
  }
}

class _FilesParityTestApi extends LightIsleApi {
  _FilesParityTestApi({this.withShare = false, this.withVideo = false})
    : super('http://127.0.0.1:1', httpClient: _NoopHttpClient());

  final bool withShare;
  final bool withVideo;
  final List<_RecordedRequest> sent = [];
  final List<_RecordedRequest> downloads = [];
  final List<_RecordedRequest> mediaRequests = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/files/root') return {'name': '共享盘'};
    if (path == '/api/v2/files') {
      final entries = <Map<String, Object?>>[
        _entry('资料夹', '资料夹', 'folder'),
        _entry('说明.txt', '说明.txt', 'file'),
        if (withVideo) _entry('clip.mp4', 'clip.mp4', 'file'),
      ];
      return {'entries': entries, 'nextCursor': '', 'canWrite': false};
    }
    if (path == '/api/v2/file-shares') {
      return {
        'shares': withShare
            ? [
                {
                  'id': 'share-id',
                  'path': 'Docs/说明.txt',
                  'createdAt': 1792756800,
                  'expiresAt': 1793361600,
                },
              ]
            : [],
      };
    }
    throw StateError('Unexpected API request: $path');
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    final request = _RecordedRequest(method, path, query ?? const {}, body);
    sent.add(request);
    if (method == 'POST' && path == '/api/v2/file-shares') {
      return {'token': 'demo-token', 'share': <String, Object?>{}};
    }
    return {'revoked': true};
  }

  @override
  Future<void> download(
    String path,
    String destination, {
    Map<String, String>? query,
    void Function(int, int)? onProgress,
  }) async {
    downloads.add(_RecordedRequest('GET', path, query ?? const {}));
    File(
      destination,
    ).writeAsStringSync(path.endsWith('/archive') ? 'zip bytes' : 'file bytes');
    onProgress?.call(10, 10);
  }

  @override
  Future<Uri> mediaUri(String path, {Map<String, String>? query}) async {
    mediaRequests.add(_RecordedRequest('GET', path, query ?? const {}));
    return Uri.parse('http://127.0.0.1:1/native-media');
  }

  Map<String, Object?> _entry(String name, String path, String type) => {
    'name': name,
    'path': path,
    'type': type,
    'size': 10,
    'modified': '2026-10-21T10:30:00Z',
    'canWrite': false,
  };
}

class _NoopHttpClient extends Fake implements HttpClient {
  @override
  void close({bool force = false}) {}
}
