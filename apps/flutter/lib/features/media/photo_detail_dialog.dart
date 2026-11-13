import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../../core/lightisle_api.dart';
import 'media_models.dart';
import 'photo_gallery_viewer.dart';
import 'photo_live_text_card.dart';
import 'photo_map_page.dart';
import 'media_ui.dart';

class PhotoDetailDialog extends StatefulWidget {
  const PhotoDetailDialog({
    required this.api,
    required this.asset,
    required this.albums,
    this.privateAlbums = const [],
    required this.isAdmin,
    required this.currentAlbumId,
    this.currentPrivateAlbumId = 0,
    this.personalFavoritesOnly = false,
    required this.canToggleFavorite,
    required this.onToggleFavorite,
    this.onTogglePersonalFavorite,
    required this.onAddToAlbum,
    required this.onRemoveFromAlbum,
    this.onAddToPrivateAlbum,
    this.onRemoveFromPrivateAlbum,
    this.onSelectSceneLabel,
    this.onSelectPerson,
    this.metadataOnly = false,
    super.key,
  });

  final LightIsleApi api;
  final PhotoAsset asset;
  final List<MediaAlbum> albums;
  final List<MediaAlbum> privateAlbums;
  final bool isAdmin;
  final int currentAlbumId;
  final int currentPrivateAlbumId;
  final bool personalFavoritesOnly;
  final bool canToggleFavorite;
  final Future<PhotoAsset> Function(PhotoAsset asset) onToggleFavorite;
  final Future<PhotoAsset> Function(PhotoAsset asset)? onTogglePersonalFavorite;
  final Future<void> Function(int albumId, int assetId) onAddToAlbum;
  final Future<void> Function(int albumId, int assetId) onRemoveFromAlbum;
  final Future<void> Function(int albumId, int assetId)? onAddToPrivateAlbum;
  final Future<void> Function(int albumId, int assetId)?
  onRemoveFromPrivateAlbum;
  final ValueChanged<String>? onSelectSceneLabel;
  final void Function(int personId, String personName)? onSelectPerson;

  /// Embedded in the photo viewer's information sheet/side panel. Do not
  /// render the photo twice or place a dialog inside another modal route.
  final bool metadataOnly;

  @override
  State<PhotoDetailDialog> createState() => _PhotoDetailDialogState();
}

