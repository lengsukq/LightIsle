import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/lightisle_api.dart';
import '../../core/isle_theme.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'media_models.dart';
import 'media_ui.dart';
import 'nas_map_tile_client.dart';
import 'photo_map_tiles.dart';

part 'photo_map_models.dart';

/// Only the authorized NAS supplies GPS IDs; third-party tiles are opt-in.
class PhotoMapPage extends StatefulWidget {
  const PhotoMapPage({required this.api, this.initialZoom = 5, super.key});
  final LightIsleApi api;

  /// Starting zoom; also the hook that lets tests exercise dense clusters.
  final double initialZoom;

  @override
  State<PhotoMapPage> createState() => _PhotoMapPageState();
}

class _PhotoMapPageState extends State<PhotoMapPage> {
  final _controller = MapController();
  List<PhotoGeoPoint> _points = [];
  int _total = 0;
  bool _truncated = false, _loading = true, _online = false, _opening = false;
  bool _tilesFailed = false;
  bool _mapOptionsExpanded = false;
  int _tileErrors = 0, _tileRevision = 0;
  PhotoMapTileSource _tileSource = PhotoMapTileSource.tianditu;
  String _tileUrl = PhotoMapTiles.openStreetMapUrl;
  bool _tiandituConfigured = false;
  bool _mapStatusError = false;
  late final NasMapTileClient _nasTileClient = NasMapTileClient(widget.api);
  String? _error;
  double _zoom = 5;

  bool get _tileSourceReady => PhotoMapTiles.isReady(
    source: _tileSource,
    tiandituConfigured: _tiandituConfigured,
    customUrl: _tileUrl,
  );
  bool get _showOnlineTiles => _online && !_tilesFailed && _tileSourceReady;

