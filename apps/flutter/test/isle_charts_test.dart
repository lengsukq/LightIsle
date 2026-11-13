import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_cache_manager.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/core/widgets.dart';
import 'package:lightisle/features/files/duplicate_files_page.dart';
import 'package:lightisle/features/media/media_ui.dart';
import 'package:lightisle/features/media/photo_similar_cleanup_sheet.dart';
import 'package:lightisle/features/overview/overview_page.dart';
import 'package:lightisle/features/overview/overview_telemetry_grid.dart';
import 'package:lightisle/features/settings/cache_management_page.dart';
import 'package:lightisle/features/settings/storage_charts.dart';
import 'package:lightisle/features/settings/storage_page.dart';

class _ChartTestApi extends LightIsleApi {
  _ChartTestApi() : super('http://127.0.0.1:19895');

  double cpuPercent = 24.0;
  int coreRssBytes = 512 * 1024 * 1024;
  int networkDownBps = 2048;

  static final Uint8List _tinyPng = Uint8List.fromList([
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x08,
    0x06,
    0x00,
    0x00,
    0x00,
    0x1F,
    0x15,
    0xC4,
    0x89,
    0x00,
    0x00,
    0x00,
    0x0A,
    0x49,
    0x44,
    0x41,
    0x54,
    0x78,
    0x9C,
    0x63,
    0x00,
    0x01,
    0x00,
    0x00,
    0x05,
    0x00,
    0x01,
    0x0D,
    0x0A,
    0x2D,
    0xB4,
    0x00,
    0x00,
    0x00,
    0x00,
    0x49,
    0x45,
    0x4E,
    0x44,
    0xAE,
    0x42,
    0x60,
    0x82,
  ]);

  @override
  Future<Uint8List> bytes(
    String path, {
    Map<String, String>? query,
    int? maxBytes,
  }) async => _tinyPng;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    switch (path) {
      case '/api/v2/system':
        return {
          'hostname': 'Mac-Studio',
          'architecture': 'arm64',
          'cpuCount': 8,
          'cpuPercent': cpuPercent,
          'memoryTotal': 16 * 1024 * 1024 * 1024,
          'memoryUsed': 8 * 1024 * 1024 * 1024,
          'coreRssBytes': coreRssBytes,
          'diskTotal': 1000 * (1 << 30),
          'diskFree': 400 * (1 << 30),
          'networkDownBps': networkDownBps,
          'networkUpBps': 512,
          'volumes': [
            {
              'name': 'Macintosh HD',
              'mount': '/',
              'total': 1000 * (1 << 30),
              'free': 400 * (1 << 30),
              'filesystem': 'apfs',
              'readOnly': false,
            },
          ],
        };
      case '/api/v2/tasks':
        return {'tasks': []};
      case '/api/v2/roots':
        return {
          'roots': [
            {
              'rootID': 'drive-one',
              'name': '家庭资料盘',
              'generation': 3,
              'online': true,
              'isDefault': true,
              'volumeMount': '/',
              'filesystemTotalBytes': 200 * (1 << 30),
              'filesystemAvailableBytes': 80 * (1 << 30),
            },
          ],
        };
      case '/api/v2/me/storage':
      case '/api/v2/users/7/storage':
        return {
          'userId': 7,
          'quotaBytes': null,
          'accountedBytes': 30 * (1 << 30),
          'reservedBytes': 5 * (1 << 30),
          'enforcement': 'pending',
          'rootQuotas': [
            {
              'rootID': 'drive-one',
              'rootGeneration': 3,
              'quotaBytes': 100 * (1 << 30),
              'accountedBytes': 30 * (1 << 30),
              'reservedBytes': 5 * (1 << 30),
            },
          ],
          'locations': [
            {
              'category': 'files',
              'rootID': 'drive-one',
              'rootGeneration': 3,
              'relativePath': 'Users/u7/files',
            },
          ],
        };
      case '/api/v2/users':
        return {
          'users': [
            {'id': 7, 'username': '家人'},
          ],
        };
      case '/api/v2/cache/status':
        return {
          'thumbnails': {
            'usedBytes': 128 * 1024 * 1024,
            'maxBytes': 512 * 1024 * 1024,
            'entryCount': 42,
          },
          'mapTiles': {
            'usedBytes': 64 * 1024 * 1024,
            'maxBytes': 256 * 1024 * 1024,
            'entryCount': 18,
          },
        };
      case '/api/v2/files/duplicates':
        return {
          'running': false,
          'result': {
            'minSizeBytes': 1048576,
            'scannedFiles': 10,
            'totalGroups': 1,
            'totalReclaimableBytes': 100 * 1024 * 1024,
            'totalReclaimablePhysicalBytes': 100 * 1024 * 1024,
            'groups': [
              {
                'groupId': 'dup-1',
                'sha256': 'abc123',
                'size': 100 * 1024 * 1024,
                'count': 2,
                'reclaimableBytes': 100 * 1024 * 1024,
                'reclaimablePhysicalBytes': 100 * 1024 * 1024,
                'allApfsClones': false,
                'items': [
                  {
                    'path': 'Movies/a.mp4',
                    'name': 'a.mp4',
                    'size': 100 * 1024 * 1024,
                    'modified': 1700000000,
                    'identity': '1:1:1',
                    'canTrash': true,
                  },
                  {
                    'path': 'Movies/copy/a.mp4',
                    'name': 'a.mp4',
                    'size': 100 * 1024 * 1024,
                    'modified': 1700000010,
                    'identity': '1:2:1',
                    'canTrash': true,
                  },
                ],
              },
            ],
          },
        };
      case '/api/v2/photos/cleanup/similar':
        return {
          'groups': [
            {
              'groupId': 'sim-1',
              'kind': 'burst',
              'takenAt': 1700000000,
              'recommendedAssetId': 11,
              'recommendReason': '画面更清晰',
              'reclaimableBytes': 8 * 1024 * 1024,
              'items': [
                {
                  'assetId': 11,
                  'path': 'Photos/11.jpg',
                  'name': '11.jpg',
                  'size': 8 * 1024 * 1024,
                  'takenAt': 1700000000,
                  'width': 4032,
                  'height': 3024,
                  'sharpness': 95.0,
                  'qualityScore': 92.0,
                  'recommended': true,
                  'canTrash': true,
                },
                {
                  'assetId': 12,
                  'path': 'Photos/12.jpg',
                  'name': '12.jpg',
                  'size': 8 * 1024 * 1024,
                  'takenAt': 1700000001,
                  'width': 4032,
                  'height': 3024,
                  'sharpness': 60.0,
                  'qualityScore': 68.0,
                  'recommended': false,
                  'canTrash': true,
                },
              ],
            },
          ],
          'quotaReleaseNote': '移入回收站后可随时恢复。',
        };
      default:
        return {};
    }
  }
}

