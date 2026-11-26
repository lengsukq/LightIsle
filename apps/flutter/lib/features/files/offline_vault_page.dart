import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import '../media/local_video_page.dart';
import '../media/offline_photo_store.dart';
import '../media/offline_photos_page.dart';
import '../media/offline_video_store.dart';
import '../media/offline_videos_page.dart';
import 'file_extras_api.dart';
import 'file_models.dart';
import 'file_preview_support.dart';
import 'file_text_preview_dialog.dart';
import 'offline_file_store.dart';

/// Unified offline vault aggregating offline documents, photos, and videos.
/// All tabs read only local app-private indexes and work with zero network.
class OfflineVaultPage extends StatefulWidget {
  const OfflineVaultPage({
    super.key,
    required this.api,
    required this.accountId,
    this.initialTab = 0,
    this.applicationDirectory,
    this.externalOpener,
  });

  final LightIsleApi api;
  final String accountId;
  final int initialTab;
  final Directory? applicationDirectory;
  final Future<OpenResult> Function(String path)? externalOpener;

  @override
  State<OfflineVaultPage> createState() => _OfflineVaultPageState();
}

class _OfflineVaultPageState extends State<OfflineVaultPage> {
  late int _tab = widget.initialTab.clamp(0, 2);
  bool _loading = true;
  bool _busy = false;
  String? _notice;
  bool _noticeError = false;

  List<OfflineFileEntry> _files = const [];
  List<OfflinePhoto> _photos = const [];
  List<OfflineVideo> _videos = const [];

  OfflineFileStore? get _fileStore => widget.accountId.trim().isEmpty
      ? null
      : OfflineFileStore(
          api: widget.api,
          accountIdentity: widget.accountId,
          applicationDirectory: widget.applicationDirectory,
        );

  OfflinePhotoStore? get _photoStore {
    if (!RegExp(r'^uid:[1-9][0-9]*$').hasMatch(widget.accountId)) return null;
    return OfflinePhotoStore(
      api: widget.api,
      accountId: widget.accountId,
      applicationDirectory: widget.applicationDirectory,
    );
  }

