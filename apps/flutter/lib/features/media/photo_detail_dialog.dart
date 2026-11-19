import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import 'media_models.dart';
import 'media_ui.dart';
import 'photo_exif_panel.dart';
import 'photo_gallery_viewer.dart';
import 'photo_live_text_card.dart';
import 'photo_map_page.dart';

class PhotoDetailDialog extends StatefulWidget {
  const PhotoDetailDialog({
    required this.api,
    required this.asset,
    required this.albums,
    this.privateAlbums = const [],
    required this.isAdmin,
    required this.currentAlbumId,
    this.currentPrivateAlbumId = 0,
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

  void _openFullScreenPhoto() {
    Navigator.of(context).push(
      buildIslePageRoute<void>(
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
        borderRadius: IsleRadius.brMd,
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    if (widget.metadataOnly) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 10, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '照片信息',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _asset.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '关闭照片信息',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: IsleGlass.rimBorderColor(isDark)),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
              children: [_buildMetadataPanel(context, isWide: true)],
            ),
          ),
        ],
      );
    }
    final width = MediaQuery.sizeOf(context).width;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.all(width < 600 ? 12 : 24),
      child: ClipRRect(
        borderRadius: IsleRadius.brCard,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            constraints: BoxConstraints(
              maxWidth: 920,
              maxHeight: MediaQuery.sizeOf(context).height * .92,
            ),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(
                alpha: isDark ? 0.90 : 0.96,
              ),
              borderRadius: IsleRadius.brCard,
              border: Border.all(
                color: IsleGlass.rimBorderColor(isDark),
                width: 1.0,
              ),
              boxShadow: IsleShadows.floating(isDark),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 12, 10),
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
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _asset.isVideo ? '视频详情' : '照片详情',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (widget.canToggleFavorite)
                        IconButton.filledTonal(
                          visualDensity: VisualDensity.compact,
                          tooltip: _asset.favorite ? '取消收藏' : '加入共享收藏',
                          onPressed: _busy ? null : _toggleFavorite,
                          icon: Icon(
                            _asset.favorite
                                ? Icons.favorite
                                : Icons.favorite_border,
                            size: 18,
                          ),
                        )
                      else
                        const Tooltip(
                          message: '当前账号对此媒体只有查看权限',
                          child: Icon(Icons.lock_outline, size: 18),
                        ),
                      if (widget.onTogglePersonalFavorite != null) ...[
                        const SizedBox(width: 4),
                        IconButton.filledTonal(
                          visualDensity: VisualDensity.compact,
                          tooltip: _asset.personalFavorite
                              ? '从我的收藏移除'
                              : '加入我的收藏',
                          onPressed: _busy ? null : _togglePersonalFavorite,
                          icon: Icon(
                            _asset.personalFavorite
                                ? Icons.star
                                : Icons.star_border,
                            size: 18,
                          ),
                        ),
                      ],
                      const SizedBox(width: 4),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '关闭',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close, size: 20),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: IsleGlass.rimBorderColor(isDark)),
                Flexible(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final isWide = constraints.maxWidth >= 640;
                      final preview = Container(
                        constraints: BoxConstraints(
                          maxHeight: isWide
                              ? double.infinity
                              : (width < 600 ? 340 : 500),
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: IsleRadius.brMd,
                          border: Border.all(
                            color: IsleGlass.rimBorderColor(isDark),
                            width: 1.0,
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: _mediaPreview(context),
                      );

                      if (isWide) {
                        return Padding(
                          padding: const EdgeInsets.all(18),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(flex: 3, child: preview),
                              const SizedBox(width: 18),
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
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            preview,
                            const SizedBox(height: 16),
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
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_error != null && !_asset.isVideo)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        Text(
          '媒体信息',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        PhotoExifPanel(asset: _asset),
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
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              onPressed: () {
                final lat = _asset.latitude!;
                final lon = _asset.longitude!;
                Navigator.of(context).push<void>(
                  buildIslePageRoute<void>(
                    builder: (_) => PhotoMapPage(
                      api: widget.api,
                      initialZoom: 13,
                      initialCenter: LatLng(lat, lon),
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.map_outlined, size: 17),
              label: const Text('在足迹地图中查看'),
            ),
          ),
        ],
        if (widget.isAdmin && widget.albums.isNotEmpty) ...[
          const SizedBox(height: 16),
          Divider(height: 1, color: IsleGlass.rimBorderColor(isDark)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
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
                    isDense: true,
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
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: _busy || _selectedAlbum == null ? null : _addToAlbum,
                icon: _busy
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_to_photos_outlined, size: 17),
                label: const Text('加入相册'),
              ),
              if (widget.currentAlbumId > 0)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _busy ? null : _removeFromAlbum,
                  icon: const Icon(Icons.remove_circle_outline, size: 17),
                  label: const Text('移出此相册'),
                ),
            ],
          ),
        ],
        if (widget.privateAlbums.isNotEmpty &&
            widget.onAddToPrivateAlbum != null) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
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
                    isDense: true,
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
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: _busy || _selectedPrivateAlbum == null
                    ? null
                    : _addToPrivateAlbum,
                icon: const Icon(Icons.folder_special_outlined, size: 17),
                label: const Text('加入私人相册'),
              ),
              if (widget.currentPrivateAlbumId > 0)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _busy ? null : _removeFromPrivateAlbum,
                  icon: const Icon(Icons.remove_circle_outline, size: 17),
                  label: const Text('移出此私人相册'),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '私人相册仅当前账号可见，不会影响共享收藏或原始文件。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (_error != null && _asset.isVideo)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }
}
