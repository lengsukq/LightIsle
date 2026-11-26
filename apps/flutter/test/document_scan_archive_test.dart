import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/document_scan_archive_page.dart';
import 'package:lightisle/features/media/photos_page.dart';
import 'package:lightisle/features/overview/overview_page.dart';

class _FakeScannerBridge extends DocumentScannerBridge {
  _FakeScannerBridge(this.pathsToReturn);

  final List<String> pathsToReturn;
  final List<String> requestedSources = [];

  @override
  Future<DocumentScannerCapabilities> capabilities() async {
    return const DocumentScannerCapabilities(
      scanner: true,
      camera: true,
      picker: true,
    );
  }

  @override
  Future<DocumentCaptureResult> capture({String source = 'scanner'}) async {
    requestedSources.add(source);
    return DocumentCaptureResult(
      paths: pathsToReturn,
      cancelled: false,
      source: 'visionkit',
    );
  }
}

class _ArchiveFakeApi extends LightIsleApi {
  _ArchiveFakeApi() : super('http://127.0.0.1:16666');

  final List<Map<String, Object?>> sendCalls = [];
  final List<Map<String, Object?>> getCalls = [];
  final List<Map<String, Object?>> uploadChunkCalls = [];
  int _aiPollCount = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    getCalls.add({'path': path, 'query': query});
    if (path == '/api/v2/me/storage') {
      return {
        'userId': 2,
        'locations': [
          {
            'category': 'photos',
            'rootID': 'root-1',
            'rootGeneration': 1,
            'relativePath': 'Users/alice/photos',
          },
        ],
        'enforcement': 'pending',
        'usageComplete': false,
      };
    }
    if (path == '/api/v2/photos') {
      final q = query?['q'] ?? '';
      final prefix = query?['pathPrefix'] ?? '';
      if (q.contains('医保报销')) {
        return {
          'assets': [
            {
              'id': 501,
              'path': 'Users/alice/photos/家庭档案/发票/20260922_医保报销单.jpg',
              'name': '20260922_医保报销单.jpg',
              'type': 'photo',
              'size': 2048,
              'takenAt': 1700000000,
              'favorite': false,
              'canWrite': true,
            },
          ],
          'nextCursor': 0,
        };
      }
      if (prefix.startsWith('Users/alice/photos/家庭档案')) {
        return {
          'assets': [
            {
              'id': 500,
              'path': 'Users/alice/photos/家庭档案/证件/id_card.jpg',
              'name': 'id_card.jpg',
              'type': 'photo',
              'size': 1024,
              'takenAt': 1700000000,
              'favorite': false,
              'canWrite': true,
            },
          ],
          'nextCursor': 0,
        };
      }
      return {'assets': [], 'nextCursor': 0};
    }
    if (path == '/api/v2/photos/501/ai') {
      _aiPollCount++;
      if (_aiPollCount == 1) {
        return {
          'assetId': 501,
          'indexed': false,
          'status': 'pending',
          'ocrText': '',
        };
      }
      return {
        'assetId': 501,
        'indexed': true,
        'status': 'ok',
        'ocrText': '增值税电子普通发票 医保报销 实付 368.50 元',
      };
    }
    if (path == '/api/v2/photos/status') {
      return {'status': {'running': false}, 'count': 0};
    }
    if (path == '/api/v2/photos/albums' ||
        path == '/api/v2/photos/private-albums') {
      return {'albums': []};
    }
    if (path == '/api/v2/photos/timeline') {
      return {'months': []};
    }
    if (path == '/api/v2/system') {
      return {'hostname': 'Mac mini', 'volumes': []};
    }
    if (path == '/api/v2/roots') {
      return {'roots': []};
    }
    if (path == '/api/v2/tasks') {
      return {'tasks': []};
    }
    if (path == '/api/v2/apps') {
      return {'apps': []};
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    sendCalls.add({'method': method, 'path': path, 'body': body});
    if (method == 'POST' && path == '/api/v2/files/folders') {
      return {'created': true};
    }
    if (method == 'POST' && path == '/api/v2/uploads') {
      final map = Map<String, dynamic>.from(body as Map);
      return {'id': 'up-doc-1', 'path': map['path'], 'offset': 0};
    }
    if (method == 'POST' && path == '/api/v2/uploads/up-doc-1/complete') {
      return {'completed': true};
    }
    if (method == 'PUT' && path == '/api/v2/files/text') {
      return {'saved': true};
    }
    if (method == 'POST' && path == '/api/v2/photos/ocr-priority') {
      final map = Map<String, dynamic>.from(body as Map);
      return {'queued': true, 'assetId': 501, 'path': map['path']};
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> uploadChunk(
    String id,
    Stream<List<int>> data,
    int length,
    int offset,
  ) async {
    await data.drain<void>();
    uploadChunkCalls.add({'id': id, 'length': length, 'offset': offset});
    return {'id': id, 'offset': offset + length};
  }

  @override
  Future<Uint8List> bytes(
    String path, {
    Map<String, String>? query,
    int? maxBytes,
  }) async {
    return Uint8List.fromList(const <int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
      0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
      0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
      0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
      0x42, 0x60, 0x82,
    ]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'DocumentScanArchivePage scans, uploads to 家庭档案/<分类>/, writes note, triggers priority OCR, polls & copies text, and searches with pathPrefix+ocr',
    (tester) async {
      final tempDir = Directory.systemTemp.createTempSync('lightisle-doc-test');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final scanFile = File('${tempDir.path}/receipt.jpg')
        ..writeAsBytesSync(const <int>[0xFF, 0xD8, 0xFF, 0xD9]);

      final api = _ArchiveFakeApi();
      addTearDown(api.close);
      final scanner = _FakeScannerBridge([scanFile.path]);

      String? clipboardText;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              final args = Map<Object?, Object?>.from(call.arguments as Map);
              clipboardText = args['text']?.toString();
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          home: DocumentScanArchivePage(
            api: api,
            scannerBridge: scanner,
            ocrPollInterval: const Duration(milliseconds: 20),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Choose category 发票 and fill note.
      await tester.tap(find.byKey(const ValueKey('archiveCategory-发票')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('archiveNoteField')),
        '医保报销单',
      );

      // Capture via VisionKit bridge.
      await tester.tap(
        find.byKey(const ValueKey('documentScanPrimaryButton')),
      );
      await tester.pumpAndSettle();
      expect(scanner.requestedSources, ['scanner']);
      expect(find.byKey(const ValueKey('uploadAndOcrButton')), findsOneWidget);

      // Upload + write note + trigger priority OCR + poll OCR result.
      final uploadBtn = find.byKey(const ValueKey('uploadAndOcrButton'));
      await tester.ensureVisible(uploadBtn);
      await tester.pumpAndSettle();
      await tester.tap(uploadBtn);
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 30));
      }

      // Verify folder creation, upload path, note write, and ocr-priority call.
      final uploadBegin = api.sendCalls.firstWhere(
        (c) => c['method'] == 'POST' && c['path'] == '/api/v2/uploads',
      );
      final uploadPath = (uploadBegin['body'] as Map)['path'].toString();
      expect(
        uploadPath,
        startsWith('Users/alice/photos/家庭档案/发票/'),
      );
      expect(uploadPath, endsWith('.jpg'));
      expect(api.uploadChunkCalls, hasLength(1));

      expect(
        api.sendCalls.any(
          (c) =>
              c['method'] == 'PUT' &&
              c['path'] == '/api/v2/files/text' &&
              ((c['body'] as Map)['content'] as String).contains('医保报销单'),
        ),
        isTrue,
      );
      expect(
        api.sendCalls.any(
          (c) =>
              c['method'] == 'POST' &&
              c['path'] == '/api/v2/photos/ocr-priority' &&
              (c['body'] as Map)['path'] == uploadPath,
        ),
        isTrue,
      );

      expect(
        find.text('增值税电子普通发票 医保报销 实付 368.50 元'),
        findsOneWidget,
      );

      // Copy OCR text.
      await tester.tap(find.byKey(const ValueKey('copyScannedOcrButton')));
      await tester.pump();
      expect(clipboardText, '增值税电子普通发票 医保报销 实付 368.50 元');

      // Search archived documents using pathPrefix + searchMode=ocr.
      final searchField = find.descendant(
        of: find.byKey(const ValueKey('archiveOcrSearchField')),
        matching: find.byType(TextField),
      );
      await tester.enterText(searchField, '医保报销');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(
        api.getCalls.any((c) {
          final q = c['query'] as Map<String, String>?;
          return c['path'] == '/api/v2/photos' &&
              q?['pathPrefix'] == 'Users/alice/photos/家庭档案' &&
              q?['searchMode'] == 'ocr' &&
              q?['q'] == '医保报销';
        }),
        isTrue,
      );
      expect(find.text('20260922_医保报销单.jpg'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('OverviewPage and PhotosPage expose family archive entry points', (
    tester,
  ) async {
    final api = _ArchiveFakeApi();
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.light),
        home: Scaffold(body: OverviewPage(api: api, isAdmin: false)),
      ),
    );
    await tester.pumpAndSettle();
    final overviewEntry = find.byKey(
      const ValueKey('overviewDocumentScanEntry'),
    );
    await tester.scrollUntilVisible(
      overviewEntry,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(overviewEntry, findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.light),
        home: Scaffold(
          body: PhotosPage(
            api: api,
            isAdmin: false,
            uploadDirectory: 'Users/alice/photos',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('photosDocumentArchiveChip')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