  OfflineVideoStore? get _videoStore => widget.accountId.trim().isEmpty
      ? null
      : OfflineVideoStore(
          api: widget.api,
          accountName: widget.accountId,
          applicationDirectory: widget.applicationDirectory,
        );

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    var files = const <OfflineFileEntry>[];
    var photos = const <OfflinePhoto>[];
    var videos = const <OfflineVideo>[];
    try {
      final fs = _fileStore;
      if (fs != null) files = await fs.list();
    } catch (_) {}
    try {
      final ps = _photoStore;
      if (ps != null) photos = await ps.list();
    } catch (_) {}
    try {
      final vs = _videoStore;
      if (vs != null) videos = await vs.list();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _files = files;
      _photos = photos;
      _videos = videos;
      _loading = false;
    });
  }

  void _setNotice(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _notice = message;
      _noticeError = error;
    });
  }

  Future<void> _openOfflineFile(OfflineFileEntry entry) async {
    final store = _fileStore;
    if (store == null || _busy) return;
    setState(() => _busy = true);
    try {
      final local = await store.fileFor(entry);
      if (!mounted) return;
      final kind = classifyFilePreview(entry.name);
      if (kind == FilePreviewKind.text || isMarkdownFile(entry.name)) {
        final raw = await local.readAsBytes();
        final decoded = decodePreviewText(raw);
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (_) => FileTextPreviewDialog(
            item: FileEntry(
              name: entry.name,
              path: entry.path,
              type: 'file',
              size: entry.sizeBytes,
              modified: entry.savedAt,
              canWrite: false,
            ),
            badge: const Icon(Icons.offline_pin_rounded, size: 22),
            text: decoded,
            onOpenExternal: () => unawaited(_openWithSystemApp(local.path)),
            onDownload: () => unawaited(_openWithSystemApp(local.path)),
          ),
        );
      } else {
        await _openWithSystemApp(local.path);
      }
    } catch (err) {
      _setNotice('打开离线文件失败：${userFacingError(err)}', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openWithSystemApp(String localPath) async {
    final opener = widget.externalOpener ?? OpenFilex.open;
    final res = await opener(localPath);
    if (res.type != ResultType.done) {
      _setNotice(
        res.type == ResultType.noAppToOpen
            ? '当前设备没有可打开此格式的应用。'
            : '系统未能打开此文件：${res.message}',
        error: true,
      );
    }
  }

  Future<void> _removeOfflineFile(OfflineFileEntry entry) async {
    final store = _fileStore;
    if (store == null || _busy) return;
    final ok = await confirmAction(
      context,
      '移除离线副本？',
      '仅删除本机离线副本“${entry.name}”，NAS 上的原文件不会被修改或删除。',
      action: '移除副本',
      isDestructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await store.remove(entry);
      await _refresh();
      _setNotice('已移除离线副本“${entry.name}”。');
    } catch (err) {
      _setNotice('移除失败：${userFacingError(err)}', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearOfflineFiles() async {
    final store = _fileStore;
    if (store == null || _busy || _files.isEmpty) return;
    final ok = await confirmAction(
      context,
      '清空本机离线文档？',
      '将删除当前账号在此存储位置保存的全部 ${_files.length} 个离线文档副本。NAS 原件不受影响，离线照片与影片不受影响。',
      action: '确认清空',
      isDestructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await store.clear();
      await _refresh();
      _setNotice('已清空本机离线文档。');
    } catch (err) {
      _setNotice('清空失败：${userFacingError(err)}', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openOfflinePhoto(OfflinePhoto photo) async {
    final store = _photoStore;
    if (store == null || _busy) return;
    setState(() => _busy = true);
    try {
      final file = await store.fileFor(photo);
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        buildIslePageRoute<void>(
          builder: (_) => Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              title: Text(photo.title),
            ),
            body: Center(
              child: InteractiveViewer(
                minScale: 1.0,
                maxScale: 5.0,
                child: Image.file(file, fit: BoxFit.contain),
              ),
            ),
          ),
        ),
      );
    } catch (err) {
      _setNotice('打开离线照片失败：${userFacingError(err)}', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeOfflinePhoto(OfflinePhoto photo) async {
    final store = _photoStore;
    if (store == null || _busy) return;
    final ok = await confirmAction(
      context,
      '移除离线照片？',
      '仅删除设备中的“${photo.title}”，NAS 原片保留不变。',
      action: '移除副本',
      isDestructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await store.remove(photo);
      await _refresh();
      _setNotice('已移除离线照片“${photo.title}”。');
    } catch (err) {
      _setNotice('移除失败：${userFacingError(err)}', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openOfflineVideo(OfflineVideo video) async {
    final store = _videoStore;
    if (store == null || _busy) return;
    setState(() => _busy = true);
    try {
      final file = await store.fileFor(video);
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        buildIslePageRoute<void>(
          builder: (_) => LocalVideoPage(path: file.path),
        ),
      );
    } catch (err) {
      _setNotice('播放离线影片失败：${userFacingError(err)}', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeOfflineVideo(OfflineVideo video) async {
    final store = _videoStore;
    if (store == null || _busy) return;
    final ok = await confirmAction(
      context,
      '移除离线影片？',
      '仅删除设备中的“${video.title}”，NAS 原文件不会删除。',
      action: '移除副本',
      isDestructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await store.remove(video);
      await _refresh();
      _setNotice('已移除离线影片“${video.title}”。');
    } catch (err) {
      _setNotice('移除失败：${userFacingError(err)}', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    final fileBytes = _files.fold<int>(0, (s, e) => s + e.sizeBytes);
    final photoBytes = _photos.fold<int>(0, (s, e) => s + e.size);
    final videoBytes = _videos.fold<int>(0, (s, e) => s + e.size);
    final totalBytes = fileBytes + photoBytes + videoBytes;

    return Scaffold(
      appBar: IsleAppBar(
        title: const Text('离线文件箱'),
        actions: [
          IconButton(
            tooltip: '刷新离线列表',
            onPressed: _loading || _busy ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: IsleListView(
        maxWidth: IsleLayout.workbenchMaxWidth,
        children: [
          IsleFocalStage(
            icon: Icons.offline_pin_rounded,
            accent: palette['brandBlue'],
            title: '离线文件箱（无网直开）',
            metrics: [
              IsleFocalMetric(
                label: '离线文档',
                value: '${_files.length}',
                accent: palette['brandAmber'],
              ),
              IsleFocalMetric(
                label: '离线照片',
                value: '${_photos.length}',
                accent: palette['brandRose'],
              ),
              IsleFocalMetric(
                label: '离线视频',
                value: '${_videos.length}',
                accent: palette['brandTerracotta'],
              ),
              IsleFocalMetric(
                label: '总占用',
                value: formatBytes(totalBytes),
                accent: palette['brandBlue'],
              ),
            ],
            actions: [
              if (_tab == 0 && _files.isNotEmpty)
                OutlinedButton.icon(
                  key: const ValueKey('clearOfflineFilesBtn'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _busy ? null : _clearOfflineFiles,
                  icon: const Icon(Icons.delete_outline_rounded, size: 16),
                  label: const Text('清空离线文档'),
                ),
              if (_tab == 1 && _photoStore != null)
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () async {
                    await Navigator.of(context).push<void>(
                      buildIslePageRoute<void>(
                        builder: (_) => OfflinePhotosPage(
                          api: widget.api,
                          accountId: widget.accountId,
                        ),
                      ),
                    );
                    await _refresh();
                  },
                  child: const Text('打开完整照片库'),
                ),
              if (_tab == 2 && _videoStore != null)
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () async {
                    await Navigator.of(context).push<void>(
                      buildIslePageRoute<void>(
                        builder: (_) => OfflineVideosPage(
                          api: widget.api,
                          accountName: widget.accountId,
                        ),
                      ),
                    );
                    await _refresh();
                  },
                  child: const Text('打开完整影片库'),
                ),
            ],
          ),
          const SizedBox(height: 10),
          SegmentedButton<int>(
            key: const ValueKey('offlineVaultTabs'),
            segments: [
              ButtonSegment<int>(
                value: 0,
                icon: const Icon(Icons.description_outlined, size: 16),
                label: Text('文档 (${_files.length})'),
              ),
              ButtonSegment<int>(
                value: 1,
                icon: const Icon(Icons.photo_outlined, size: 16),
                label: Text('照片 (${_photos.length})'),
              ),
              ButtonSegment<int>(
                value: 2,
                icon: const Icon(Icons.movie_outlined, size: 16),
                label: Text('视频 (${_videos.length})'),
              ),
            ],
            selected: <int>{_tab},
            onSelectionChanged: (s) => setState(() => _tab = s.first),
          ),
          const SizedBox(height: 10),
          if (_notice != null) ...[
            Notice(_notice!, error: _noticeError),
            const SizedBox(height: 8),
          ],
          if (_loading)
            const IsleLoadingState(compact: true, label: '正在读取本机离线索引…')
          else if (_tab == 0)
            _buildFilesList(palette)
          else if (_tab == 1)
            _buildPhotosList(palette)
          else
            _buildVideosList(palette),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildFilesList(IslePalette palette) {
    if (_files.isEmpty) {
      return const IsleEmptyStateCard(
        '离线文件箱里还没有文档。在文件列表中选择「保存到离线文件箱」即可无网直开。',
        icon: Icons.folder_off_outlined,
      );
    }
    return IsleSurface(
      margin: EdgeInsets.zero,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < _files.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 56),
            ListTile(
              key: ValueKey('offline-file-${_files[i].path}'),
              dense: true,
              leading: IsleSquircleBadge(
                icon: Icons.description_rounded,
                color: palette['brandAmber'],
                size: 34,
                iconSize: 17,
              ),
              title: Text(
                _files[i].name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                '${formatBytes(_files[i].sizeBytes)} · ${_files[i].path}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5),
              ),
              onTap: _busy ? null : () => _openOfflineFile(_files[i]),
              trailing: IconButton(
                tooltip: '移除离线副本',
                onPressed: _busy ? null : () => _removeOfflineFile(_files[i]),
                icon: const Icon(Icons.delete_outline_rounded, size: 19),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPhotosList(IslePalette palette) {
    if (_photos.isEmpty) {
      return const IsleEmptyStateCard(
        '当前存储位置还没有离线照片。在相册中保存原片后可在此无网查看。',
        icon: Icons.photo_library_outlined,
      );
    }
    return IsleSurface(
      margin: EdgeInsets.zero,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < _photos.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 56),
            ListTile(
              dense: true,
              leading: IsleSquircleBadge(
                icon: Icons.photo_rounded,
                color: palette['brandRose'],
                size: 34,
                iconSize: 17,
              ),
              title: Text(
                _photos[i].title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                '${formatBytes(_photos[i].size)} · ${_photos[i].remotePath}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5),
              ),
              onTap: _busy ? null : () => _openOfflinePhoto(_photos[i]),
              trailing: IconButton(
                tooltip: '移除离线照片',
                onPressed: _busy ? null : () => _removeOfflinePhoto(_photos[i]),
                icon: const Icon(Icons.delete_outline_rounded, size: 19),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildVideosList(IslePalette palette) {
    if (_videos.isEmpty) {
      return const IsleEmptyStateCard(
        '当前存储位置还没有离线视频。在影院中缓存影片后可在此无网播放。',
        icon: Icons.video_library_outlined,
      );
    }
    return IsleSurface(
      margin: EdgeInsets.zero,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < _videos.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 56),
            ListTile(
              dense: true,
              leading: IsleSquircleBadge(
                icon: Icons.play_circle_outline_rounded,
                color: palette['brandTerracotta'],
                size: 34,
                iconSize: 17,
              ),
              title: Text(
                _videos[i].title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                '${formatBytes(_videos[i].size)} · ${_videos[i].remotePath}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5),
              ),
              onTap: _busy ? null : () => _openOfflineVideo(_videos[i]),
              trailing: IconButton(
                tooltip: '移除离线影片',
                onPressed: _busy ? null : () => _removeOfflineVideo(_videos[i]),
                icon: const Icon(Icons.delete_outline_rounded, size: 19),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
