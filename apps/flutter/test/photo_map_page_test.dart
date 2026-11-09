import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/photo_map_page.dart';
import 'package:lightisle/features/media/photo_map_tiles.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _GeoApi extends LightIsleApi {
  _GeoApi(
    this.points, {
    this.truncated = false,
    this.total,
    this.tiandituConfigured = false,
  }) : super('http://127.0.0.1');

  final List<Map<String, Object>> points;
  final bool truncated;
  final int? total;
  final bool tiandituConfigured;

  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query}) {
    if (path == '/api/v2/map/status') {
      return Future.value(<String, dynamic>{
        'tiandituConfigured': tiandituConfigured,
      });
    }
    if (path == '/api/v2/photos/geo') {
      return Future.value(<String, dynamic>{
        'points': points,
        'total': total ?? points.length,
        'truncated': truncated,
      });
    }
    if (path == '/api/v2/photos') {
      final rawIds = (query?['ids'] ?? '')
          .split(',')
          .map((s) => int.tryParse(s.trim()))
          .whereType<int>()
          .toList();
      return Future.value(<String, dynamic>{
        'assets': [
          for (final id in rawIds)
            <String, dynamic>{
              'id': id,
              'name': 'MVIMG_$id.jpg',
              'path': 'Photos/MVIMG_$id.jpg',
              'type': 'photo',
              'size': 2048,
              'takenAt': 1761577299,
            },
        ],
      });
    }
    return Future.value(<String, dynamic>{});
  }
}

class _UnavailableGeoApi extends LightIsleApi {
  _UnavailableGeoApi() : super('http://127.0.0.1');

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    throw StateError('offline');
  }
}

