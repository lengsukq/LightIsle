import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_cache_manager.dart';
import 'package:lightisle/core/isle_data_cache.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/core/widgets.dart';
import 'package:lightisle/features/settings/cache_management_page.dart';

class _StatefulCounterTab extends StatefulWidget {
  const _StatefulCounterTab({required this.label, super.key});

  final String label;

  @override
  State<_StatefulCounterTab> createState() => _StatefulCounterTabState();
}

class _StatefulCounterTabState extends State<_StatefulCounterTab> {
  int count = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text('${widget.label}:$count'),
        ElevatedButton(
          key: ValueKey('inc-${widget.label}'),
          onPressed: () => setState(() => count++),
          child: const Text('Increment'),
        ),
      ],
    );
  }
}

class _FakeCacheApi extends LightIsleApi {
  _FakeCacheApi() : super('http://127.0.0.1:19890');

  int serverThumbBytes = 4 * 1024 * 1024;
  int serverTileBytes = 2 * 1024 * 1024;
  List<String> lastClearedServerCategories = const [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/cache/status') {
      return {
        'thumbnails': {
          'usedBytes': serverThumbBytes,
          'maxBytes': 512 * 1024 * 1024,
          'entryCount': serverThumbBytes > 0 ? 120 : 0,
        },
        'mapTiles': {
          'usedBytes': serverTileBytes,
          'maxBytes': 256 * 1024 * 1024,
          'entryCount': serverTileBytes > 0 ? 45 : 0,
        },
      };
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
    if (method == 'POST' && path == '/api/v2/admin/cache/clear') {
      final map = body is Map ? Map<String, dynamic>.from(body) : const {};
      final cats = (map['categories'] as List?)?.cast<String>() ?? const ['all'];
      lastClearedServerCategories = cats;
      var freed = 0;
      if (cats.contains('all') || cats.contains('thumbnails')) {
        freed += serverThumbBytes;
        serverThumbBytes = 0;
      }
      if (cats.contains('all') || cats.contains('map_tiles')) {
        freed += serverTileBytes;
        serverTileBytes = 0;
      }
      return {
        'freedBytes': freed,
        'removedEntries': 10,
      };
    }
    return {};
  }
}