void main() {
  test('IsleChartSegment supports value equality and hashing', () {
    const a = IsleChartSegment(
      label: '已用',
      value: 42,
      color: Color(0xff0071e3),
      detail: '42 GB',
    );
    const b = IsleChartSegment(
      label: '已用',
      value: 42,
      color: Color(0xff0071e3),
      detail: '42 GB',
    );
    const c = IsleChartSegment(
      label: '已用',
      value: 50,
      color: Color(0xff0071e3),
      detail: '50 GB',
    );
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
    expect(a, isNot(equals(c)));
  });

  testWidgets(
    'IsleDonutGauge, IsleSegmentedBar, and IsleSparkline render cleanly at 320px and 200% text scale with zero tickers',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(2.0),
            ),
            child: Scaffold(
              body: ListView(
                padding: const EdgeInsets.all(16),
                children: const [
                  IsleDonutGauge(
                    fraction: 0.72,
                    color: Color(0xff0071e3),
                    centerText: '72%',
                  ),
                  IsleDonutGauge(
                    fraction: double.nan,
                    segments: [
                      IsleChartSegment(
                        label: 'A',
                        value: 1,
                        color: Colors.blue,
                        detail: '1 MiB',
                      ),
                      IsleChartSegment(
                        label: 'B',
                        value: 3,
                        color: Colors.green,
                        detail: '3 MiB',
                      ),
                    ],
                  ),
                  IsleSegmentedBar(
                    showPercentInLegend: true,
                    segments: [
                      IsleChartSegment(
                        label: '超长分类名称测试自动换行与省略号截断保护',
                        value: 1,
                        color: Color(0xff0071e3),
                        detail: '100 KB',
                      ),
                      IsleChartSegment(
                        label: '照片与视频备份缓存空间',
                        value: 99,
                        color: Color(0xff10b981),
                        detail: '9.9 GB',
                      ),
                    ],
                  ),
                  IsleSparkline(values: [], color: Color(0xff0071e3)),
                  IsleSparkline(values: [42.0], color: Color(0xff0071e3)),
                  IsleSparkline(
                    values: [10, 25, 18, 64, 48, 82],
                    color: Color(0xff10b981),
                    minValue: 0,
                    maxValue: 100,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('72%'), findsOneWidget);
      expect(find.byType(IsleDonutGauge), findsNWidgets(2));
      expect(find.byType(IsleSegmentedBar), findsOneWidget);
      expect(find.byType(IsleSparkline), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'OverviewPage admin dashboard renders vector donuts, 3-color memory bar, and sparklines',
    (tester) async {
      final api = _ChartTestApi();
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OverviewPage(api: api, isAdmin: true, onNavigate: (_) {}),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(AdminTelemetryBentoGrid), findsOneWidget);
      expect(find.textContaining('核心服务'), findsOneWidget);
      expect(find.byType(IsleSparkline), findsNWidgets(2));
      expect(find.byType(IsleSegmentedBar), findsWidgets);
      expect(find.byType(IsleDonutGauge), findsWidgets);

      api.cpuPercent = 66.0;
      api.networkDownBps = 8192;
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.text('66.0%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'StoragePage, CacheManagementPage, DuplicateFilesPage, and PhotoSimilarCleanupPage integrate native vector charts',
    (tester) async {
      final api = _ChartTestApi();
      addTearDown(api.close);

      // 1. StoragePage charts
      await tester.pumpWidget(
        MaterialApp(home: StoragePage(api: api, isAdmin: true)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(StorageRootBreakdownBar), findsOneWidget);
      expect(find.byType(StorageQuotaSegmentedBar), findsOneWidget);
      expect(find.byType(StorageCompactDonut), findsWidgets);
      expect(find.textContaining('成员已入账'), findsOneWidget);

      // 2. CacheManagementPage charts
      IsleCacheManager.instance.setDiskRootForTesting(null);
      await tester.pumpWidget(
        MaterialApp(home: CacheManagementPage(api: api, isAdmin: true)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(IsleSegmentedBar), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('clearServerThumbnailsBtn')),
        250,
      );
      await tester.pumpAndSettle();
      expect(find.byType(IsleSegmentedBar), findsOneWidget);
      expect(find.byType(IsleDonutGauge), findsNWidgets(2));
      expect(find.text('25%'), findsNWidgets(2));

      // 3. DuplicateFilesPage savings comparison
      await tester.pumpWidget(MaterialApp(home: DuplicateFilesPage(api: api)));
      await tester.pumpAndSettle();
      expect(find.text('省50%'), findsOneWidget);
      expect(find.textContaining('保留原件 100 MB · 50%'), findsOneWidget);
      expect(find.textContaining('可释放物理冗余 100 MB · 50%'), findsOneWidget);

      // 4. PhotoSimilarCleanupPage comparison bar & live update
      await tester.pumpWidget(
        MaterialApp(home: PhotoSimilarCleanupPage(api: api)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('待整理 1 组 · 已选清理 1/2 张'), findsOneWidget);
      expect(find.textContaining('保留精选 1 张 · 50%'), findsOneWidget);
      expect(find.textContaining('待清理冗余 1 张 · 50%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Member OverviewPage renders per-disk quota chart without leaking admin quick jumps',
    (tester) async {
      final api = _ChartTestApi();
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OverviewPage(api: api, isAdmin: false, onNavigate: (_) {}),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(IsleDonutGauge), findsOneWidget);
      expect(find.text('35%'), findsOneWidget);
      expect(find.byType(IsleSegmentedBar), findsOneWidget);
      expect(find.textContaining('上传预占'), findsWidgets);
      expect(find.textContaining('仅为已入账用量'), findsOneWidget);
      expect(find.textContaining('SMB'), findsNothing);
      expect(find.textContaining('TMDB'), findsNothing);
      expect(find.textContaining('自动化'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'MediaStatusBanner integrates IsleDonutGauge cleanly without overflow',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 480));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaStatusBanner(
              message: '正在后台离线建立智能识图与 OCR 索引 · 剩余 30 张',
              leading: const IsleDonutGauge(
                fraction: 0.7,
                size: 32,
                strokeWidth: 3.5,
                centerText: '70%',
              ),
              trailing: TextButton(onPressed: () {}, child: const Text('暂停')),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('70%'), findsOneWidget);
      expect(find.byType(IsleDonutGauge), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
