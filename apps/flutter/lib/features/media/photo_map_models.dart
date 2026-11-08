part of 'photo_map_page.dart';

class PhotoGeoPoint {
  const PhotoGeoPoint(this.id, this.lat, this.lon);
  final int id;
  final double lat, lon;
  static PhotoGeoPoint? parse(Object? value) {
    if (value is! Map) return null;
    final id = value['id'], lat = value['lat'], lon = value['lon'];
    if (id is! num || lat is! num || lon is! num) return null;
    final a = lat.toDouble(), b = lon.toDouble();
    if (id < 1 ||
        !a.isFinite ||
        !b.isFinite ||
        a.abs() > 90 ||
        b.abs() > 180 ||
        (a == 0 && b == 0)) {
      return null;
    }
    return PhotoGeoPoint(id.toInt(), a, b);
  }
}

class _GeoGroup {
  _GeoGroup(this.location);
  final LatLng location;
  final List<int> ids = [];
}

/// Render and same-location pick caps stay honest: whenever one applies, the
/// UI says so instead of silently dropping markers or photos.
const _maxRenderedGroups = 1200;
const _maxSameLocationPhotos = 120;

/// Title of the same-location picker; says so when only the newest slice of a
/// large set is offered.
String sameLocationPickerTitle(int totalCount) =>
    totalCount > _maxSameLocationPhotos
    ? '该位置最新 $_maxSameLocationPhotos 张（共 $totalCount 张）'
    : '该位置 $totalCount 张照片';

/// Header notice when the render cap drops the smallest clusters; null when
/// every cluster is drawn.
String? clusterCapNotice(int totalGroups) => totalGroups > _maxRenderedGroups
    ? '点簇较多，仅绘制最大的 $_maxRenderedGroups 组；放大地图可看到更多。'
    : null;

List<_GeoGroup> _clusters(List<PhotoGeoPoint> points, double zoom) {
  final cell = (360 / math.pow(2, zoom.clamp(0, 18).floor())).clamp(.005, 90.0);
  final grouped = <String, _GeoGroup>{};
  for (final p in points) {
    final key = '${(p.lat / cell).floor()}:${(p.lon / cell).floor()}';
    final group = grouped.putIfAbsent(
      key,
      () => _GeoGroup(LatLng(p.lat, p.lon)),
    );
    group.ids.add(p.id);
  }
  // Deterministic order: biggest clusters first, so when the render cap
  // applies the dropped groups are the smallest ones.
  final groups = grouped.values.toList()
    ..sort((a, b) => b.ids.length.compareTo(a.ids.length));
  return groups;
}
