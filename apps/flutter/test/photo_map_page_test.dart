import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/photo_map_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _GeoApi extends LightIsleApi {
  _GeoApi(this.points, {this.truncated = false, this.total})
      : super('http://127.0.0.1');

  final List<Map<String, Object>> points;
  final bool truncated;
  final int? total;

  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query}) {
    if (path == '/api/v1/photos/geo') {
      return Future.value(<String, dynamic>{
        'points': points,
        'total': total ?? points.length,
        'truncated': truncated,
      });
    }
    return Future.value(<String, dynamic>{});
  }
}

void main() {
  test('map accepts valid GPS photo IDs and rejects malformed or null island data', () {
    final point = PhotoGeoPoint.parse({'id': 5, 'lat': 31.2304, 'lon': 121.4737});
    expect(point, isNotNull);
    expect(point!.id, 5);
    expect(point.lat, closeTo(31.2304, .00001));
    expect(PhotoGeoPoint.parse({'id': 2, 'lat': 0, 'lon': 0}), isNull);
    expect(PhotoGeoPoint.parse({'id': 2, 'lat': 91, 'lon': 1}), isNull);
    expect(PhotoGeoPoint.parse({'id': -1, 'lat': 1, 'lon': 1}), isNull);
    expect(PhotoGeoPoint.parse({'id': 1, 'lat': 'private', 'lon': 1}), isNull);
  });

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

  testWidgets('dense cluster field renders the honest cap notice', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final points = <Map<String, Object>>[
      for (var i = 0; i < 1300; i++)
        <String, Object>{
          'id': i + 1,
          'lat': -80.0 + (i % 320) * 0.5,
          'lon': -178.0 + (i ~/ 320) * 0.5,
        },
    ];
    await tester.pumpWidget(MaterialApp(
      home: PhotoMapPage(api: _GeoApi(points), initialZoom: 12),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('点簇较多'), findsOneWidget);
    expect(find.textContaining('1300 张位置照片'), findsOneWidget);
  });

  testWidgets('server-side truncation stays labeled and no cap notice shows', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final points = <Map<String, Object>>[
      for (var i = 0; i < 40; i++)
        <String, Object>{
          'id': i + 1,
          'lat': 31.0 + i * 0.01,
          'lon': 121.0 + i * 0.01,
        },
    ];
    await tester.pumpWidget(MaterialApp(
      home: PhotoMapPage(
        api: _GeoApi(points, truncated: true, total: 20000),
      ),
    ));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('20000 张位置照片'), findsOneWidget);
    expect(find.textContaining('显示最新 40 张'), findsOneWidget);
    expect(find.textContaining('点簇较多'), findsNothing);
  });
}
