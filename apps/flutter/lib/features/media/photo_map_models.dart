part of 'photo_map_page.dart';

const photoMapMinZoom = 2.5;
const photoMapMaxZoom = 18.0;

/// Render and same-location pick caps stay honest: whenever one applies, the
/// UI says so instead of silently dropping markers or photos.
const _maxRenderedGroups = 1200;
const _maxThumbnailMarkers = 48;
const _maxSameLocationPhotos = 120;

class PhotoGeoPoint {
  const PhotoGeoPoint(
    this.id,
    this.lat,
    this.lon, {
    this.takenAt = 0,
    this.type = 'photo',
  });
  final int id;
  final double lat, lon;
  final int takenAt;
  final String type;

  bool get isVideo => type == 'video';

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
    final takenAt = value['takenAt'];
    final type = value['type'];
    return PhotoGeoPoint(
      id.toInt(),
      a,
      b,
      takenAt: takenAt is num ? takenAt.toInt() : 0,
      type: type is String && type.isNotEmpty ? type : 'photo',
    );
  }
}

class _GeoGroup {
  _GeoGroup(this.key);
  final String key;
  final List<int> ids = [];
  double _latSum = 0;
  double _lonSum = 0;
  double minLat = 90;
  double maxLat = -90;
  double minLon = 180;
  double maxLon = -180;
  int minTakenAt = 0;
  int maxTakenAt = 0;
  bool coverIsVideo = false;

  void add(PhotoGeoPoint point) {
    if (ids.isEmpty) {
      coverIsVideo = point.isVideo;
    }
    ids.add(point.id);
    _latSum += point.lat;
    _lonSum += point.lon;
    if (point.lat < minLat) minLat = point.lat;
    if (point.lat > maxLat) maxLat = point.lat;
    if (point.lon < minLon) minLon = point.lon;
    if (point.lon > maxLon) maxLon = point.lon;
    if (point.takenAt > 0) {
      if (minTakenAt == 0 || point.takenAt < minTakenAt) {
        minTakenAt = point.takenAt;
      }
      if (point.takenAt > maxTakenAt) {
        maxTakenAt = point.takenAt;
      }
    }
  }

  LatLng get location => ids.isEmpty
      ? const LatLng(0, 0)
      : LatLng(_latSum / ids.length, _lonSum / ids.length);

  int get coverId => ids.first;

  bool get hasSpread =>
      (maxLat - minLat) > 0.00035 || (maxLon - minLon) > 0.00035;

  LatLngBounds get bounds =>
      LatLngBounds(LatLng(minLat, minLon), LatLng(maxLat, maxLon));

  String get dateRangeLabel {
    if (maxTakenAt <= 0) return '';
    final newest = formatMediaDate(maxTakenAt);
    if (minTakenAt <= 0 || minTakenAt == maxTakenAt) return newest;
    final oldest = formatMediaDate(minTakenAt);
    return oldest == newest ? newest : '$oldest – $newest';
  }
}

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

/// Grid cell size in degrees for a given zoom level. At street/building zoom
/// levels (16–18), cells narrow down to ~300m / ~120m / ~45m so nearby spots
/// in the same neighborhood split cleanly while same-spot burst photos stay
/// grouped.
double geoClusterCellDegrees(double zoom) {
  final z = zoom.clamp(0, 18).floor();
  if (z >= 18) return 0.0004;
  if (z == 17) return 0.0011;
  if (z == 16) return 0.0027;
  return (360 / math.pow(2, z)).clamp(0.0004, 90.0);
}

List<_GeoGroup> _clusters(List<PhotoGeoPoint> points, double zoom) {
  final cell = geoClusterCellDegrees(zoom);
  final grouped = <String, _GeoGroup>{};
  for (final p in points) {
    final key = '${(p.lat / cell).floor()}:${(p.lon / cell).floor()}';
    final group = grouped.putIfAbsent(key, () => _GeoGroup(key));
    group.add(p);
  }
  // Deterministic order: biggest clusters first, so when the render cap
  // applies the dropped groups are the smallest ones.
  final groups = grouped.values.toList()
    ..sort((a, b) => b.ids.length.compareTo(a.ids.length));
  return groups;
}

LatLngBounds? geoPointsBounds(List<PhotoGeoPoint> points) {
  if (points.isEmpty) return null;
  var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
  for (final p in points) {
    if (p.lat < minLat) minLat = p.lat;
    if (p.lat > maxLat) maxLat = p.lat;
    if (p.lon < minLon) minLon = p.lon;
    if (p.lon > maxLon) maxLon = p.lon;
  }
  return LatLngBounds(LatLng(minLat, minLon), LatLng(maxLat, maxLon));
}

