import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/lightisle_api.dart';
import 'media_models.dart';

/// Only the authorized NAS supplies GPS IDs; third-party tiles are opt-in.
class PhotoMapPage extends StatefulWidget {
  const PhotoMapPage({required this.api, this.initialZoom = 5, super.key});
  final LightIsleApi api;

  /// Starting zoom; also the hook that lets tests exercise dense clusters.
  final double initialZoom;

  @override
  State<PhotoMapPage> createState() => _PhotoMapPageState();
}

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

class _PhotoMapPageState extends State<PhotoMapPage> {
  static const _consentKey = 'lightisle_flutter_map_tiles_enabled';
  final _controller = MapController();
  List<PhotoGeoPoint> _points = [];
  int _total = 0;
  bool _truncated = false, _loading = true, _online = false, _opening = false;
  String? _error;
  double _zoom = 5;

  @override
  void initState() {
    super.initState();
    _zoom = widget.initialZoom;
    _load();
    _readConsent();
  }

  Future<void> _readConsent() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        setState(() => _online = prefs.getBool(_consentKey) ?? false);
      }
    } catch (_) {
      /* No persisted consent: remain offline. */
    }
  }

  Future<void> _toggleTiles(bool enabled) async {
    if (enabled) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_consentKey, true);
      } catch (_) {
        return;
      }
    } else {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_consentKey, false);
      } catch (_) {
        /* Immediately disable even if storage fails. */
      }
    }
    if (mounted) setState(() => _online = enabled);
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final json = await widget.api.get('/api/v2/photos/geo');
      final raw = json['points'];
      if (raw is! List) {
        throw const FormatException('Invalid photo geo response');
      }
      final points = raw
          .map(PhotoGeoPoint.parse)
          .whereType<PhotoGeoPoint>()
          .toList();
      if (!mounted) return;
      setState(() {
        _points = points;
        _total = (json['total'] as num?)?.toInt() ?? points.length;
        _truncated = json['truncated'] == true;
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '读取位置照片失败：$error';
        });
      }
    }
  }

  Future<void> _open(_GeoGroup group) async {
    if (_opening) return;
    if (group.ids.length > 1 && _zoom < 16) {
      _controller.move(group.location, math.min(17.0, _zoom + 2));
      return;
    }
    setState(() => _opening = true);
    try {
      // Do not trust geolocation points for permission checks: re-query the
      // authenticated media list after every marker selection.
      final ids = group.ids.take(_maxSameLocationPhotos).toList();
      final json = await widget.api.get(
        '/api/v2/photos',
        query: {'ids': ids.join(','), 'limit': ids.length.toString()},
      );
      final raw = json['assets'];
      final assets = (raw is List ? raw : const [])
          .whereType<Map>()
          .map((r) => PhotoAsset.fromJson(Map<String, dynamic>.from(r)))
          .toList();
      if (!mounted) return;
      if (assets.length == 1) {
        Navigator.of(context).pop(assets.first);
      } else if (assets.isNotEmpty) {
        final picked = await showModalBottomSheet<PhotoAsset>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (context) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  title: Text(sameLocationPickerTitle(group.ids.length)),
                ),
                for (final asset in assets)
                  ListTile(
                    leading: Icon(asset.isVideo ? Icons.movie : Icons.photo),
                    title: Text(
                      asset.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.of(context).pop(asset),
                  ),
              ],
            ),
          ),
        );
        if (mounted && picked != null) {
          Navigator.of(context).pop(picked);
        }
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('照片可能已被移走，或当前账号没有访问权限。')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('打开照片失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allGroups = _clusters(_points, _zoom);
    final groups = allGroups.take(_maxRenderedGroups).toList();
    final clustersNotice = clusterCapNotice(allGroups.length);
    return Scaffold(
      appBar: AppBar(
        title: const Text('照片地图回溯'),
        actions: [
          IconButton(
            tooltip: '刷新位置照片',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '$_total 张位置照片${_truncated ? "（显示最新 ${_points.length} 张）" : ""}',
                ),
                if (clustersNotice != null)
                  Text(clustersNotice, style: theme.textTheme.bodySmall),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: Icon(_online ? Icons.public : Icons.shield_outlined),
                    label: Text(_online ? '在线底图 · 点击关闭' : '隐私模式 · 选择底图'),
                    onPressed: () async {
                      if (_online) {
                        await _toggleTiles(false);
                        return;
                      }
                      final enabled = await showModalBottomSheet<bool>(
                        context: context,
                        useSafeArea: true,
                        builder: (context) => SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                '在线地图底图',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                '隐私模式只绘制照片位置。启用 OpenStreetMap 后，会向第三方地图服务发送 IP 和地图范围；照片原图不会发送。',
                              ),
                              const SizedBox(height: 20),
                              FilledButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('同意并启用在线底图'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('保持隐私模式'),
                              ),
                            ],
                          ),
                        ),
                      );
                      if (enabled == true && mounted) await _toggleTiles(true);
                    },
                  ),
                ),
              ],
            ),
          ),
          if (_error != null)
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _points.isEmpty
                ? const Center(child: Text('暂无带 GPS 位置的照片或视频'))
                : Stack(
                    children: [
                      FlutterMap(
                        mapController: _controller,
                        options: MapOptions(
                          initialCenter: LatLng(
                            _points.first.lat,
                            _points.first.lon,
                          ),
                          initialZoom: _zoom,
                          backgroundColor: theme.colorScheme.surfaceContainer,
                          onPositionChanged: (camera, _) {
                            if ((camera.zoom - _zoom).abs() >= .75 && mounted) {
                              setState(() => _zoom = camera.zoom);
                            }
                          },
                        ),
                        children: [
                          if (_online)
                            TileLayer(
                              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                              userAgentPackageName: 'dev.lightisle.client',
                            ),
                          MarkerLayer(
                            markers: [
                              for (final group in groups)
                                Marker(
                                  point: group.location,
                                  width: 50,
                                  height: 50,
                                  child: IconButton.filledTonal(
                                    tooltip: '查看 ${group.ids.length} 张照片',
                                    onPressed: _opening
                                        ? null
                                        : () => _open(group),
                                    icon: group.ids.length == 1
                                        ? const Icon(Icons.photo, size: 20)
                                        : Text(group.ids.length.toString()),
                                  ),
                                ),
                            ],
                          ),
                          if (_online)
                            const RichAttributionWidget(
                              attributions: [
                                TextSourceAttribution(
                                  '© OpenStreetMap contributors',
                                ),
                              ],
                            ),
                        ],
                      ),
                      if (_opening)
                        const Align(
                          alignment: Alignment.topCenter,
                          child: LinearProgressIndicator(),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
