import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'mobile_photo_backup_controller.dart';
import 'mobile_photo_backup_state_models.dart';
import 'photo_backup_prefs_schema.dart';

Future<void> showMobilePhotoAlbumPickerSheet(
  BuildContext context,
  MobilePhotoBackupController controller,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetContext) => _MobilePhotoAlbumPickerSheet(
      controller: controller,
    ),
  );
}

class _MobilePhotoAlbumPickerSheet extends StatefulWidget {
  const _MobilePhotoAlbumPickerSheet({required this.controller});

  final MobilePhotoBackupController controller;

  @override
  State<_MobilePhotoAlbumPickerSheet> createState() =>
      _MobilePhotoAlbumPickerSheetState();
}

class _MobilePhotoAlbumPickerSheetState
    extends State<_MobilePhotoAlbumPickerSheet> {
  late String _mode;
  late Set<String> _selectedIds;
  List<DevicePhotoAlbum> _albums = const <DevicePhotoAlbum>[];
  bool _loading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    final currentScope = widget.controller.options.albumScope;
    _mode = currentScope == PhotoBackupPrefsSchema.albumScopeExcluded
        ? PhotoBackupPrefsSchema.albumScopeExcluded
        : PhotoBackupPrefsSchema.albumScopeSelected;
    _selectedIds = widget.controller.options.selectedAlbumIds.toSet();
    unawaited(_loadAlbums());
  }

  Future<void> _loadAlbums() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      final albums = await widget.controller.loadDeviceAlbums();
      if (!mounted) return;
      setState(() {
        _albums = albums;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = userFacingError(error);
        _loading = false;
      });
    }
  }

  void _selectCameraOnly() {
    final cameraIds = _albums
        .where((album) => album.isCamera)
        .map((album) => album.id)
        .toSet();
    setState(() {
      _mode = PhotoBackupPrefsSchema.albumScopeSelected;
      _selectedIds = cameraIds;
    });
  }

  void _selectAll() {
    setState(() {
      _selectedIds = _albums.map((album) => album.id).toSet();
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedIds = <String>{};
    });
  }

  void _toggleAlbum(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _apply() {
    widget.controller.updateAlbumSelection(
      albumScope: _mode,
      selectedAlbumIds: _selectedIds.toList(growable: false),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final rose = palette['brandRose'];
    final isSelectedMode = _mode == PhotoBackupPrefsSchema.albumScopeSelected;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.78,
      minChildSize: 0.5,
      maxChildSize: 0.94,
      builder: (context, scrollController) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '选择备份相簿与文件夹',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isSelectedMode
                      ? '仅备份下方勾选的相簿或目录，适合精准备份相机、旅行或家庭相册。'
                      : '备份手机全部媒体，但自动跳过下方勾选的相簿（如截屏、微信缓存等）。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  segments: const [
                    ButtonSegment<String>(
                      value: PhotoBackupPrefsSchema.albumScopeSelected,
                      icon: Icon(Icons.check_box_outlined, size: 16),
                      label: Text('仅备份已勾选'),
                    ),
                    ButtonSegment<String>(
                      value: PhotoBackupPrefsSchema.albumScopeExcluded,
                      icon: Icon(Icons.block_outlined, size: 16),
                      label: Text('备份全部但排除勾选'),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (selection) =>
                      setState(() => _mode = selection.first),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    ActionChip(
                      avatar: const Icon(Icons.camera_alt_outlined, size: 15),
                      label: const Text('仅选相机'),
                      onPressed: _albums.isEmpty ? null : _selectCameraOnly,
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.select_all_rounded, size: 15),
                      label: const Text('全选'),
                      onPressed: _albums.isEmpty ? null : _selectAll,
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.deselect_rounded, size: 15),
                      label: const Text('清空'),
                      onPressed: _selectedIds.isEmpty ? null : _clearSelection,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildBody(scrollController, rose, colors)),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    isSelectedMode
                        ? '已勾选 ${_selectedIds.length} 个相簿'
                        : '已排除 ${_selectedIds.length} 个相簿',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: isSelectedMode && _selectedIds.isEmpty
                      ? null
                      : _apply,
                  child: const Text('应用相簿规则'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(
    ScrollController scrollController,
    Color accent,
    ColorScheme colors,
  ) {
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(strokeWidth: 2.5),
              SizedBox(height: 12),
              Text('正在读取手机相簿与目录…'),
            ],
          ),
        ),
      );
    }
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_off_outlined, size: 36, color: colors.error),
              const SizedBox(height: 10),
              Text(_errorMessage!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _loadAlbums,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('重新加载'),
              ),
            ],
          ),
        ),
      );
    }
    if (_albums.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('未发现可备份的手机相簿或照片文件夹。'),
        ),
      );
    }
    return ListView.separated(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: _albums.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 68),
      itemBuilder: (context, index) {
        final album = _albums[index];
        final checked = _selectedIds.contains(album.id);
        final details = <String>[
          '${album.count} 项',
          if (album.totalBytes > 0) formatBytes(album.totalBytes),
          if (album.relativePath.isNotEmpty)
            album.relativePath
          else if (album.kind == 'smart')
            '智能相簿'
          else if (album.kind == 'user')
            '自建相簿',
        ];
        return CheckboxListTile(
          value: checked,
          onChanged: (_) => _toggleAlbum(album.id),
          secondary: IsleSquircleBadge(
            icon: album.isCamera
                ? Icons.camera_alt_outlined
                : album.kind == 'smart'
                ? Icons.auto_awesome_outlined
                : Icons.photo_album_outlined,
            color: album.isCamera ? accent : colors.primary,
            size: 38,
            iconSize: 18,
          ),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  album.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (album.isCamera) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1.5,
                  ),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '相机',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: accent,
                    ),
                  ),
                ),
              ],
            ],
          ),
          subtitle: Text(
            details.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
        );
      },
    );
  }
}