Future<({PhotoMapTileSource source, String customUrl})?> _showTileConfigSheet(
  BuildContext context, {
  required PhotoMapTileSource initialSource,
  required String initialUrl,
}) async {
  var source = initialSource;
  var input = initialUrl;
  String? validation;
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, update) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          14,
          20,
          MediaQuery.viewInsetsOf(sheetContext).bottom + 24,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '选择地图来源',
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              const Text('在线地图由第三方提供，可能收到访问 IP 和浏览范围，但不会收到照片原件。'),
              const SizedBox(height: 12),
              DropdownButtonFormField<PhotoMapTileSource>(
                initialValue: source,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '地图来源',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final candidate in PhotoMapTileSource.values)
                    DropdownMenuItem(
                      value: candidate,
                      child: Text(candidate.label),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    update(() {
                      source = value;
                      validation = null;
                    });
                  }
                },
              ),
              if (source == PhotoMapTileSource.tianditu) ...[
                const SizedBox(height: 12),
                const Text(
                  '天地图由 Mac 统一配置。请管理员到 Mac 版 LightIsle「设置 → 媒体服务」填写 Key，手机无需单独设置。',
                ),
              ] else if (source == PhotoMapTileSource.custom) ...[
                const SizedBox(height: 12),
                TextFormField(
                  key: ValueKey(
                    input == PhotoMapTiles.openStreetMapUrl
                        ? 'default-custom-url'
                        : 'custom-url',
                  ),
                  initialValue: input,
                  onChanged: (value) => input = value,
                  decoration: InputDecoration(
                    labelText: '自定义地图地址',
                    hintText: PhotoMapTiles.openStreetMapUrl,
                    errorText: validation,
                    border: const OutlineInputBorder(),
                  ),
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                ),
                TextButton(
                  onPressed: () => update(() {
                    input = PhotoMapTiles.openStreetMapUrl;
                    validation = null;
                  }),
                  child: const Text('恢复默认地址'),
                ),
              ] else ...[
                const SizedBox(height: 12),
                const Text('使用 OpenStreetMap 在线地图。请遵守服务商的使用规定。'),
              ],
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  onPressed: () {
                    final issue = switch (source) {
                      PhotoMapTileSource.tianditu => null,
                      PhotoMapTileSource.openStreetMap => null,
                      PhotoMapTileSource.custom =>
                        PhotoMapTiles.validateCustomUrl(input),
                    };
                    if (issue != null) {
                      update(() => validation = issue);
                    } else {
                      Navigator.pop(sheetContext, true);
                    }
                  },
                  child: const Text('保存地图设置'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (saved != true) return null;
  return (source: source, customUrl: input.trim());
}

class _PhotoMapOptionsHeader extends StatelessWidget {
  const _PhotoMapOptionsHeader({
    required this.total,
    required this.loadedCount,
    required this.truncated,
    required this.clustersNotice,
    required this.compactOptions,
    required this.expanded,
    required this.tileSourceReady,
    required this.tileSource,
    required this.mapStatusError,
    required this.tilesFailed,
    required this.onToggleExpand,
    required this.onConfigureTiles,
    required this.onRefreshConfig,
    required this.onRetryTiles,
  });

  final int total;
  final int loadedCount;
  final bool truncated;
  final String? clustersNotice;
  final bool compactOptions;
  final bool expanded;
  final bool tileSourceReady;
  final PhotoMapTileSource tileSource;
  final bool mapStatusError;
  final bool tilesFailed;
  final VoidCallback onToggleExpand;
  final VoidCallback onConfigureTiles;
  final VoidCallback onRefreshConfig;
  final VoidCallback onRetryTiles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IsleSurface(
      margin: EdgeInsets.symmetric(
        horizontal: IsleLayout.pageInset(MediaQuery.sizeOf(context).width),
        vertical: 6,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      radius: 14,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$total 张位置照片${truncated ? "（显示最新 $loadedCount 张）" : ""}',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (clustersNotice != null)
            Text(clustersNotice!, style: theme.textTheme.bodySmall),
          if (compactOptions)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onToggleExpand,
                icon: Icon(
                  expanded ? Icons.expand_less_rounded : Icons.tune_rounded,
                ),
                label: Text(expanded ? '收起地图选项' : '地图选项'),
              ),
            ),
          if (compactOptions && !expanded && !tileSourceReady)
            Text('底图尚未配置，可展开地图选项了解详情', style: theme.textTheme.bodySmall),
          if (!compactOptions || expanded) ...[
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      tileSourceReady ? Icons.public : Icons.info_outline,
                      size: 16,
                      color: tileSourceReady
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        tileSourceReady
                            ? '在线底图已默认开启（仅 Mac 端可关闭）'
                            : '等待 Mac 端配置地图 Key',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
                TextButton.icon(
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('地图设置'),
                  onPressed: onConfigureTiles,
                ),
              ],
            ),
            if (!tileSourceReady && tileSource == PhotoMapTileSource.tianditu)
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    mapStatusError
                        ? '无法读取地图设置，请检查 Mac 是否在线。'
                        : '天地图还没有设置，请管理员在 Mac 版 LightIsle「设置 → 媒体服务」填写 Key。',
                  ),
                  TextButton.icon(
                    onPressed: onRefreshConfig,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新检查'),
                  ),
                ],
              ),
            if (tilesFailed && tileSourceReady)
              Notice(
                '地图暂时无法加载，但照片位置仍可查看。请检查网络，重试或在「地图设置」中更换来源。',
                onRetry: onRetryTiles,
              ),
          ],
        ],
      ),
    );
  }
}
