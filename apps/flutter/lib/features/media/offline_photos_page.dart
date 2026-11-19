import 'package:flutter/material.dart';

import '../../core/isle_gallery_layout.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import '../files/files_page.dart';
import 'offline_photo_store.dart';
import 'offline_videos_page.dart';
import 'photo_media_view.dart' show computeViewerDecodeCap;
import 'photo_zoom_surface.dart';

class OfflineMediaSegmentBar extends StatelessWidget {
  const OfflineMediaSegmentBar({
    super.key,
    required this.isPhotos,
    required this.onSwitchTab,
  });

  final bool isPhotos;
  final VoidCallback? onSwitchTab;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette(isDark);

    Widget pill({
      required IconData icon,
      required String label,
      required bool active,
      required VoidCallback? onTap,
    }) {
      return Expanded(
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: active ? null : onTap,
            child: AnimatedContainer(
              duration: IsleMotion.fast,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: active
                    ? (isDark
                          ? colors.primary.withValues(alpha: 0.24)
                          : palette['cardTop'])
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: active
                    ? Border.all(
                        color: isDark
                            ? colors.primary.withValues(alpha: 0.35)
                            : IsleGlass.rimBorderColor(false),
                        width: 0.9,
                      )
                    : null,
                boxShadow: active && !isDark ? IsleShadows.subtle(false) : null,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 15,
                    color: active ? colors.primary : colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                        color: active
                            ? (isDark ? colors.primary : colors.onSurface)
                            : colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(3.5),
      decoration: IsleDecorations.recessedWell(context, radius: 13),
      child: Row(
        children: [
          pill(
            icon: Icons.photo_library_outlined,
            label: '离线照片',
            active: isPhotos,
            onTap: isPhotos ? null : onSwitchTab,
          ),
          const SizedBox(width: 4),
          pill(
            icon: Icons.offline_pin_outlined,
            label: '离线影片',
            active: !isPhotos,
            onTap: !isPhotos ? null : onSwitchTab,
          ),
        ],
      ),
    );
  }
}

class OfflinePhotosPage extends StatefulWidget {
  const OfflinePhotosPage({
    super.key,
    required this.api,
    required this.accountId,
  });
  final LightIsleApi api;
  final String accountId;

  @override
  State<OfflinePhotosPage> createState() => _OfflinePhotosPageState();
}

class _OfflinePhotosPageState extends State<OfflinePhotosPage> {
  late final OfflinePhotoStore _store = OfflinePhotoStore(
    api: widget.api,
    accountId: widget.accountId,
  );
  List<OfflinePhoto> _items = const [];
  bool _loading = true, _busy = false;
  String? _message;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _switchToVideos() {
    if (widget.accountId.isEmpty) return;
    Navigator.of(context).pushReplacement(
      buildIslePageRoute<void>(
        builder: (_) => OfflineVideosPage(
          api: widget.api,
          accountName: widget.accountId,
        ),
      ),
    );
  }

  Future<void> _refresh() async {
    final epoch = ++_epoch;
    if (mounted) {
      setState(() {
        _loading = true;
        _message = null;
      });
    }
    try {
      final list = await _store.list();
      if (mounted && epoch == _epoch) {
        setState(() => _items = list.reversed.toList());
      }
    } catch (error) {
      if (mounted && epoch == _epoch) {
        setState(() => _message = userFacingError(error));
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _loading = false);
    }
  }