class _PhotoDetailDialogState extends State<PhotoDetailDialog> {
  late PhotoAsset _asset;
  int? _selectedAlbum;
  int? _selectedPrivateAlbum;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _asset = widget.asset;
  }

  Future<void> _toggleFavorite() async {
    HapticFeedback.lightImpact();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final updated = await widget.onToggleFavorite(_asset);
      if (mounted) setState(() => _asset = updated);
    } catch (error) {
      if (mounted) setState(() => _error = mediaErrorLabel(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _togglePersonalFavorite() async {
    final callback = widget.onTogglePersonalFavorite;
    if (callback == null) return;
    HapticFeedback.lightImpact();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final updated = await callback(_asset);
      if (mounted) setState(() => _asset = updated);
    } catch (error) {
      if (mounted) setState(() => _error = mediaErrorLabel(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addToAlbum() async {
    final albumId = _selectedAlbum;
    if (albumId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onAddToAlbum(albumId, _asset.id);
      if (mounted) setState(() => _error = null);
    } catch (error) {
      if (mounted) setState(() => _error = mediaErrorLabel(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeFromAlbum() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onRemoveFromAlbum(widget.currentAlbumId, _asset.id);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = mediaErrorLabel(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addToPrivateAlbum() async {
    final albumId = _selectedPrivateAlbum;
    final callback = widget.onAddToPrivateAlbum;
    if (albumId == null || callback == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await callback(albumId, _asset.id);
      if (mounted) setState(() => _error = null);
    } catch (error) {
      if (mounted) setState(() => _error = mediaErrorLabel(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeFromPrivateAlbum() async {
    final callback = widget.onRemoveFromPrivateAlbum;
    if (callback == null || widget.currentPrivateAlbumId < 1) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await callback(widget.currentPrivateAlbumId, _asset.id);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = mediaErrorLabel(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _detailsDate {
    if (_asset.capturedAt.isNotEmpty) {
      final parsed = DateTime.tryParse(_asset.capturedAt);
      if (parsed != null) return parsed.toLocal().toString().split('.').first;
    }
    return formatMediaDate(_asset.takenAt);
  }

  void _openFullScreenPhoto() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoGalleryViewer(
          api: widget.api,
          assets: [_asset],
          initialIndex: 0,
          fileBrowserMode: true,
          canEditSharedFavorite: (_) => false,
          onSharedFavorite: (asset) async => asset,
          onPersonalFavorite: (asset) async => asset,
          onDetails: (_) async {},
          onLoadMore: () async => const [],
        ),
      ),
    );
  }

  Widget _mediaPreview(BuildContext context) {
    if (_asset.isVideo) {
      return PhotoMediaVideo(
        key: ValueKey('detail-video-${_asset.id}'),
        api: widget.api,
        asset: _asset,
        active: true,
      );
    }
    return AspectRatio(
      aspectRatio: _asset.width > 0 && _asset.height > 0
          ? (_asset.width / _asset.height).clamp(.5, 2.5).toDouble()
          : 1.4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: PhotoMediaImage(
          key: ValueKey('detail-image-${_asset.id}'),
          api: widget.api,
          asset: _asset,
          onTap: _openFullScreenPhoto,
          onZoomChanged: (_) {},
        ),
      ),
    );
  }

  Widget _metadata(BuildContext context) {
    final values = <(IconData, String, String)>[
      (Icons.event_outlined, '拍摄时间', _detailsDate),
      (Icons.storage_outlined, '文件大小', formatMediaSize(_asset.size)),
      if (_asset.width > 0 && _asset.height > 0)
        (
          Icons.aspect_ratio_outlined,
          '画面尺寸',
          '${_asset.width} × ${_asset.height}',
        ),
      if (_asset.isVideo)
        (
          Icons.schedule_outlined,
          '时长',
          formatMediaSeconds(_asset.durationSeconds),
        ),
      if (_asset.container.isNotEmpty || _asset.videoCodec.isNotEmpty)
        (
          Icons.movie_outlined,
          '格式',
          [
            _asset.container,
            _asset.videoCodec,
            _asset.audioCodec,
          ].where((value) => value.isNotEmpty).join(' · '),
        ),
      if (_asset.cameraMake.isNotEmpty || _asset.cameraModel.isNotEmpty)
        (
          Icons.photo_camera_outlined,
          '相机',
          [
            _asset.cameraMake,
            _asset.cameraModel,
          ].where((value) => value.isNotEmpty).join(' '),
        ),
      if (_asset.lensModel.isNotEmpty)
        (Icons.camera_outlined, '镜头', _asset.lensModel),
      if (_asset.iso > 0 ||
          _asset.fNumber > 0 ||
          _asset.exposureSeconds > 0 ||
          _asset.focalLength > 0)
        (
          Icons.tune_outlined,
          '拍摄参数',
          [
            if (_asset.iso > 0) 'ISO ${_asset.iso}',
            if (_asset.fNumber > 0)
              'f/${_asset.fNumber < 10 ? _asset.fNumber.toStringAsFixed(1) : _asset.fNumber.round().toString()}',
            if (_asset.exposureSeconds > 0)
              _asset.exposureSeconds >= 1
                  ? '${_asset.exposureSeconds.toStringAsFixed(1)}s'
                  : '1/${(1 / _asset.exposureSeconds).round()}s',
            if (_asset.focalLength > 0) '${_asset.focalLength.round()}mm',
          ].join(' · '),
        ),
      if (_asset.latitude != null && _asset.longitude != null)
        (
          Icons.place_outlined,
          '位置',
          '${_asset.latitude!.abs().toStringAsFixed(5)}°'
              '${_asset.latitude! >= 0 ? 'N' : 'S'}，'
              '${_asset.longitude!.abs().toStringAsFixed(5)}°'
              '${_asset.longitude! >= 0 ? 'E' : 'W'}',
        ),
    ];
    return Wrap(
      spacing: 14,
      runSpacing: 12,
      children: [
        for (final value in values)
          SizedBox(
            width: 220,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  value.$1,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        value.$2,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        value.$3,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.metadataOnly) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '照片信息',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text(
                        _asset.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '关闭照片信息',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
              children: [_buildMetadataPanel(context, isWide: true)],
            ),
          ),
        ],
      );
    }
    final width = MediaQuery.sizeOf(context).width;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.all(width < 600 ? 12 : 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            constraints: BoxConstraints(
              maxWidth: 920,
              maxHeight: MediaQuery.sizeOf(context).height * .92,
            ),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface
                  .withValues(alpha: isDark ? 0.88 : 0.94),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.16)
                    : Theme.of(context).colorScheme.outlineVariant
                          .withValues(alpha: 0.45),
                width: 0.85,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.15),
                  blurRadius: 36,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 14, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _asset.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.3,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _asset.isVideo ? '视频详情' : '照片详情',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      if (widget.canToggleFavorite)
                        IconButton.filledTonal(
                          tooltip: _asset.favorite ? '取消收藏' : '加入共享收藏',
                          onPressed: _busy ? null : _toggleFavorite,
                          icon: Icon(
                            _asset.favorite
                                ? Icons.favorite
                                : Icons.favorite_border,
                          ),
                        )
                      else
                        const Tooltip(
                          message: '当前账号对此媒体只有查看权限',
                          child: Icon(Icons.lock_outline),
                        ),
                      if (widget.onTogglePersonalFavorite != null)
                        IconButton.filledTonal(
                          tooltip: _asset.personalFavorite
                              ? '从我的收藏移除'
                              : '加入我的收藏',
                          onPressed: _busy ? null : _togglePersonalFavorite,
                          icon: Icon(
                            _asset.personalFavorite
                                ? Icons.star
                                : Icons.star_border,
                          ),
                        ),
                      const SizedBox(width: 6),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final isWide = constraints.maxWidth >= 640;
                      final preview = Container(
                        constraints: BoxConstraints(
                          maxHeight: isWide
                              ? double.infinity
                              : (width < 600 ? 340 : 520),
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: _mediaPreview(context),
                      );

                      if (isWide) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(flex: 3, child: preview),
                              const SizedBox(width: 20),
                              SizedBox(
                                width: 320,
                                child: SingleChildScrollView(
                                  child: _buildMetadataPanel(
                                    context,
                                    isWide: true,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }

                      return SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(height: 6),
                            preview,
                            const SizedBox(height: 18),
                            _buildMetadataPanel(context, isWide: false),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMetadataPanel(BuildContext context, {required bool isWide}) {
    final width = MediaQuery.sizeOf(context).width;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_error != null && !_asset.isVideo)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Text('媒体信息', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        _metadata(context),
        if (!_asset.isVideo)
          PhotoLiveTextCard(
            api: widget.api,
            assetId: _asset.id,
            onSelectSceneLabel: widget.onSelectSceneLabel,
            onSelectPerson: widget.onSelectPerson,
          ),
        if (!widget.metadataOnly &&
            _asset.latitude != null &&
            _asset.longitude != null) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () {
                final lat = _asset.latitude!;
                final lon = _asset.longitude!;
                Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => PhotoMapPage(
                      api: widget.api,
                      initialZoom: 13,
                      initialCenter: LatLng(lat, lon),
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.map_outlined, size: 18),
              label: const Text('在足迹地图中查看'),
            ),
          ),
        ],
        if (widget.isAdmin && widget.albums.isNotEmpty) ...[
          const SizedBox(height: 18),
          const Divider(height: 1),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: isWide
                    ? double.infinity
                    : (width < 540 ? double.infinity : 260),
                child: DropdownButtonFormField<int>(
                  initialValue: _selectedAlbum,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '加入相册',
                    border: OutlineInputBorder(),
                  ),
                  hint: const Text('选择相册'),
                  items: widget.albums
                      .map(
                        (album) => DropdownMenuItem(
                          value: album.id,
                          child: Text(
                            album.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _selectedAlbum = value),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _busy || _selectedAlbum == null ? null : _addToAlbum,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_to_photos_outlined),
                label: const Text('加入相册'),
              ),
              if (widget.currentAlbumId > 0)
                OutlinedButton.icon(
                  onPressed: _busy ? null : _removeFromAlbum,
                  icon: const Icon(Icons.remove_circle_outline),
                  label: const Text('移出此相册'),
                ),
            ],
          ),
        ],
        if (widget.privateAlbums.isNotEmpty &&
            widget.onAddToPrivateAlbum != null) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: isWide
                    ? double.infinity
                    : (width < 540 ? double.infinity : 260),
                child: DropdownButtonFormField<int>(
                  initialValue: _selectedPrivateAlbum,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '加入我的私人相册',
                    border: OutlineInputBorder(),
                  ),
                  hint: const Text('选择私人相册'),
                  items: widget.privateAlbums
                      .map(
                        (album) => DropdownMenuItem(
                          value: album.id,
                          child: Text(
                            album.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: _busy
                      ? null
                      : (value) =>
                            setState(() => _selectedPrivateAlbum = value),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _busy || _selectedPrivateAlbum == null
                    ? null
                    : _addToPrivateAlbum,
                icon: const Icon(Icons.folder_special_outlined),
                label: const Text('加入私人相册'),
              ),
              if (widget.currentPrivateAlbumId > 0)
                OutlinedButton.icon(
                  onPressed: _busy ? null : _removeFromPrivateAlbum,
                  icon: const Icon(Icons.remove_circle_outline),
                  label: const Text('移出此私人相册'),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '私人相册仅当前账号可见，不会影响共享收藏或原始文件。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (_error != null && _asset.isVideo)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }
}