  @override
  void initState() {
    super.initState();
    _zoom = widget.initialZoom;
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
        final previouslyEnabled =
            prefs.getBool(PhotoMapTiles.consentKey) ?? false;
        final selectedSource = PhotoMapTiles.migratedSource(
          storedSource: prefs.getString(PhotoMapTiles.sourceKey),
          legacyCustomUrl: savedUrl,
          previouslyEnabled: previouslyEnabled,
        );
        // The old Flutter version persisted the provider credential in local
        // preferences. Drop that insecure copy; never transmit it to NAS.
        await prefs.remove(PhotoMapTiles.legacyTiandituKey);
        if (!mounted) return;
        setState(() {
          _online = previouslyEnabled;
          _tileSource = selectedSource;
          _tileUrl =
              savedUrl != null &&
                  PhotoMapTiles.validateCustomUrl(savedUrl) == null
              ? savedUrl
              : PhotoMapTiles.openStreetMapUrl;
        });
      }
    } catch (_) {
      /* No persisted consent: remain offline. */
    }
  }

  Future<void> _toggleTiles(bool enabled) async {
    if (enabled && _tileSource == PhotoMapTileSource.tianditu) {
      final configured = await _refreshMapConfiguration();
      if (!mounted) return;
      if (!configured) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('请管理员在 Mac 版 LightIsle「设置 → 媒体服务」配置天地图 Key。'),
          ),
        );
        return;
      }
    }
    if (enabled && !_tileSourceReady) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('所选瓦片地址无效，请先检查「底图设置」。')));
      await _configureTiles();
      return;
    }
    if (enabled) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(PhotoMapTiles.consentKey, true);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('无法保存地图授权，请检查应用存储状态。')));
        }
        return;
      }
    } else {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(PhotoMapTiles.consentKey, false);
      } catch (_) {
        /* Immediately disable even if storage fails. */
      }
    }
    if (mounted) {
      setState(() {
        _online = enabled;
        _resetTileFailure();
      });
    }
  }

  void _resetTileFailure() {
    _tilesFailed = false;
    _tileErrors = 0;
    _tileRevision++;
  }

  void _onTileError() {
    if (!mounted || !_online || _tilesFailed) return;
    _tileErrors++;
    // A single missing tile must not disable an otherwise working service.
    if (_tileErrors >= 4) {
      setState(() => _tilesFailed = true);
    }
  }

  Future<void> _configureTiles() async {
    var source = _tileSource;
    var input = _tileUrl;
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
    if (saved != true || !mounted) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(PhotoMapTiles.sourceKey, source.storageValue);
      await prefs.setString(PhotoMapTiles.customUrlKey, input.trim());
      await prefs.remove(PhotoMapTiles.legacyTiandituKey);
      if (!PhotoMapTiles.isReady(
        source: source,
        tiandituConfigured: _tiandituConfigured,
        customUrl: input.trim(),
      )) {
        await prefs.setBool(PhotoMapTiles.consentKey, false);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法保存地图设置，请检查应用存储权限后重试。')));
      }
      return;
    }
    if (mounted) {
      setState(() {
        _tileSource = source;
        _tileUrl = input.trim();
        if (!_tileSourceReady) _online = false;
        _resetTileFailure();
      });
    }
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
          _error = '读取位置照片失败：${userFacingError(error)}';
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
    _nasTileClient.close();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allGroups = _clusters(_points, _zoom);
    final groups = allGroups.take(_maxRenderedGroups).toList();
    final clustersNotice = clusterCapNotice(allGroups.length);
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
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: (viewport.maxHeight * .42).clamp(96.0, 260.0),
              ),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    IsleSurface(
                      margin: EdgeInsets.symmetric(
                        horizontal: IsleLayout.pageInset(
                          MediaQuery.sizeOf(context).width,
                        ),
                        vertical: 6,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      radius: 14,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$_total 张位置照片${_truncated ? "（显示最新 ${_points.length} 张）" : ""}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                          if (clustersNotice != null)
                            Text(
                              clustersNotice,
                              style: theme.textTheme.bodySmall,
                            ),
                          if (compactOptions)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                onPressed: () => setState(
                                  () => _mapOptionsExpanded =
                                      !_mapOptionsExpanded,
                                ),
                                icon: Icon(
                                  _mapOptionsExpanded
                                      ? Icons.expand_less_rounded
                                      : Icons.tune_rounded,
                                ),
                                label: Text(
                                  _mapOptionsExpanded ? '收起地图选项' : '地图选项',
                                ),
                              ),
                            ),
                          if (compactOptions &&
                              !_mapOptionsExpanded &&
                              !_tileSourceReady)
                            Text(
                              '底图尚未配置，可展开地图选项了解详情',
                              style: theme.textTheme.bodySmall,
                            ),
                          if (!compactOptions || _mapOptionsExpanded) ...[
                            Wrap(
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 8,
                              children: [
                                TextButton.icon(
                                  icon: Icon(
                                    _online
                                        ? Icons.public
                                        : Icons.shield_outlined,
                                  ),
                                  label: Text(
                                    _online
                                        ? (_tileSourceReady
                                              ? '在线底图 · 点击关闭'
                                              : '等待 Mac 地图配置 · 点击关闭')
                                        : '启用在线地图',
                                  ),
                                  onPressed: () async {
                                    if (_online) {
                                      await _toggleTiles(false);
                                      return;
                                    }
                                    final enabled =
                                        await showModalBottomSheet<bool>(
                                          context: context,
                                          useSafeArea: true,
                                          builder: (context) =>
                                              SingleChildScrollView(
                                                padding:
                                                    const EdgeInsets.fromLTRB(
                                                      20,
                                                      0,
                                                      20,
                                                      24,
                                                    ),
                                                child: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      '显示在线地图',
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .titleLarge,
                                                    ),
                                                    const SizedBox(height: 12),
                                                    const Text(
                                                      '开启后可以看到道路和地名。地图服务可能收到访问 IP 和浏览范围，但不会收到照片原件。',
                                                    ),
                                                    const SizedBox(height: 20),
                                                    FilledButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                            context,
                                                            true,
                                                          ),
                                                      child: const Text(
                                                        '同意并开启地图',
                                                      ),
                                                    ),
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                            context,
                                                            false,
                                                          ),
                                                      child: const Text('暂不开启'),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                        );
                                    if (enabled == true && mounted) {
                                      await _toggleTiles(true);
                                    }
                                  },
                                ),
                                TextButton.icon(
                                  icon: const Icon(Icons.settings_outlined),
                                  label: const Text('地图设置'),
                                  onPressed: _configureTiles,
                                ),
                              ],
                            ),
                            if (!_tileSourceReady &&
                                _tileSource == PhotoMapTileSource.tianditu)
                              Wrap(
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(
                                    _mapStatusError ? '无法读取地图设置，请检查 Mac 是否在线。' : '天地图还没有设置，请管理员在 Mac 版 LightIsle「设置 → 媒体服务」填写 Key。',
                                  ),
                                  TextButton.icon(
                                    onPressed: () => _refreshMapConfiguration(),
                                    icon: const Icon(Icons.refresh),
                                    label: const Text('重新检查'),
                                  ),
                                ],
                              ),
                            if (!_online && _points.isNotEmpty)
                              Text(
                                '当前只显示照片位置。点击「启用在线地图」即可显示道路和地名。',
                                style: theme.textTheme.bodySmall,
                              ),
                            if (_tilesFailed && _online)
                              Notice(
                                '地图暂时无法加载，但照片位置仍可查看。请检查网络，重试或在「地图设置」中更换来源。',
                                onRetry: () => setState(_resetTileFailure),
                              ),
                          ],
                        ],
                      ),
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
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _points.isEmpty
                  ? LayoutBuilder(
                      builder: (context, remaining) => SingleChildScrollView(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: remaining.maxHeight,
                          ),
                          child: Center(
                            child: MediaEmptyState(
                              icon: Icons.map_outlined,
                              title: _error == null
                                  ? '暂无带 GPS 位置的照片'
                                  : '位置照片未能读取',
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
                    )
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
                              if ((camera.zoom - _zoom).abs() >= .75 &&
                                  mounted) {
                                setState(() => _zoom = camera.zoom);
                              }
                            },
                          ),
                          children: [
                            if (_showOnlineTiles &&
                                _tileSource == PhotoMapTileSource.tianditu) ...[
                              TileLayer(
                                key: ValueKey('tdt-vector-$_tileRevision'),
                                urlTemplate:
                                    widget.api
                                        .uri('/api/v2/map/status')
                                        .origin +
                                    PhotoMapTiles.tiandituUrl('vec'),
                                tileProvider: NetworkTileProvider(
                                  httpClient: _nasTileClient,
                                ),
                                maxNativeZoom: 18,
                                userAgentPackageName: 'dev.lightisle.client',
                                errorTileCallback: (_, _, _) => _onTileError(),
                              ),
                              TileLayer(
                                key: ValueKey('tdt-labels-$_tileRevision'),
                                urlTemplate:
                                    widget.api
                                        .uri('/api/v2/map/status')
                                        .origin +
                                    PhotoMapTiles.tiandituUrl('cva'),
                                tileProvider: NetworkTileProvider(
                                  httpClient: _nasTileClient,
                                ),
                                maxNativeZoom: 18,
                                userAgentPackageName: 'dev.lightisle.client',
                                errorTileCallback: (_, _, _) => _onTileError(),
                              ),
                            ] else if (_showOnlineTiles)
                              TileLayer(
                                key: ValueKey('tiles-$_tileRevision'),
                                urlTemplate:
                                    _tileSource ==
                                        PhotoMapTileSource.openStreetMap
                                    ? PhotoMapTiles.openStreetMapUrl
                                    : _tileUrl,
                                userAgentPackageName: 'dev.lightisle.client',
                                errorTileCallback: (_, _, _) => _onTileError(),
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
                            if (_showOnlineTiles)
                              RichAttributionWidget(
                                attributions: [
                                  TextSourceAttribution(switch (_tileSource) {
                                    PhotoMapTileSource.tianditu => '© 天地图',
                                    PhotoMapTileSource.openStreetMap =>
                                      '© OpenStreetMap contributors',
                                    PhotoMapTileSource.custom =>
                                      '地图来源：用户配置的瓦片服务',
                                  }),
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
      ),
    );
  }
}
