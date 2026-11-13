import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_cache_manager.dart';
import '../../core/isle_data_cache.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/media_image_memory_cache.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'media_models.dart';
import 'media_ui.dart';
import 'nas_map_tile_client.dart';
import 'photo_detail_dialog.dart';
import 'photo_gallery_viewer.dart';
import 'photo_map_tiles.dart';

part 'photo_map_models.dart';
part 'photo_map_sheet.dart';

/// Only the authorized NAS supplies GPS IDs; online map tiles are enabled
/// automatically whenever the configured tile source (e.g. Mac Tianditu Key)
/// is ready, and can only be turned off by clearing the Key on macOS.
class PhotoMapPage extends StatefulWidget {
  const PhotoMapPage({
    required this.api,
    this.initialZoom = 5,
    this.initialCenter,
    super.key,
  });
  final LightIsleApi api;

  /// Starting zoom; also the hook that lets tests exercise dense clusters.
  final double initialZoom;
  final LatLng? initialCenter;

  @override
  State<PhotoMapPage> createState() => _PhotoMapPageState();
}

class _PhotoMapPageState extends State<PhotoMapPage> {
  final _controller = MapController();
  MediaImageMemoryCache get _thumbCache =>
      IsleCacheManager.instance.sharedThumbnails;
  List<PhotoGeoPoint> _points = [];
  int _total = 0;
  bool _truncated = false, _loading = true, _opening = false;
  bool _tilesFailed = false;
  bool _mapOptionsExpanded = false;
  bool _sheetExpanded = false;
  int _tileErrors = 0, _tileRevision = 0, _openGeneration = 0;
  PhotoMapTileSource _tileSource = PhotoMapTileSource.tianditu;
  String _tileUrl = PhotoMapTiles.openStreetMapUrl;
  bool _tiandituConfigured = false;
  bool _mapStatusError = false;
  late final NasMapTileClient _nasTileClient = NasMapTileClient(widget.api);
  late final CachedPublicMapTileClient _publicTileClient =
      CachedPublicMapTileClient();
  String? _error;
  String? _sheetError;
  _GeoGroup? _selectedGroup;
  List<PhotoAsset> _selectedAssets = const [];
  double _zoom = 5;

  bool get _tileSourceReady => PhotoMapTiles.isReady(
    source: _tileSource,
    tiandituConfigured: _tiandituConfigured,
    customUrl: _tileUrl,
  );
  bool get _showOnlineTiles => !_tilesFailed && _tileSourceReady;

  @override
  void initState() {
    super.initState();
    _zoom = widget.initialZoom.clamp(photoMapMinZoom, photoMapMaxZoom);
    _load();
    _readConsent();
    _refreshMapConfiguration();
  }

  Future<bool> _refreshMapConfiguration() async {
    try {
      final json = await widget.api.get('/api/v2/map/status');
      final configured = json['tiandituConfigured'] == true;
      if (mounted) {
        setState(() {
          _tiandituConfigured = configured;
          _mapStatusError = false;
        });
      }
      return configured;
    } catch (_) {
      if (mounted) {
        setState(() {
          _tiandituConfigured = false;
          _mapStatusError = true;
        });
      }
      return false;
    }
  }