void main() {
  testWidgets(
    'IsleFluidTabSwitcher preserves child State across tab switches',
    (tester) async {
      var activeIndex = 0;
      late StateSetter setHostState;

      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              setHostState = setState;
              return Scaffold(
                body: IsleFluidTabSwitcher(
                  index: activeIndex,
                  children: const [
                    _StatefulCounterTab(
                      key: ValueKey('tab-0'),
                      label: 'photos',
                    ),
                    _StatefulCounterTab(
                      key: ValueKey('tab-1'),
                      label: 'cinema',
                    ),
                    _StatefulCounterTab(
                      key: ValueKey('tab-2'),
                      label: 'files',
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );

      expect(find.text('photos:0'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('inc-photos')));
      await tester.pump();
      expect(find.text('photos:1'), findsOneWidget);

      // Switch to tab 1 (cinema) and increment it.
      setHostState(() => activeIndex = 1);
      await tester.pumpAndSettle();
      expect(find.text('cinema:0'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('inc-cinema')));
      await tester.pump();
      expect(find.text('cinema:1'), findsOneWidget);

      // Switch to tab 2 (files) and then back to tab 0 (photos).
      setHostState(() => activeIndex = 2);
      await tester.pumpAndSettle();
      setHostState(() => activeIndex = 0);
      await tester.pumpAndSettle();

      // Tab 0 and Tab 1 must have preserved their states without remounting!
      expect(find.text('photos:1'), findsOneWidget);
      setHostState(() => activeIndex = 1);
      await tester.pumpAndSettle();
      expect(find.text('cinema:1'), findsOneWidget);
    },
  );

  test(
    'IsleCacheManager tracks L1+L2 categories and clears selectively',
    () async {
      final tempDir = Directory.systemTemp.createTempSync('isle_cache_test_');
      addTearDown(() {
        IsleCacheManager.instance.setDiskRootForTesting(null);
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final api = _FakeCacheApi();
      IsleCacheManager.instance.setDiskRootForTesting(tempDir);
      await IsleCacheManager.instance.clearAllTemporary();

      final thumbBytes = Uint8List.fromList(List<int>.filled(2048, 1));
      final posterBytes = Uint8List.fromList(List<int>.filled(4096, 2));
      final tileBytes = Uint8List.fromList(List<int>.filled(1024, 3));

      await IsleCacheManager.instance.putBytes(
        IsleCacheCategory.thumbnails,
        'thumb-1',
        thumbBytes,
      );
      await IsleCacheManager.instance.putBytes(
        IsleCacheCategory.posters,
        'poster-1',
        posterBytes,
      );
      await IsleCacheManager.instance.putBytes(
        IsleCacheCategory.mapTiles,
        'tianditu:vec:1/1/1',
        tileBytes,
      );
      IsleDataCache.instance.putJsonMap(
        api,
        'photos',
        'list',
        {'items': [1, 2, 3]},
        persistToDisk: true,
      );

      final report = await IsleCacheManager.instance.inspect();
      expect(
        report.categories[IsleCacheCategory.thumbnails]!.effectiveBytes,
        greaterThanOrEqualTo(2048),
      );
      expect(
        report.categories[IsleCacheCategory.posters]!.effectiveBytes,
        greaterThanOrEqualTo(4096),
      );
      expect(
        report.categories[IsleCacheCategory.mapTiles]!.effectiveBytes,
        greaterThanOrEqualTo(1024),
      );
      expect(
        report.categories[IsleCacheCategory.metadata]!.effectiveEntries,
        greaterThanOrEqualTo(1),
      );

      // Selectively clear only mapTiles; thumbnails and posters must remain intact.
      await IsleCacheManager.instance.clearCategories({
        IsleCacheCategory.mapTiles,
      });
      final afterMapClear = await IsleCacheManager.instance.inspect();
      expect(
        afterMapClear.categories[IsleCacheCategory.mapTiles]!.effectiveBytes,
        0,
      );
      expect(
        afterMapClear.categories[IsleCacheCategory.thumbnails]!.effectiveBytes,
        greaterThanOrEqualTo(2048),
      );
      expect(
        afterMapClear.categories[IsleCacheCategory.posters]!.effectiveBytes,
        greaterThanOrEqualTo(4096),
      );
    },
  );

  testWidgets(
    'CacheManagementPage displays category sizes and clears local & server caches',
    (tester) async {
      final tempDir = Directory.systemTemp.createTempSync('isle_cache_ui_');
      addTearDown(() {
        IsleCacheManager.instance.setDiskRootForTesting(null);
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      IsleCacheManager.instance.setDiskRootForTesting(tempDir);
      await IsleCacheManager.instance.clearAllTemporary();
      await IsleCacheManager.instance.putBytes(
        IsleCacheCategory.mapTiles,
        'tile-key-1',
        Uint8List.fromList(List<int>.filled(3072, 7)),
      );

      final api = _FakeCacheApi();
      await tester.pumpWidget(
        MaterialApp(
          home: CacheManagementPage(
            api: api,
            isAdmin: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('缓存与本地存储管理'), findsOneWidget);
      expect(find.text('本机缓存分类管理'), findsOneWidget);
      expect(find.text('足迹地图与瓦片'), findsOneWidget);

      // Clear single category (mapTiles).
      await tester.tap(find.byKey(const ValueKey('clear-single-map_tiles')));
      await tester.pumpAndSettle();

      final report = await IsleCacheManager.instance.inspect();
      expect(
        report.categories[IsleCacheCategory.mapTiles]!.effectiveBytes,
        0,
      );

      // Scroll down to server cache card and clear server thumbnails.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('clearServerThumbnailsBtn')),
        200,
      );
      await tester.tap(find.byKey(const ValueKey('clearServerThumbnailsBtn')));
      await tester.pumpAndSettle();
      expect(api.lastClearedServerCategories, ['thumbnails']);
      expect(api.serverThumbBytes, 0);
    },
  );
}