  Future<void> _view(OfflinePhoto photo) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final original = await _store.fileFor(photo);
      if (!mounted) return;
      final decodeCap = computeViewerDecodeCap(context);
      String? action;
      try {
        action = await showDialog<String>(
          context: context,
          builder: (context) => Dialog.fullscreen(
            child: Scaffold(
              appBar: IsleAppBar(title: Text(photo.title)),
              body: Column(
                children: [
                  Expanded(
                    child: photo.previewable
                        ? PhotoZoomSurface(
                            onSwipeDown: () => Navigator.of(context).pop(),
                            child: Image.file(
                              original,
                              cacheWidth: decodeCap,
                              filterQuality: FilterQuality.high,
                              fit: BoxFit.contain,
                              errorBuilder: (context, error, stack) =>
                                  const Center(
                                    child: Text('系统无法解码此原图，请选择“导出原件”使用专业软件打开。'),
                                  ),
                            ),
                          )
                        : const Center(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Text(
                                '这是已完整保存的 HEIC/RAW 等相机原件。'
                                '当前 Flutter 图像解码器不支持直接显示这种格式，'
                                '请通过系统导出保存原始文件；不会修改或转码。',
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                  ),
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: FilledButton.icon(
                        onPressed: () => Navigator.pop(context, 'export'),
                        icon: const Icon(Icons.save_alt),
                        label: const Text('导出原件'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      } finally {
        if (photo.previewable) {
          await FileImage(original).evict();
          await ResizeImage.resizeIfNeeded(
            decodeCap,
            null,
            FileImage(original),
          ).evict();
        }
      }
      if (action == 'export') {
        final message = await exportOfflineMediaFile(original, photo.title);
        if (mounted) setState(() => _message = message);
      }
    } catch (error) {
      if (mounted) setState(() => _message = userFacingError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export(OfflinePhoto photo) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final file = await _store.fileFor(photo);
      final result = await exportOfflineMediaFile(file, photo.title);
      if (mounted) setState(() => _message = result);
    } catch (error) {
      if (mounted) setState(() => _message = userFacingError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(OfflinePhoto photo) async {
    if (_busy) return;
    final choice = await confirmAction(
      context,
      '删除离线照片',
      '仅删除当前设备上“${photo.title}”的离线副本，NAS 原件不会受到影响。',
      action: '删除本机副本',
      isDestructive: true,
    );
    if (!choice || !mounted) return;
    setState(() => _busy = true);
    try {
      await _store.remove(photo);
      if (mounted) {
        setState(() {
          _items = _items.where((p) => p.fileName != photo.fileName).toList();
        });
      }
    } catch (error) {
      if (mounted) setState(() => _message = userFacingError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _buildPhotoTile(OfflinePhoto photo, Color rose) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
      leading: IsleSquircleBadge(
        icon: photo.previewable
            ? Icons.photo_outlined
            : Icons.insert_drive_file_outlined,
        color: rose,
        size: 32,
        iconSize: 17,
      ),
      title: Text(
        photo.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '${(photo.size / (1 << 20)).toStringAsFixed(1)} MiB',
        style: const TextStyle(fontSize: 12),
      ),
      onTap: _busy ? null : () => _view(photo),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '导出离线原件',
            visualDensity: VisualDensity.compact,
            onPressed: _busy ? null : () => _export(photo),
            icon: const Icon(Icons.save_alt, size: 19),
          ),
          IconButton(
            tooltip: '删除本机副本',
            visualDensity: VisualDensity.compact,
            onPressed: _busy ? null : () => _remove(photo),
            icon: const Icon(Icons.delete_outline, size: 19),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    final rose = palette['brandRose'];
    final totalMb = _items.fold<int>(0, (s, p) => s + p.size) / (1 << 20);

    return Scaffold(
      appBar: IsleAppBar(
        title: const Text('本机离线媒体'),
        actions: [
          IconButton(
            tooltip: '刷新本机离线照片',
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
          IsleHelpButton(
            title: '离线照片库说明',
            accentColor: rose,
            body:
                '离线保存会将原始画质照片（含 HEIC / RAW 原件）下载至当前设备沙盒，断网时仍可查看或导出；删除离线副本不会影响 NAS 上的原文件。',
          ),
        ],
      ),
      body: IsleListView(
        maxWidth: IsleLayout.workbenchMaxWidth,
        children: [
          OfflineMediaSegmentBar(
            isPhotos: true,
            onSwitchTab: widget.accountId.isEmpty ? null : _switchToVideos,
          ),
          IsleFocalStage(
            icon: Icons.photo_library_rounded,
            accent: rose,
            title: '本机离线照片库',
            metrics: [
              IsleFocalMetric(
                label: '离线原片',
                value: '${_items.length}',
                accent: rose,
              ),
              IsleFocalMetric(
                label: '占用空间',
                value: '${totalMb.toStringAsFixed(1)} MiB',
                accent: palette['brandAmber'],
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_loading && _items.isEmpty)
            const IsleLoadingState(compact: true, label: '正在读取本机离线照片…')
          else if (_loading || _busy)
            const LinearProgressIndicator(),
          if (_message != null)
            Notice(_message!, error: true, onRetry: _refresh),
          if (!_loading && _items.isEmpty)
            const IsleEmptyStateCard(
              '在图库中打开照片并选择“离线保存”，即可断网查看。',
              icon: Icons.photo_library_outlined,
            ),
          if (_items.isNotEmpty) ...[
            IsleSectionHeader(
              title: '已保存照片（${_items.length}）',
              accentColor: rose,
            ),
            IsleAdaptiveBuilder(
              builder: (context, tier, width) {
                final textScale =
                    MediaQuery.textScalerOf(context).scale(14) / 14;
                if (tier == IsleViewportTier.expanded &&
                    _items.length > 1 &&
                    textScale <= 1.35) {
                  final cardWidth = (width - 12) / 2;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 10,
                    children: [
                      for (final photo in _items)
                        SizedBox(
                          width: cardWidth,
                          child: IsleSurface(
                            margin: EdgeInsets.zero,
                            padding: EdgeInsets.zero,
                            child: _buildPhotoTile(photo, rose),
                          ),
                        ),
                    ],
                  );
                }
                return IsleGroupCard(
                  margin: EdgeInsets.zero,
                  children: [
                    for (final photo in _items) _buildPhotoTile(photo, rose),
                  ],
                );
              },
            ),
          ],
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
