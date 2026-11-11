import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/core/user_facing_error.dart';
import 'package:lightisle/features/files/duplicate_files_page.dart';
import 'package:lightisle/features/media/media_models.dart';
import 'package:lightisle/features/media/photo_ai_models.dart';
import 'package:lightisle/features/media/photo_live_text_card.dart';

class _FakeAIApi extends LightIsleApi {
  _FakeAIApi() : super('http://localhost:16666');

  final requests = <(String, String, Map<String, String>?, Object?)>[];
  Map<String, dynamic> Function(String path, Map<String, String>? query)? onGet;
  Map<String, dynamic> Function(String method, String path, Object? body)?
  onSend;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    requests.add(('GET', path, query, null));
    if (onGet != null) return onGet!(path, query);
    return <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    requests.add((method, path, query, body));
    if (onSend != null) return onSend!(method, path, body);
    return <String, dynamic>{};
  }
}

void main() {
  test('appendPhotoAISearchQuery attaches personId and searchMode cleanly', () {
    final q1 = <String, String>{};
    appendPhotoAISearchQuery(
      q1,
      searchTerm: '',
      searchMode: PhotoSearchMode.ocr,
      personId: 0,
    );
    expect(q1, isEmpty);

    final q2 = <String, String>{};
    appendPhotoAISearchQuery(
      q2,
      searchTerm: '发票',
      searchMode: PhotoSearchMode.ocr,
      personId: 9,
    );
    expect(q2['personId'], '9');
    expect(q2['searchMode'], 'ocr');

    final q3 = <String, String>{};
    appendPhotoAISearchQuery(
      q3,
      searchTerm: '海边日落',
      searchMode: PhotoSearchMode.all,
      personId: 0,
    );
    expect(q3.containsKey('searchMode'), isFalse);
  });

  test('selectRecommendedWasteIds keeps Best-Shot and respects canTrash', () {
    const group = SimilarPhotoGroup(
      groupId: 'burst-1',
      kind: 'burst',
      takenAt: 1700000000,
      recommendedAssetId: 22,
      recommendReason: '清晰度更高 · 综合画质更佳',
      reclaimableBytes: 4096,
      items: [
        SimilarPhotoCandidate(
          assetId: 11,
          path: 'SharedPhotos/1.jpg',
          name: '1.jpg',
          size: 2048,
          takenAt: 1700000000,
          width: 4000,
          height: 3000,
          sharpness: 0.4,
          qualityScore: 0.5,
          recommended: false,
          canTrash: true,
        ),
        SimilarPhotoCandidate(
          assetId: 22,
          path: 'SharedPhotos/2.jpg',
          name: '2.jpg',
          size: 2048,
          takenAt: 1700000001,
          width: 4000,
          height: 3000,
          sharpness: 0.9,
          qualityScore: 0.92,
          recommended: true,
          canTrash: true,
        ),
        SimilarPhotoCandidate(
          assetId: 33,
          path: 'SharedPhotos/ro.jpg',
          name: 'ro.jpg',
          size: 2048,
          takenAt: 1700000002,
          width: 4000,
          height: 3000,
          sharpness: 0.2,
          qualityScore: 0.3,
          recommended: false,
          canTrash: false,
        ),
      ],
    );
    expect(selectRecommendedWasteIds(group), [11]);
  });

  test('chooseDuplicateKeepPath honors shortestPath, newest, and oldest', () {
    const items = [
      DuplicateFileItem(
        path: 'Archive/2025/Backup/clip.mov',
        name: 'clip.mov',
        size: 10485760,
        modified: 100,
        identity: '1:10:1',
        canTrash: true,
      ),
      DuplicateFileItem(
        path: 'Videos/clip.mov',
        name: 'clip.mov',
        size: 10485760,
        modified: 200,
        identity: '1:11:1',
        canTrash: true,
      ),
      DuplicateFileItem(
        path: 'Downloads/clip-copy.mov',
        name: 'clip-copy.mov',
        size: 10485760,
        modified: 500,
        identity: '1:12:1',
        canTrash: true,
      ),
    ];
    expect(
      chooseDuplicateKeepPath(items, DuplicateKeepStrategy.shortestPath),
      'Videos/clip.mov',
    );
    expect(
      chooseDuplicateKeepPath(items, DuplicateKeepStrategy.newest),
      'Downloads/clip-copy.mov',
    );
    expect(
      chooseDuplicateKeepPath(items, DuplicateKeepStrategy.oldest),
      'Archive/2025/Backup/clip.mov',
    );
  });

  test('MediaScanStatus parses aiIndexing progress cleanly', () {
    final status = MediaScanStatus.fromJson({
      'running': false,
      'found': 120,
      'aiIndexing': {
        'running': true,
        'paused': false,
        'remaining': 18,
        'total': 120,
      },
    });
    expect(status.aiRunning, isTrue);
    expect(status.aiPaused, isFalse);
    expect(status.aiRemaining, 18);
    expect(status.aiTotal, 120);
  });

  test(
    'PhotoAIRepository routes person, similar, and duplicate calls',
    () async {
      final api = _FakeAIApi();
      addTearDown(api.close);
      api.onGet = (path, query) {
        if (path == '/api/v2/photos/persons') {
          return {
            'persons': [
              {
                'id': 3,
                'name': '宝宝',
                'photoCount': 12,
                'faceCount': 14,
                'coverFaceId': 8,
              },
            ],
          };
        }
        return {};
      };
      api.onSend = (method, path, body) {
        if (path == '/api/v2/files/duplicates/trash') {
          return {
            'trashed': 1,
            'stagedTrashBytes': 2097152,
            'quotaReleaseNote': '移入回收站后可随时恢复；个人空间配额将在从回收站永久删除后释放。',
          };
        }
        return {'paused': true};
      };

      final repo = PhotoAIRepository(api);
      final persons = await repo.listPersons(includeHidden: true);
      expect(persons.single.displayName, '宝宝');
      expect(api.requests.first.$3, {'includeHidden': '1'});

      await repo.updatePerson(3, name: '小宝');
      await repo.mergePerson(sourcePersonId: 3, targetPersonId: 5);
      final receipt = await repo.trashDuplicates([
        (
          keepPath: 'Movies/a.mp4',
          trashItems: const [
            DuplicateFileItem(
              path: 'Backup/a.mp4',
              name: 'a.mp4',
              size: 2097152,
              modified: 100,
              identity: '1:99:1',
              canTrash: true,
            ),
          ],
        ),
      ]);
      expect(receipt.trashed, 1);
      expect(api.requests.map((r) => '${r.$1} ${r.$2}'), [
        'GET /api/v2/photos/persons',
        'PATCH /api/v2/photos/persons/3',
        'POST /api/v2/photos/persons/3/merge',
        'POST /api/v2/files/duplicates/trash',
      ]);
    },
  );

  testWidgets('PhotoLiveTextCard renders scene chips, person tags, and OCR', (
    tester,
  ) async {
    final api = _FakeAIApi();
    addTearDown(api.close);
    api.onGet = (path, _) => {
      'assetId': 42,
      'indexed': true,
      'status': 'done',
      'ocrText': '电子发票 HT-9981',
      'sceneLabels': ['文档', '海边日落'],
      'faces': [
        {'faceId': 1, 'personId': 3, 'personName': '妈妈'},
      ],
    };

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PhotoLiveTextCard(api: api, assetId: 42)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('智能识图与图中文字'), findsOneWidget);
    expect(find.text('海边日落'), findsOneWidget);
    expect(find.text('妈妈'), findsOneWidget);
    expect(find.text('电子发票 HT-9981'), findsOneWidget);
    expect(find.byKey(const ValueKey('copyPhotoOcrButton')), findsOneWidget);
  });

  testWidgets('DuplicateFilesPage displays APFS clone badge and keep-1 guard', (
    tester,
  ) async {
    final api = _FakeAIApi();
    addTearDown(api.close);
    api.onGet = (path, _) => {
      'running': false,
      'quotaReleaseNote': '移入回收站后可随时恢复；个人空间配额将在从回收站永久删除后释放。',
      'result': {
        'minSizeBytes': 1048576,
        'scannedFiles': 8,
        'totalGroups': 1,
        'totalReclaimableBytes': 4194304,
        'totalReclaimablePhysicalBytes': 0,
        'groups': [
          {
            'groupId': 'g1',
            'size': 4194304,
            'count': 2,
            'reclaimableBytes': 4194304,
            'reclaimablePhysicalBytes': 0,
            'allApfsClones': true,
            'items': [
              {
                'path': 'Files/report.pdf',
                'name': 'report.pdf',
                'size': 4194304,
                'modified': 1700000000,
                'identity': '1:10:1',
                'isApfsClone': true,
                'canTrash': true,
              },
              {
                'path': 'Files/Copy/report.pdf',
                'name': 'report.pdf',
                'size': 4194304,
                'modified': 1700000010,
                'identity': '1:11:1',
                'isApfsClone': true,
                'canTrash': true,
              },
            ],
          },
        ],
      },
    };

    await tester.pumpWidget(MaterialApp(home: DuplicateFilesPage(api: api)));
    await tester.pumpAndSettle();

    expect(find.textContaining('APFS 克隆'), findsWidgets);
    expect(find.text('Files/report.pdf'), findsOneWidget);
    expect(find.text('Files/Copy/report.pdf'), findsOneWidget);
    expect(find.text('移入回收站 (1)'), findsOneWidget);
  });

  test('new AI and duplicate error codes translate cleanly', () {
    for (final code in const [
      'file_changed_rescan_required',
      'must_keep_one_photo',
      'must_keep_one_file',
      'invalid_person_name',
      'cannot_merge_same_person',
      'invalid_search_mode',
      'invalid_person_id',
    ]) {
      final msg = userFacingError(
        LightIsleApiException(code: code, message: code, statusCode: 400),
      );
      expect(msg, isNot(contains('排查标识')), reason: 'missing label for $code');
    }
  });
}