void main() {
  testWidgets('no GPS photos gives an explanation and manual refresh', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(MaterialApp(home: PhotoMapPage(api: _GeoApi([]))));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('暂无带 GPS 位置的照片'), findsOneWidget);
    expect(find.text('重新读取位置'), findsOneWidget);
    expect(find.text('启用在线地图'), findsOneWidget);
  });

  testWidgets('online Tianditu uses two WMTS layers, not one unlabelled map', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      PhotoMapTiles.sourceKey: 'tianditu',
      PhotoMapTiles.consentKey: true,
    });
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoMapPage(
          api: _GeoApi([
            {'id': 7, 'lat': 31.2304, 'lon': 121.4737},
          ], tiandituConfigured: true),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final layers = tester
        .widgetList<TileLayer>(find.byType(TileLayer))
        .toList();
    expect(layers, hasLength(2));
    expect(
      layers.map((e) => e.urlTemplate),
      contains('http://127.0.0.1${PhotoMapTiles.tiandituUrl('vec')}'),
    );
    expect(
      layers.map((e) => e.urlTemplate),
      contains('http://127.0.0.1${PhotoMapTiles.tiandituUrl('cva')}'),
    );
    for (final layer in layers) {
      expect(layer.urlTemplate, isNot(contains('ABCDEFGHIJKLMNOP')));
      expect(layer.urlTemplate, isNot(contains('tk=')));
      expect(layer.maxNativeZoom, 18);
    }
  });

  testWidgets(
    'a saved consent with missing Tianditu key makes no tile requests',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        PhotoMapTiles.sourceKey: 'tianditu',
        PhotoMapTiles.consentKey: true,
      });
      await tester.pumpWidget(
        MaterialApp(
          home: PhotoMapPage(
            api: _GeoApi([
              {'id': 7, 'lat': 31.2304, 'lon': 121.4737},
            ]),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byType(TileLayer), findsNothing);
      expect(find.textContaining('天地图还没有设置'), findsOneWidget);
      expect(find.text('等待 Mac 地图配置 · 点击关闭'), findsOneWidget);
    },
  );

  testWidgets('NAS geo failure is not mistaken for an empty photo library', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(
      MaterialApp(home: PhotoMapPage(api: _UnavailableGeoApi())),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('读取位置照片失败'), findsOneWidget);
    expect(find.textContaining('位置照片未能读取'), findsOneWidget);
    expect(find.textContaining('暂无带 GPS 位置的照片'), findsNothing);
  });

  testWidgets(
    'tile URL settings validate and save without enabling network maps',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await tester.pumpWidget(
        MaterialApp(home: PhotoMapPage(api: _GeoApi([]))),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('地图设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('天地图（国内推荐）').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义瓦片').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'not-a-url');
      await tester.tap(find.text('保存地图设置'));
      await tester.pumpAndSettle();
      expect(find.textContaining('请输入 http(s) 瓦片链接'), findsOneWidget);

      const tileUrl = 'https://example.com/tiles/{z}/{x}/{y}.png';
      await tester.enterText(find.byType(TextFormField), tileUrl);
      await tester.tap(find.text('保存地图设置'));
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lightisle_flutter_map_tile_url'), tileUrl);
      expect(prefs.getString(PhotoMapTiles.sourceKey), 'custom');
      expect(prefs.getBool('lightisle_flutter_map_tiles_enabled'), isNull);
      expect(find.text('启用在线地图'), findsOneWidget);
    },
  );

  test('Tianditu WMTS uses Web Mercator for roads and Chinese labels', () {
    final roads = PhotoMapTiles.tiandituUrl('vec');
    final labels = PhotoMapTiles.tiandituUrl('cva');
    expect(roads, startsWith('/api/v2/map/tiles/tianditu/vec'));
    expect(labels, startsWith('/api/v2/map/tiles/tianditu/cva'));
    for (final template in [roads, labels]) {
      expect(template, contains('/{z}/{x}/{y}'));
      expect(template, isNot(contains('tk=')));
    }
    expect(() => PhotoMapTiles.tiandituUrl('img'), throwsArgumentError);
  });

  test(
    'reads configured status without key and preserves legacy tile selection',
    () {
      expect(
        PhotoMapTiles.isReady(
          source: PhotoMapTileSource.tianditu,
          tiandituConfigured: false,
          customUrl: PhotoMapTiles.openStreetMapUrl,
        ),
        isFalse,
      );
      expect(
        PhotoMapTiles.isReady(
          source: PhotoMapTileSource.tianditu,
          tiandituConfigured: true,
          customUrl: '',
        ),
        isTrue,
      );
      expect(
        PhotoMapTiles.migratedSource(
          storedSource: null,
          legacyCustomUrl: null,
          previouslyEnabled: false,
        ),
        PhotoMapTileSource.tianditu,
      );
      expect(
        PhotoMapTiles.migratedSource(
          storedSource: null,
          legacyCustomUrl: null,
          previouslyEnabled: true,
        ),
        PhotoMapTileSource.openStreetMap,
      );
      expect(
        PhotoMapTiles.migratedSource(
          storedSource: null,
          legacyCustomUrl: 'https://example.com/{z}/{x}/{y}.png',
          previouslyEnabled: true,
        ),
        PhotoMapTileSource.custom,
      );
      expect(
        PhotoMapTiles.migratedSource(
          storedSource: 'tianditu',
          legacyCustomUrl: PhotoMapTiles.openStreetMapUrl,
          previouslyEnabled: true,
        ),
        PhotoMapTileSource.tianditu,
      );
    },
  );

  testWidgets(
    'Tianditu settings only show Mac-admin guidance and never persist Key',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await tester.pumpWidget(
        MaterialApp(home: PhotoMapPage(api: _GeoApi([]))),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('地图设置'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Mac 版 LightIsle'), findsWidgets);
      expect(find.byKey(const ValueKey('tianditu-key-input')), findsNothing);
      await tester.tap(find.text('保存地图设置'));
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PhotoMapTiles.sourceKey), 'tianditu');
      expect(prefs.getString(PhotoMapTiles.legacyTiandituKey), isNull);
      expect(prefs.getBool(PhotoMapTiles.consentKey), isFalse);
    },
  );

  testWidgets(
    'legacy local provider Key is deleted during map initialization',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        PhotoMapTiles.legacyTiandituKey: 'old-secret-token',
        PhotoMapTiles.sourceKey: 'tianditu',
      });
      await tester.pumpWidget(
        MaterialApp(home: PhotoMapPage(api: _GeoApi([]))),
      );
      await tester.pump();
      await tester.pump();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PhotoMapTiles.legacyTiandituKey), isNull);
    },
  );

  test(
    'map accepts valid GPS photo IDs and rejects malformed or null island data',
    () {
      final point = PhotoGeoPoint.parse({
        'id': 5,
        'lat': 31.2304,
        'lon': 121.4737,
      });
      expect(point, isNotNull);
      expect(point!.id, 5);
      expect(point.lat, closeTo(31.2304, .00001));
      expect(PhotoGeoPoint.parse({'id': 2, 'lat': 0, 'lon': 0}), isNull);
      expect(PhotoGeoPoint.parse({'id': 2, 'lat': 91, 'lon': 1}), isNull);
      expect(PhotoGeoPoint.parse({'id': -1, 'lat': 1, 'lon': 1}), isNull);
      expect(
        PhotoGeoPoint.parse({'id': 1, 'lat': 'private', 'lon': 1}),
        isNull,
      );
    },
  );

  test('same-location picker says when only the newest slice is offered', () {
    expect(sameLocationPickerTitle(130), '该位置最新 120 张（共 130 张）');
    expect(sameLocationPickerTitle(121), '该位置最新 120 张（共 121 张）');
    expect(sameLocationPickerTitle(120), '该位置 120 张照片');
    expect(sameLocationPickerTitle(3), '该位置 3 张照片');
  });

  test('cluster cap notice only appears when groups were dropped', () {
    expect(clusterCapNotice(1300), contains('1200'));
    expect(clusterCapNotice(1201), isNotNull);
    expect(clusterCapNotice(1200), isNull);
    expect(clusterCapNotice(8), isNull);
  });

  testWidgets('dense cluster field renders the honest cap notice', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final points = <Map<String, Object>>[
      for (var i = 0; i < 1300; i++)
        <String, Object>{
          'id': i + 1,
          'lat': -80.0 + (i % 320) * 0.5,
          'lon': -178.0 + (i ~/ 320) * 0.5,
        },
    ];
    await tester.pumpWidget(
      MaterialApp(home: PhotoMapPage(api: _GeoApi(points), initialZoom: 12)),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('点簇较多'), findsOneWidget);
    expect(find.textContaining('1300 张位置照片'), findsOneWidget);
  });

  testWidgets('server-side truncation stays labeled and no cap notice shows', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final points = <Map<String, Object>>[
      for (var i = 0; i < 40; i++)
        <String, Object>{
          'id': i + 1,
          'lat': 31.0 + i * 0.01,
          'lon': 121.0 + i * 0.01,
        },
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoMapPage(api: _GeoApi(points, truncated: true, total: 20000)),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('20000 张位置照片'), findsOneWidget);
    expect(find.textContaining('显示最新 40 张'), findsOneWidget);
    expect(find.textContaining('点簇较多'), findsNothing);
  });

  testWidgets(
    'map enforces zoom bounds and single-world camera constraint, and clicking a cluster opens the photo sheet immediately',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final points = <Map<String, Object>>[
        {'id': 10, 'lat': 31.2304, 'lon': 121.4737, 'takenAt': 1761577299},
        {'id': 11, 'lat': 31.2305, 'lon': 121.4738, 'takenAt': 1761577200},
        {'id': 12, 'lat': 31.2306, 'lon': 121.4739, 'takenAt': 1761577100},
      ];
      await tester.pumpWidget(
        MaterialApp(home: PhotoMapPage(api: _GeoApi(points), initialZoom: 5)),
      );
      await tester.pump();
      await tester.pump();

      final mapWidget = tester.widget<FlutterMap>(find.byType(FlutterMap));
      expect(mapWidget.options.minZoom, photoMapMinZoom);
      expect(mapWidget.options.maxZoom, photoMapMaxZoom);
      expect(mapWidget.options.cameraConstraint, isA<CameraConstraint>());

      // Pin shows cover thumbnail frame and count badge "3"
      final pinFinder = find.byKey(const ValueKey('photo-map-pin-10'));
      expect(pinFinder, findsOneWidget);
      expect(find.text('3'), findsOneWidget);

      // Single tap at zoom=5 immediately opens the location photo sheet
      // instead of merely zooming in without showing photos.
      await tester.tap(pinFinder);
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const ValueKey('photo-map-location-sheet')),
        findsOneWidget,
      );
      expect(find.text('该位置 3 张照片'), findsOneWidget);
      expect(find.byKey(const ValueKey('map-sheet-photo-10')), findsOneWidget);
      expect(find.byKey(const ValueKey('map-sheet-photo-11')), findsOneWidget);
      expect(find.byKey(const ValueKey('map-sheet-photo-12')), findsOneWidget);

      // Close the sheet
      await tester.tap(find.byKey(const ValueKey('photo-map-close-sheet')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('photo-map-location-sheet')),
        findsNothing,
      );
    },
  );

  test('street-level zoom cluster cell size subdivides nearby spots', () {
    expect(geoClusterCellDegrees(18), lessThan(0.001));
    expect(geoClusterCellDegrees(17), lessThan(geoClusterCellDegrees(16)));
    expect(geoClusterCellDegrees(16), lessThan(geoClusterCellDegrees(15)));
  });
}