  Future<void> _readConsent() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        final savedUrl = prefs.getString(PhotoMapTiles.customUrlKey);
        final selectedSource = PhotoMapTiles.migratedSource(
          storedSource: prefs.getString(PhotoMapTiles.sourceKey),
          legacyCustomUrl: savedUrl,
          previouslyEnabled: false,
        );
        // The old Flutter version persisted the provider credential in local
        // preferences. Drop that insecure copy; never transmit it to NAS.
        await prefs.remove(PhotoMapTiles.legacyTiandituKey);
        await prefs.remove(PhotoMapTiles.consentKey);
        if (!mounted) return;
        setState(() {
          _tileSource = selectedSource;
          _tileUrl =
              savedUrl != null &&
                  PhotoMapTiles.validateCustomUrl(savedUrl) == null
              ? savedUrl
              : PhotoMapTiles.openStreetMapUrl;
        });
      }
    } catch (_) {
      /* Default to Tianditu in memory even if local storage is unavailable. */
    }
  }

  void _resetTileFailure() {
    _tilesFailed = false;
    _tileErrors = 0;
    _tileRevision++;
  }

  void _onTileError() {
    if (!mounted || !_tileSourceReady || _tilesFailed) return;
    _tileErrors++;
    // A single missing tile must not disable an otherwise working service.
    if (_tileErrors >= 4) {
      setState(() => _tilesFailed = true);
    }
  }

  Future<void> _configureTiles() async {
    final result = await _showTileConfigSheet(
      context,
      initialSource: _tileSource,
      initialUrl: _tileUrl,
    );
    if (result == null || !mounted) return;
    setState(() {
      _tileSource = result.source;
      _tileUrl = result.customUrl;
      _resetTileFailure();
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PhotoMapTiles.sourceKey,
        result.source.storageValue,
      );
      await prefs.setString(PhotoMapTiles.customUrlKey, result.customUrl);
      await prefs.remove(PhotoMapTiles.legacyTiandituKey);
      await prefs.remove(PhotoMapTiles.consentKey);
    } catch (_) {
      /* Keep the new tile source active in memory even if storage fails. */
    }
  }

  Future<void> _load() async {
    final cached = IsleDataCache.instance.getJsonMap(
      widget.api,
      'photos_geo',
      'all',
    );
    if (cached != null && _points.isEmpty) {
      final rawCached = cached['points'];
      if (rawCached is List) {
        final cachedPoints = rawCached
            .map(PhotoGeoPoint.parse)
            .whereType<PhotoGeoPoint>()
            .toList();
        if (mounted) {
          setState(() {
            _points = cachedPoints;
            _total = (cached['total'] as num?)?.toInt() ?? cachedPoints.length;
            _truncated = cached['truncated'] == true;
            _loading = false;
            _error = null;
          });
        }
      }
    } else if (mounted) {
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
      IsleDataCache.instance.putJsonMap(widget.api, 'photos_geo', 'all', json);
      if (!mounted) return;
      setState(() {
        _points = points;
        _total = (json['total'] as num?)?.toInt() ?? points.length;
        _truncated = json['truncated'] == true;
        _selectedGroup = null;
        _selectedAssets = const [];
        _sheetError = null;
        _loading = false;
      });
    } catch (error) {
      if (mounted && _points.isEmpty) {
        setState(() {
          _loading = false;
          _error = '读取位置照片失败：${userFacingError(error)}';
        });
      }
    }
  }

  void _moveCameraSafe(LatLng center, double zoom) {
    final targetZoom = zoom.clamp(photoMapMinZoom, photoMapMaxZoom);
    try {
      _controller.move(center, targetZoom);
    } catch (_) {
      // MapController may not yet be attached during synchronous widget tests.
    }
  }

  void _zoomBy(double delta) {
    final nextZoom = (_zoom + delta).clamp(photoMapMinZoom, photoMapMaxZoom);
    if ((nextZoom - _zoom).abs() < 0.01) return;
    LatLng center =
        _selectedGroup?.location ??
        (_points.isNotEmpty
            ? LatLng(_points.first.lat, _points.first.lon)
            : const LatLng(31.2304, 121.4737));
    try {
      center = _controller.camera.center;
    } catch (_) {
      // MapController camera is unavailable before initial layout attachment.
    }
    setState(() => _zoom = nextZoom);
    _moveCameraSafe(center, nextZoom);
  }

  void _fitAllFootprints() {
    if (_points.isEmpty) return;
    final bounds = geoPointsBounds(_points);
    if (bounds == null) return;
    final latSpan = (bounds.north - bounds.south).abs();
    final lonSpan = (bounds.east - bounds.west).abs();
    if (latSpan < 0.001 && lonSpan < 0.001) {
      setState(() => _zoom = 14);
      _moveCameraSafe(bounds.center, 14);
      return;
    }
    try {
      _controller.fitCamera(
        CameraFit.bounds(
          bounds: bounds,
          padding: const EdgeInsets.all(48),
          maxZoom: 15,
          minZoom: photoMapMinZoom,
        ),
      );
      setState(
        () => _zoom = _controller.camera.zoom.clamp(
          photoMapMinZoom,
          photoMapMaxZoom,
        ),
      );
    } catch (_) {
      setState(() => _zoom = 5);
      _moveCameraSafe(bounds.center, 5);
    }
  }

  Future<void> _selectGroup(_GeoGroup group, {bool centerCamera = true}) async {
    final generation = ++_openGeneration;
    setState(() {
      _selectedGroup = group;
      _opening = true;
      _sheetError = null;
      _selectedAssets = const [];
    });
    if (centerCamera) {
      _moveCameraSafe(group.location, _zoom);
    }
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
      if (!mounted || generation != _openGeneration) return;
      setState(() {
        _selectedAssets = assets;
        _opening = false;
      });
    } catch (error) {
      if (!mounted || generation != _openGeneration) return;
      setState(() {
        _opening = false;
        _sheetError = '打开照片失败：${userFacingError(error)}';
      });
    }
  }

  void _zoomIntoCluster(_GeoGroup group) {
    final nextZoom = math.min(photoMapMaxZoom, _zoom + 2.5);
    setState(() => _zoom = nextZoom);
    _moveCameraSafe(group.location, nextZoom);
    final updatedGroups = _clusters(
      _points,
      nextZoom,
    ).take(_maxRenderedGroups).toList();
    if (updatedGroups.isEmpty) return;
    _GeoGroup nearest = updatedGroups.first;
    var bestDist = double.infinity;
    for (final candidate in updatedGroups) {
      final dLat = candidate.location.latitude - group.location.latitude;
      final dLon = candidate.location.longitude - group.location.longitude;
      final dist = dLat * dLat + dLon * dLon;
      if (dist < bestDist) {
        bestDist = dist;
        nearest = candidate;
      }
    }
    unawaited(_selectGroup(nearest, centerCamera: false));
  }

  void _stepCluster(int delta, List<_GeoGroup> groups) {
    if (groups.isEmpty) return;
    final currentKey = _selectedGroup?.key;
    final currentIndex = currentKey == null
        ? 0
        : groups.indexWhere((g) => g.key == currentKey);
    final nextIndex =
        ((currentIndex < 0 ? 0 : currentIndex) + delta + groups.length) %
        groups.length;
    unawaited(_selectGroup(groups[nextIndex]));
  }

  Future<void> _showMapAssetDetails(PhotoAsset asset) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.78,
        child: PhotoDetailDialog(
          api: widget.api,
          asset: asset,
          albums: const [],
          isAdmin: false,
          currentAlbumId: 0,
          canToggleFavorite: false,
          onToggleFavorite: (a) async => a,
          onAddToAlbum: (_, _) async {},
          onRemoveFromAlbum: (_, _) async {},
          metadataOnly: true,
        ),
      ),
    );
  }

  Future<void> _openAssetInViewer(
    PhotoAsset asset,
    List<PhotoAsset> groupAssets,
  ) async {
    final initialIndex = math.max(
      0,
      groupAssets.indexWhere((item) => item.id == asset.id),
    );
    await Navigator.of(context).push<void>(
      buildIslePageRoute<void>(
        builder: (_) => PhotoGalleryViewer(
          api: widget.api,
          memoryCache: _thumbCache,
          assets: List<PhotoAsset>.of(groupAssets),
          initialIndex: initialIndex,
          fileBrowserMode: true,
          canEditSharedFavorite: (_) => false,
          onSharedFavorite: (item) async => item,
          onPersonalFavorite: (item) async => item,
          onDetails: _showMapAssetDetails,
          onLoadMore: () async => const [],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _openGeneration++;
    _nasTileClient.close();
    _publicTileClient.close();
    _controller.dispose();
    super.dispose();
  }

  Widget _buildTopBannerArea(
    BuildContext context,
    BoxConstraints viewport, {
    required String? clustersNotice,
    required bool compactOptions,
  }) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: (viewport.maxHeight * .38).clamp(88.0, 220.0),
    ),
    child: SingleChildScrollView(
      child: Column(
        children: [
          _PhotoMapOptionsHeader(
            total: _total,
            loadedCount: _points.length,
            truncated: _truncated,
            clustersNotice: clustersNotice,
            compactOptions: compactOptions,
            expanded: _mapOptionsExpanded,
            tileSourceReady: _tileSourceReady,
            tileSource: _tileSource,
            mapStatusError: _mapStatusError,
            tilesFailed: _tilesFailed,
            onToggleExpand: () =>
                setState(() => _mapOptionsExpanded = !_mapOptionsExpanded),
            onConfigureTiles: _configureTiles,
            onRefreshConfig: _refreshMapConfiguration,
            onRetryTiles: () => setState(_resetTileFailure),
          ),
          if (_error != null)
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: IsleLayout.pageInset(
                  MediaQuery.sizeOf(context).width,
                ),
              ),
              child: Notice(_error!, error: true, onRetry: _load),
            ),
        ],
      ),
    ),
  );

  Widget _buildEmptyGeoState() => LayoutBuilder(
    builder: (context, remaining) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: remaining.maxHeight),
        child: Center(
          child: MediaEmptyState(
            icon: Icons.map_outlined,
            title: _error == null ? '暂无带 GPS 位置的照片' : '位置照片未能读取',
            message: _error == null
                ? '请确认拍摄时开启了定位，并等待 NAS 完成索引。'
                : '请确认 NAS 在线、存储盘已连接，或稍后重试。',
            action: OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('重新读取位置'),
            ),
          ),
        ),
      ),
    ),
  );

  List<Widget> _buildMapTileLayers() {
    if (!_showOnlineTiles) return const <Widget>[];
    if (_tileSource == PhotoMapTileSource.tianditu) {
      final origin = widget.api.uri('/api/v2/map/status').origin;
      return <Widget>[
        TileLayer(
          key: ValueKey('tdt-vector-$_tileRevision'),
          urlTemplate: origin + PhotoMapTiles.tiandituUrl('vec'),
          tileProvider: NetworkTileProvider(httpClient: _nasTileClient),
          maxNativeZoom: 18,
          maxZoom: 18,
          userAgentPackageName: 'dev.lightisle.client',
          errorTileCallback: (_, _, _) => _onTileError(),
        ),
        TileLayer(
          key: ValueKey('tdt-labels-$_tileRevision'),
          urlTemplate: origin + PhotoMapTiles.tiandituUrl('cva'),
          tileProvider: NetworkTileProvider(httpClient: _nasTileClient),
          maxNativeZoom: 18,
          maxZoom: 18,
          userAgentPackageName: 'dev.lightisle.client',
          errorTileCallback: (_, _, _) => _onTileError(),
        ),
      ];
    }
    return <Widget>[
      TileLayer(
        key: ValueKey('tiles-$_tileRevision'),
        urlTemplate: _tileSource == PhotoMapTileSource.openStreetMap
            ? PhotoMapTiles.openStreetMapUrl
            : _tileUrl,
        tileProvider: NetworkTileProvider(httpClient: _publicTileClient),
        maxNativeZoom: 18,
        maxZoom: 18,
        userAgentPackageName: 'dev.lightisle.client',
        errorTileCallback: (_, _, _) => _onTileError(),
      ),
    ];
  }

  Widget _buildInteractiveMapStack(
    ThemeData theme,
    List<_GeoGroup> groups,
    _GeoGroup? activeGroup,
    int selectedIndex,
  ) => Stack(
    children: [
      FlutterMap(
        mapController: _controller,
        options: MapOptions(
          initialCenter:
              widget.initialCenter ??
              LatLng(_points.first.lat, _points.first.lon),
          initialZoom: _zoom,
          minZoom: photoMapMinZoom,
          maxZoom: photoMapMaxZoom,
          cameraConstraint: CameraConstraint.contain(
            bounds: LatLngBounds(
              const LatLng(-85.0, -180.0),
              const LatLng(85.0, 180.0),
            ),
          ),
          backgroundColor: theme.colorScheme.surfaceContainer,
          onTap: (_, _) {
            if (_selectedGroup != null) {
              setState(() {
                _selectedGroup = null;
                _selectedAssets = const [];
                _sheetError = null;
              });
            }
          },
          onPositionChanged: (camera, _) {
            final clamped = camera.zoom.clamp(photoMapMinZoom, photoMapMaxZoom);
            if ((clamped - _zoom).abs() >= .25 && mounted) {
              setState(() => _zoom = clamped);
            }
          },
        ),
        children: [
          ..._buildMapTileLayers(),
          MarkerLayer(
            markers: [
              for (var i = 0; i < groups.length; i++)
                Marker(
                  point: groups[i].location,
                  width: 68,
                  height: 70,
                  child: _PhotoMapPin(
                    key: ValueKey('photo-map-pin-${groups[i].coverId}'),
                    api: widget.api,
                    memoryCache: _thumbCache,
                    group: groups[i],
                    selected: groups[i].key == activeGroup?.key,
                    loadThumbnail:
                        i < _maxThumbnailMarkers ||
                        groups[i].key == activeGroup?.key,
                    onTap: () => _selectGroup(groups[i]),
                  ),
                ),
            ],
          ),
          if (_showOnlineTiles)
            RichAttributionWidget(
              attributions: [
                TextSourceAttribution(switch (_tileSource) {
                  PhotoMapTileSource.tianditu => '© 天地图',
                  PhotoMapTileSource.openStreetMap =>
                    '© OpenStreetMap contributors',
                  PhotoMapTileSource.custom => '地图来源：用户配置的瓦片服务',
                }),
              ],
            ),
        ],
      ),
      Positioned(
        top: 12,
        right: 12,
        child: _MapZoomControls(
          zoom: _zoom,
          onZoomIn: () => _zoomBy(1.5),
          onZoomOut: () => _zoomBy(-1.5),
          onFitAll: _fitAllFootprints,
        ),
      ),
      if (activeGroup != null)
        _LocationPhotoSheet(
          api: widget.api,
          memoryCache: _thumbCache,
          group: activeGroup,
          assets: _selectedAssets,
          loading: _opening,
          error: _sheetError,
          expanded: _sheetExpanded,
          canZoomCluster:
              activeGroup.ids.length > 1 &&
              (activeGroup.hasSpread || _zoom < 15.5) &&
              _zoom < photoMapMaxZoom - 0.1,
          clusterIndex: selectedIndex >= 0 ? selectedIndex : 0,
          totalClusters: groups.length,
          onToggleExpand: () =>
              setState(() => _sheetExpanded = !_sheetExpanded),
          onZoomCluster: () => _zoomIntoCluster(activeGroup),
          onStepCluster: (delta) => _stepCluster(delta, groups),
          onRetry: () => _selectGroup(activeGroup, centerCamera: false),
          onClose: () => setState(() {
            _selectedGroup = null;
            _selectedAssets = const [];
            _sheetError = null;
          }),
          onOpenAsset: _openAssetInViewer,
        ),
      if (_opening)
        const Align(
          alignment: Alignment.topCenter,
          child: LinearProgressIndicator(),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allGroups = _clusters(_points, _zoom);
    final groups = allGroups.take(_maxRenderedGroups).toList();
    final clustersNotice = clusterCapNotice(allGroups.length);
    final selectedKey = _selectedGroup?.key;
    final selectedIndex = selectedKey == null
        ? -1
        : groups.indexWhere((g) => g.key == selectedKey);
    final activeGroup = selectedIndex >= 0
        ? groups[selectedIndex]
        : _selectedGroup;
    final compactOptions =
        MediaQuery.sizeOf(context).width < 520 ||
        MediaQuery.textScalerOf(context).scale(14) > 19;
    return Scaffold(
      appBar: IsleAppBar(
        title: const Text('照片地图'),
        actions: [
          IconButton(
            tooltip: '刷新位置照片',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, viewport) => Column(
          children: [
            _buildTopBannerArea(
              context,
              viewport,
              clustersNotice: clustersNotice,
              compactOptions: compactOptions,
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _points.isEmpty
                  ? _buildEmptyGeoState()
                  : _buildInteractiveMapStack(
                      theme,
                      groups,
                      activeGroup,
                      selectedIndex,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
