import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_cache_manager.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/files/collect_links_sheet.dart';
import 'package:lightisle/features/files/file_comic_epub_reader_page.dart';
import 'package:lightisle/features/files/file_text_preview_dialog.dart';
import 'package:lightisle/features/files/files_page.dart';
import 'package:lightisle/features/files/offline_file_store.dart';
import 'package:lightisle/features/files/offline_vault_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Valid 1x1 transparent PNG bytes.
final Uint8List _kTinyPng = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _FakeExtrasApi extends LightIsleApi {
  _FakeExtrasApi() : super('http://127.0.0.1:18888') {
    selectRoot(
      const LightIsleRoot(
        id: 'root-main',
        name: '家庭主盘',
        generation: 2,
        online: true,
        isDefault: true,
      ),
    );
  }

  final List<({String method, String path, Map<String, String> query, Object? body})>
      calls = [];

  List<Map<String, dynamic>> collectLinks = [
    {
      'id': 'col-1',
      'rootId': 'root-main',
      'rootGeneration': 2,
      'targetPath': '家庭相册',
      'title': '春节合影收集',
      'hasPassword': true,
      'maxFiles': 50,
      'maxFileBytes': 104857600,
      'maxTotalBytes': 1073741824,
      'uploadedFiles': 3,
      'uploadedBytes': 15728640,
      'createdAt': 1760000000,
      'expiresAt': 1990000000,
    },
  ];

  List<Map<String, dynamic>> pins = [
    {
      'rootId': 'root-main',
      'rootGeneration': 2,
      'path': '家庭相册',
      'kind': 'folder',
      'label': '家庭相册',
      'pinnedAt': 1760000000,
      'exists': true,
      'canWrite': true,
    },
  ];

  String textContent = '# 家庭清单\n\n- [x] 买菜\n- [ ] 交水电费\n';
  int textMtime = 1000001;
  bool forceSaveConflict = false;
  String? savedReadingLocator;
  double? savedReadingPercent;
  String initialReadingLocator = 'page:1';

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    calls.add((method: 'GET', path: path, query: query ?? const {}, body: null));
    if (path == '/api/v2/roots/root-main/collect-links') {
      return {'links': collectLinks};
    }
    if (path == '/api/v2/admin/tailscale') {
      return {'boundUrl': 'https://nas.example.com'};
    }
    if (path == '/api/v2/files/root') return {'name': '家庭主盘'};
    if (path == '/api/v2/files/pins') return {'pins': pins};
    if (path == '/api/v2/files') {
      return {
        'path': query?['path'] ?? '.',
        'entries': [
          {
            'name': '家庭相册',
            'path': '家庭相册',
            'type': 'folder',
            'size': 0,
            'canWrite': true,
          },
          {
            'name': '合同.docx',
            'path': '合同.docx',
            'type': 'file',
            'size': 4096,
            'canWrite': true,
          },
        ],
        'nextCursor': '',
        'canWrite': true,
      };
    }
    if (path == '/api/v2/files/insights') {
      final mode = query?['mode'] ?? 'large';
      return {
        'mode': mode,
        'scannedFiles': 120,
        'matchedFiles': 1,
        'totalBytes': 120 * 1024 * 1024,
        'truncated': false,
        'timedOut': false,
        'items': [
          {
            'name': mode == 'large' ? '4K旅游录像.mp4' : '今日票据.pdf',
            'path': mode == 'large' ? '家庭相册/4K旅游录像.mp4' : '家庭相册/今日票据.pdf',
            'parentDir': '家庭相册',
            'size': mode == 'large' ? 120 * 1024 * 1024 : 512000,
            'modified': '2026-11-26T08:00:00Z',
            'modifiedAt': 1795593600,
            'canWrite': true,
          },
        ],
      };
    }
    if (path == '/api/v2/files/text') {
      return {
        'path': query?['path'] ?? 'notes/todo.md',
        'name': 'todo.md',
        'content': textContent,
        'size': utf8.encode(textContent).length,
        'mtimeUnixNano': textMtime,
        'modified': '2026-11-26T08:00:00Z',
        'canWrite': true,
      };
    }
    if (path == '/api/v2/files/archive-entries') {
      final p = query?['path'] ?? '';
      if (p.endsWith('.epub')) {
        return {
          'path': p,
          'format': 'epub',
          'size': 4096,
          'mtimeUnixNano': 10,
          'entryCount': 3,
          'entries': [
            {'name': 'OEBPS/content.opf', 'size': 300, 'mime': 'application/xml', 'kind': 'metadata'},
            {'name': 'OEBPS/ch2.xhtml', 'size': 200, 'mime': 'application/xhtml+xml', 'kind': 'document'},
            {'name': 'OEBPS/ch1.xhtml', 'size': 200, 'mime': 'application/xhtml+xml', 'kind': 'document'},
          ],
        };
      }
      return {
        'path': p,
        'format': 'cbz',
        'size': 2048,
        'mtimeUnixNano': 10,
        'entryCount': 2,
        'entries': [
          {'name': '001.png', 'size': _kTinyPng.length, 'mime': 'image/png', 'kind': 'image'},
          {'name': '002.png', 'size': _kTinyPng.length, 'mime': 'image/png', 'kind': 'image'},
        ],
      };
    }
    if (path == '/api/v2/files/reading-progress') {
      return {
        'found': true,
        'progress': {
          'rootId': 'root-main',
          'rootGeneration': 2,
          'path': query?['path'] ?? '',
          'locator': initialReadingLocator,
          'percent': 50.0,
          'updatedAt': 1795593600,
        },
      };
    }
    throw StateError('Unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    calls.add((method: method, path: path, query: query ?? const {}, body: body));
    if (method == 'POST' && path == '/api/v2/roots/root-main/collect-links') {
      final b = Map<String, dynamic>.from(body as Map);
      final newLink = {
        'id': 'col-2',
        'rootId': 'root-main',
        'rootGeneration': 2,
        'targetPath': b['path'],
        'title': b['title'] ?? '新收集',
        'hasPassword': (b['password']?.toString().isNotEmpty ?? false),
        'maxFiles': b['maxFiles'] ?? 0,
        'maxFileBytes': b['maxFileBytes'] ?? 0,
        'maxTotalBytes': b['maxTotalBytes'] ?? 0,
        'uploadedFiles': 0,
        'uploadedBytes': 0,
        'createdAt': 1760000100,
        'expiresAt': 1990000100,
      };
      collectLinks = [...collectLinks, newLink];
      return {
        'link': newLink,
        'token': 'tok-collect-demo',
        'publicPath': '/api/v2/roots/root-main/public/collect/tok-collect-demo',
      };
    }
    if (method == 'DELETE' &&
        path.startsWith('/api/v2/roots/root-main/collect-links/')) {
      final id = path.split('/').last;
      collectLinks = collectLinks.where((e) => e['id'] != id).toList();
      return {'revoked': true};
    }
    if (method == 'POST' && path == '/api/v2/files/pins') {
      final b = Map<String, dynamic>.from(body as Map);
      final pin = {
        'rootId': 'root-main',
        'rootGeneration': 2,
        'path': b['path'],
        'kind': 'file',
        'label': b['label'] ?? b['path'],
        'pinnedAt': 1760000200,
        'exists': true,
        'canWrite': true,
      };
      pins = [pin, ...pins];
      return {'pin': pin};
    }
    if (method == 'DELETE' && path == '/api/v2/files/pins') {
      final target = query?['path'];
      pins = pins.where((p) => p['path'] != target).toList();
      return {'removed': true, 'path': target};
    }
    if (method == 'PUT' && path == '/api/v2/files/text') {
      if (forceSaveConflict) {
        throw const LightIsleApiException(
          code: 'file_modified_conflict',
          statusCode: 409,
          message: '文件在磁盘上已被其他设备修改，本次保存已中止。',
        );
      }
      final b = Map<String, dynamic>.from(body as Map);
      textContent = b['content'] as String;
      textMtime += 500;
      return {
        'saved': true,
        'path': b['path'],
        'size': utf8.encode(textContent).length,
        'mtimeUnixNano': textMtime,
        'modified': '2026-11-26T09:00:00Z',
      };
    }
    if (method == 'PUT' && path == '/api/v2/files/reading-progress') {
      final b = Map<String, dynamic>.from(body as Map);
      savedReadingLocator = b['locator']?.toString();
      savedReadingPercent = (b['percent'] as num?)?.toDouble();
      return {
        'progress': {
          'rootId': 'root-main',
          'rootGeneration': 2,
          'path': b['path'],
          'locator': savedReadingLocator,
          'percent': savedReadingPercent,
          'updatedAt': 1795593700,
        },
      };
    }
    return {};
  }

  @override
  Future<Uint8List> bytes(
    String path, {
    Map<String, String>? query,
    int? maxBytes,
  }) async {
    if (path == '/api/v2/files/archive-entry') {
      final entry = query?['entry'] ?? '';
      if (entry.endsWith('.opf')) {
        return Uint8List.fromList(
          utf8.encode(
            '<package><manifest>'
            '<item id="c1" href="ch1.xhtml"/>'
            '<item id="c2" href="ch2.xhtml"/>'
            '</manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>',
          ),
        );
      }
      if (entry.endsWith('ch1.xhtml')) {
        return Uint8List.fromList(
          utf8.encode(
            '<html><head><title>第一章</title><script>alert(1)</script></head>'
            '<body><h1>第一章 开始</h1><p>安全正文段落 &amp; 实体。</p></body></html>',
          ),
        );
      }
      if (entry.endsWith('ch2.xhtml')) {
        return Uint8List.fromList(
          utf8.encode('<html><body><h2>第二章 旅程</h2><p>继续阅读。</p></body></html>'),
        );
      }
      return _kTinyPng;
    }
    return Uint8List.fromList(utf8.encode(textContent));
  }

  @override
  Future<void> download(
    String path,
    String destination, {
    Map<String, String>? query,
    void Function(int, int)? onProgress,
  }) async {
    final payload = utf8.encode('# 离线文档\n无网可读内容');
    await File(destination).writeAsBytes(payload, flush: true);
    onProgress?.call(payload.length, payload.length);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('CollectLinksSheet creates, shows public/LAN URLs, and revokes', (
    tester,
  ) async {
    final api = _FakeExtrasApi();
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CollectLinksSheet(
            api: api,
            targetPath: '家庭相册',
            folderName: '家庭相册',
            isAdmin: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('春节合影收集'), findsOneWidget);
    expect(find.textContaining('已收 3/50 个文件'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('createCollectLinkBtn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('collectLinkPrimaryUrl')), findsOneWidget);
    expect(find.byKey(const ValueKey('copyCollectLinkAltBtn')), findsOneWidget);

    await tester.drag(find.byType(ListView).first, const Offset(0, -450));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('revoke-collect-col-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认撤销'));
    await tester.pumpAndSettle();

    expect(
      api.calls.any(
        (c) =>
            c.method == 'DELETE' &&
            c.path == '/api/v2/roots/root-main/collect-links/col-1',
      ),
      isTrue,
    );
    expect(find.text('春节合影收集'), findsNothing);
  });

  testWidgets('FilesPage renders pins strip, insights modes, and Office guide', (
    tester,
  ) async {
    final api = _FakeExtrasApi();
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FilesPage(
            api: api,
            isAdmin: true,
            accountName: 'alice',
            accountId: 'uid:1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('file-pin-chip-家庭相册')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('filesPinsCollapseToggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('file-pin-chip-家庭相册')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('filesQuickFilterLarge')));
    await tester.pumpAndSettle();
    expect(find.text('4K旅游录像.mp4'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('filesQuickFilterRecent')));
    await tester.pumpAndSettle();
    expect(find.text('今日票据.pdf'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('filesQuickFilterBrowse')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('合同.docx').last);
    await tester.pumpAndSettle();
    expect(find.text('用系统应用预览'), findsOneWidget);
    expect(find.text('离线保存后打开'), findsOneWidget);
  });

  test('OfflineFileStore isolates from temp cache clear and verifies SHA-256', () async {
    final tempDir = await Directory.systemTemp.createTemp('isle-offline-vault-');
    addTearDown(() async {
      IsleCacheManager.instance.setDiskRootForTesting(null);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });
    IsleCacheManager.instance.setDiskRootForTesting(tempDir);

    final api = _FakeExtrasApi();
    addTearDown(api.close);

    final store = OfflineFileStore(
      api: api,
      accountIdentity: 'uid:1',
      applicationDirectory: tempDir,
    );
    final payloadBytes = utf8.encode('# 离线文档\n无网可读内容').length;
    final entry = await store.save(
      FileEntry(
        name: 'readme.md',
        path: 'docs/readme.md',
        type: 'file',
        size: payloadBytes,
        modified: null,
        canWrite: true,
      ),
    );
    expect(entry.rootId, 'root-main');
    expect(entry.generation, 2);
    expect(entry.sha256.length, 64);

    // Clearing all temporary caches must NEVER delete offline files.
    await IsleCacheManager.instance.clearCategories(
      IsleCacheCategory.values.toSet(),
    );
    final listed = await store.list();
    expect(listed, hasLength(1));
    final verified = await store.fileFor(listed.single);
    expect(await verified.exists(), isTrue);

    // Tampering with local bytes triggers SHA-256 integrity failure.
    await verified.writeAsBytes(List<int>.filled(payloadBytes, 0x41), flush: true);
    await expectLater(store.fileFor(listed.single), throwsFormatException);

    await store.remove(listed.single);
    expect(await store.list(), isEmpty);
  });

  testWidgets('OfflineVaultPage opens saved markdown offline and removes it', (
    tester,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync('isle-vault-page-');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final api = _FakeExtrasApi();
    addTearDown(api.close);

    final store = OfflineFileStore(
      api: api,
      accountIdentity: 'uid:1',
      applicationDirectory: tempDir,
    );
    await tester.runAsync(
      () => store.save(
        FileEntry(
          name: 'guide.md',
          path: 'docs/guide.md',
          type: 'file',
          size: utf8.encode('# 离线文档\n无网可读内容').length,
          modified: null,
          canWrite: false,
        ),
      ),
    );

    Future<void> pumpIo() async {
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
    }

    await tester.pumpWidget(
      MaterialApp(
        home: OfflineVaultPage(
          api: api,
          accountId: 'uid:1',
          applicationDirectory: tempDir,
        ),
      ),
    );
    await pumpIo();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('offline-file-docs/guide.md')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('offline-file-docs/guide.md')));
    await pumpIo();
    await tester.pumpAndSettle();
    expect(find.textContaining('无网可读内容'), findsOneWidget);
  });

  testWidgets('Markdown dialog edits, saves with mtime, and preserves draft on 409', (
    tester,
  ) async {
    final api = _FakeExtrasApi();
    addTearDown(api.close);
    const mdItem = FileEntry(
      name: 'todo.md',
      path: 'notes/todo.md',
      type: 'file',
      size: 40,
      modified: null,
      canWrite: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FileTextPreviewDialog(
            item: mdItem,
            badge: const Icon(Icons.description),
            text: api.textContent,
            api: api,
            canEdit: true,
            onOpenExternal: () {},
            onDownload: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SafeMarkdownView), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('textDialogEditModeChip')));
    await tester.pumpAndSettle();

    api.forceSaveConflict = true;
    await tester.enterText(
      find.byKey(const ValueKey('textDialogEditorField')),
      '# 我的冲突草稿',
    );
    await tester.tap(find.byKey(const ValueKey('textDialogSaveBtn')));
    await tester.pumpAndSettle();

    expect(find.textContaining('已被其他设备修改'), findsOneWidget);
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('textDialogEditorField')),
    );
    expect(field.controller?.text, '# 我的冲突草稿');

    api.forceSaveConflict = false;
    await tester.tap(find.byKey(const ValueKey('textDialogSaveBtn')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已安全保存到 NAS'), findsOneWidget);
    expect(api.textContent, '# 我的冲突草稿');
  });

  test('EPUB parser strips scripts and resolves OPF spine order', () {
    final parsed = parseSafeEpubDocument(
      '<html><head><title>测试书</title><script>evil()</script></head>'
      '<body><h1>标题</h1><p>第一段 &amp; 第二句</p></body></html>',
    );
    expect(parsed.title, '测试书');
    expect(parsed.blocks.map((b) => b.text).join('\n'), isNot(contains('evil')));
    expect(parsed.blocks.last.text, '第一段 & 第二句');

    final spine = parseEpubOpfSpine(
      '<package><manifest><item id="a" href="ch1.xhtml"/><item id="b" href="ch2.xhtml"/></manifest>'
      '<spine><itemref idref="b"/><itemref idref="a"/></spine></package>',
      'OEBPS/content.opf',
    );
    expect(spine, ['OEBPS/ch2.xhtml', 'OEBPS/ch1.xhtml']);
  });

  testWidgets('Comic/EPUB reader restores progress, toggles mode, and renders EPUB', (
    tester,
  ) async {
    final api = _FakeExtrasApi();
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: FileComicEpubReaderPage(
          api: api,
          item: const FileEntry(
            name: 'vol1.cbz',
            path: 'comics/vol1.cbz',
            type: 'file',
            size: 2048,
            modified: null,
            canWrite: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('comicModeToggleBtn')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('comicVerticalList')), findsOneWidget);

    api.initialReadingLocator = 'chapter:0:OEBPS/ch1.xhtml';
    await tester.pumpWidget(
      MaterialApp(
        home: FileComicEpubReaderPage(
          api: api,
          item: const FileEntry(
            name: 'book.epub',
            path: 'books/book.epub',
            type: 'file',
            size: 4096,
            modified: null,
            canWrite: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('安全正文段落 & 实体。'), findsOneWidget);
    expect(find.textContaining('alert'), findsNothing);
    await tester.tap(find.byTooltip('下一章'));
    await tester.pumpAndSettle();
    expect(find.textContaining('第二章 旅程'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 700));
    expect(api.savedReadingLocator, 'chapter:1:OEBPS/ch2.xhtml');
  });
}
