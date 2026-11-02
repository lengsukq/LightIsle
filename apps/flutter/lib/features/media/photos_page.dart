import 'dart:async';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import 'media_models.dart';
import 'photo_gallery_viewer.dart';
import 'photo_detail_dialog.dart';
export 'photo_detail_dialog.dart' show PhotoDetailDialog;
import 'photo_map_page.dart';
import 'media_ui.dart';
import 'offline_photos_page.dart';
import '../files/android_photo_backup_page.dart';
import '../files/files_page.dart';

class PhotosPage extends StatefulWidget {
  const PhotosPage({
    required this.api,
    required this.isAdmin,
    this.accountName = '',
    this.offlineAccountId = '',
    this.backupDirectory = 'PhonePhotos',
    this.canBackup = false,
    this.uploadDirectory = '.',
    super.key,
  });

  final LightIsleApi api;
  final bool isAdmin;
  final String accountName;
  final String offlineAccountId;
  final String backupDirectory;
  final bool canBackup;
  final String uploadDirectory;

  @override
  State<PhotosPage> createState() => _PhotosPageState();
}

class _PhotosPageState extends State<PhotosPage> with WidgetsBindingObserver {
  static const int _pageSize = 48;
  final ScrollController _timelineScroll = ScrollController();

  final List<PhotoAsset> _assets = [];
  List<MediaAlbum> _albums = const [];
  List<MediaAlbum> _privateAlbums = const [];
  int _activeAlbum = 0;
  int _activePrivateAlbum = 0;
  int _nextCursor = 0;
  bool _favoritesOnly = false;
  bool _personalFavoritesOnly = false;
  bool _onThisDay = false;
  bool _showSearch = false;
  bool _selecting = false;
  bool _batchBusy = false;
  final Set<int> _selectedAssets = <int>{};
  String _query = '', _mediaType = '';
  final _searchController = TextEditingController();
  Timer? _searchTimer;
  bool _loading = true;
  bool _loadingMore = false;
  bool _scanning = false;
  bool _wasScanning = false;
  bool _albumBusy = false;
  String? _loadError;
  String? _actionMessage;
  bool _actionIsError = false;
  String? _scanError;
  MediaScanStatus _scanStatus = const MediaScanStatus();
  int _lastDone = 0;
  int _listGeneration = 0;
  int _albumsGeneration = 0;
  int _privateAlbumsGeneration = 0;
  int _statusGeneration = 0;
  Timer? _statusTimer;
  bool _tabEnabled = true;
  bool _appForeground = true;
  bool _pollingActive = false;

  MediaAlbum? get _currentAlbum {
    for (final album in _albums) {
      if (album.id == _activeAlbum) return album;
    }
    return null;
  }

  Future<void> _batchExport() async {
    if (_batchBusy || _selectedAssets.isEmpty) return;
    final items = _assets
        .where((item) => _selectedAssets.contains(item.id))
        .toList();
    final mobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    if (mobile) {
      if (items.length > 20) {
        setState(() {
          _actionMessage = '手机一次最多导出 20 项，请减少选择。';
          _actionIsError = true;
        });
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('批量导出原文件'),
          content: Text(
            '将临时下载 ${items.length} 个原文件到本机，'
            '然后 Android 只选择一次系统保存文件夹，iOS 只显示一次系统分享面板。'
            '总大小不得超过 2 GiB，取消或结束会清理本机临时副本。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('继续导出'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      setState(() => _batchBusy = true);
      try {
        final message = await exportMediaFiles(
          widget.api,
          items: [
            for (final item in items)
              (path: item.path, name: item.name, size: item.size),
          ],
          onProgress: (finished, total, name) {
            if (mounted) {
              setState(() {
                _actionMessage = '正在准备批量导出 $finished/$total 项：$name';
                _actionIsError = false;
              });
            }
          },
        );
        if (mounted) {
          setState(() {
            _actionMessage = message;
            _actionIsError = false;
          });
        }
      } catch (error) {
        if (mounted) {
          setState(() {
            _actionMessage = '批量导出失败：${mediaErrorLabel(error)}';
            _actionIsError = true;
          });
        }
      } finally {
        if (mounted) setState(() => _batchBusy = false);
      }
      return;
    }
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: '选择批量媒体保存位置',
    );
    if (directory == null || directory.isEmpty || !mounted) return;
    setState(() => _batchBusy = true);
    var saved = 0;
    String? error;
    for (final asset in items) {
      try {
        await exportMediaFile(
          widget.api,
          path: asset.path,
          name: asset.name,
          destinationDirectory: directory,
        );
        saved++;
      } catch (failure) {
        error = mediaErrorLabel(failure);
        break;
      }
      if (!mounted) return;
    }
    if (!mounted) return;
    setState(() {
      _batchBusy = false;
      _actionMessage = error == null
          ? '已保存 $saved 项原文件到所选文件夹。'
          : '已保存 $saved 项，剩余文件未处理：$error';
      _actionIsError = error != null;
    });
  }

  Future<void> _batchShare() async {
    if (_batchBusy || _selectedAssets.isEmpty) return;
    final items = _assets
        .where((item) => _selectedAssets.contains(item.id))
        .toList();
    if (items.length > 10) {
      setState(() {
        _actionMessage = '每次最多分享 10 项，请减少选择。';
        _actionIsError = true;
      });
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('分享所选媒体？'),
        content: Text(
          '将为 ${items.length} 个原文件分别创建有效期 24 小时的公开下载链接。'
          '获得链接的人无需登录；链接仅在本次创建后提供，请妥善发送给收件人。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('创建并复制链接'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _batchBusy = true);
    final links = <String>[];
    String? error;
    for (final item in items) {
      try {
        final result = await widget.api.send(
          'POST',
          '/api/v2/file-shares',
          body: {'path': item.path, 'hours': 24},
        );
        final token = result['token']?.toString() ?? '';
        if (token.isEmpty) throw const FormatException('服务器未返回分享令牌');
        final url = widget.api.uri(
          '/api/v2/public/file/${Uri.encodeComponent(token)}',
        );
        links.add('${item.name}: $url');
      } catch (failure) {
        error = mediaErrorLabel(failure);
        break;
      }
      if (!mounted) return;
    }
    if (links.isNotEmpty) {
      try {
        await Clipboard.setData(ClipboardData(text: links.join('\n')));
      } catch (_) {
        error ??= '无法复制链接到剪贴板，请进入文件分享列表撤销后重试。';
      }
    }
    if (!mounted) return;
    setState(() {
      _batchBusy = false;
      _actionMessage = error == null
          ? '已创建并复制 ${links.length} 条限时下载链接。'
          : '已创建 ${links.length} 条链接。$error';
      _actionIsError = error != null;
    });
  }

  void _toggleSelection(PhotoAsset asset) {
    HapticFeedback.selectionClick();
    setState(() {
      _selecting = true;
      if (_selectedAssets.contains(asset.id)) {
        _selectedAssets.remove(asset.id);
      } else if (_selectedAssets.length < 50) {
        _selectedAssets.add(asset.id);
      } else {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('每次最多选择 50 项媒体。')));
      }
    });
  }

  Future<void> _batchFavorite() async {
    if (_batchBusy || _selectedAssets.isEmpty) return;
    final selected = _assets
        .where(
          (item) => _selectedAssets.contains(item.id) && !item.personalFavorite,
        )
        .toList();
    setState(() => _batchBusy = true);
    var done = 0;
    String? error;
    for (final asset in selected) {
      try {
        await _togglePersonalFavorite(asset);
        done++;
      } catch (failure) {
        error = mediaErrorLabel(failure);
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      _selectedAssets.clear();
      _selecting = false;
      _batchBusy = false;
      _actionMessage = error == null
          ? '已将 $done 项加入我的收藏。'
          : '已完成 $done 项，其他项目未处理：$error';
      _actionIsError = error != null;
    });
  }

  Future<void> _batchAddToPrivateAlbum() async {
    if (_batchBusy || _selectedAssets.isEmpty) return;
    if (_privateAlbums.isEmpty) {
      setState(() {
        _actionMessage = '请先在相册中创建一个私人相册。';
        _actionIsError = true;
      });
      return;
    }
    final albumId = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            Text('整理到私人相册', style: Theme.of(sheetContext).textTheme.titleLarge),
            const SizedBox(height: 10),
            for (final album in _privateAlbums)
              ListTile(
                leading: const Icon(Icons.photo_album_outlined),
                title: Text(album.name),
                subtitle: Text('${album.count} 项 · 仅自己可见'),
                onTap: () => Navigator.pop(sheetContext, album.id),
              ),
          ],
        ),
      ),
    );
    if (albumId == null || !mounted) return;
    setState(() => _batchBusy = true);
    var done = 0;
    String? error;
    for (final asset in _assets.where(
      (item) => _selectedAssets.contains(item.id),
    )) {
      try {
        await widget.api.send(
          'POST',
          '/api/v2/photos/private-albums/$albumId/items',
          body: <String, int>{'assetId': asset.id},
        );
        done++;
      } catch (failure) {
        error = mediaErrorLabel(failure);
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      _selectedAssets.clear();
      _selecting = false;
      _batchBusy = false;
      _actionMessage = error == null
          ? '已将 $done 项加入私人相册。'
          : '已完成 $done 项，其他项目未处理：$error';
      _actionIsError = error != null;
    });
    await _refreshPrivateAlbums();
  }

  Future<void> _openPhotoMap() async {
    final selected = await Navigator.of(context).push<PhotoAsset>(
      MaterialPageRoute<PhotoAsset>(
        builder: (_) => PhotoMapPage(api: widget.api),
      ),
    );
    if (mounted && selected != null) await _openAsset(selected);
  }

  MediaAlbum? get _currentPrivateAlbum {
    for (final album in _privateAlbums) {
      if (album.id == _activePrivateAlbum) return album;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _loadAssets(reset: true);
    _refreshAlbums();
    _refreshPrivateAlbums();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _listGeneration++;
    _albumsGeneration++;
    _privateAlbumsGeneration++;
    _statusGeneration++;
    _statusTimer?.cancel();
    _timelineScroll.dispose();
    _searchTimer?.cancel();
    _searchController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tabEnabled = TickerMode.valuesOf(context).enabled;
    _updatePollingState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appForeground = state == AppLifecycleState.resumed;
    _updatePollingState();
  }

  void _updatePollingState() {
    final active = _tabEnabled && _appForeground;
    if (_pollingActive == active) return;
    _pollingActive = active;
    if (!active) {
      _statusTimer?.cancel();
      _statusTimer = null;
      _statusGeneration++;
    } else {
      _refreshStatus();
    }
  }

  Widget _albumCards(
    BuildContext sheetContext,
    List<MediaAlbum> albums, {
    required bool private,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final columns =
          constraints.maxWidth >= 660 &&
              MediaQuery.textScalerOf(context).scale(14) < 21
          ? 3
          : constraints.maxWidth >= 320 &&
                MediaQuery.textScalerOf(context).scale(14) < 21
          ? 2
          : 1;
      final cardWidth = (constraints.maxWidth - (columns - 1) * 12) / columns;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final album in albums)
            SizedBox(
              width: cardWidth,
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(18),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => Navigator.pop(
                    sheetContext,
                    '${private ? 'private' : 'shared'}:${album.id}',
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AspectRatio(
                        aspectRatio: 1.55,
                        child: album.coverAssetId > 0
                            ? AuthenticatedMediaImage(
                                api: widget.api,
                                path:
                                    '/api/v2/photos/${album.coverAssetId}/thumbnail',
                                fit: BoxFit.cover,
                                maxBytes: 4 * 1024 * 1024,
                                loadingBuilder: (_) =>
                                    _albumCoverPlaceholder(private),
                                errorBuilder: (_, _, retry) => Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    _albumCoverPlaceholder(private),
                                    Align(
                                      alignment: Alignment.bottomRight,
                                      child: IconButton(
                                        tooltip: '重试相册封面',
                                        onPressed: retry,
                                        icon: const Icon(Icons.refresh),
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : _albumCoverPlaceholder(private),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 12,
                        ),
                        child: Text(
                          '${album.name} · ${album.count}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _albumCoverPlaceholder(bool private) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    child: Center(
      child: Icon(
        private ? Icons.photo_library_rounded : Icons.collections_rounded,
        size: 32,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );

  void _syncStatusTimer() {
    if (!_pollingActive || !_scanning) {
      _statusTimer?.cancel();
      _statusTimer = null;
    } else {
      _statusTimer ??= Timer.periodic(
        const Duration(seconds: 3),
        (_) => _refreshStatus(),
      );
    }
  }

  Future<void> _loadAssets({required bool reset, int? startCursor}) async {
    if (!reset && (_loading || _loadingMore || _nextCursor == 0)) return;
    final generation = ++_listGeneration;
    final cursor = reset ? (startCursor ?? 0) : _nextCursor;
    setState(() {
      if (reset) {
        _assets.clear();
        _nextCursor = 0;
        _loadError = null;
        _loading = true;
      } else {
        _loadingMore = true;
      }
    });

    final query = <String, String>{'limit': '$_pageSize', 'cursor': '$cursor'};
    if (_activeAlbum > 0) query['album'] = '$_activeAlbum';
    if (_activePrivateAlbum > 0) {
      query['privateAlbum'] = '$_activePrivateAlbum';
    }
    if (_favoritesOnly) query['favorites'] = '1';
    if (_personalFavoritesOnly) query['personal'] = '1';
    if (_onThisDay) query['onThisDay'] = '1';
    if (_query.isNotEmpty) query['q'] = _query;
    if (_mediaType.isNotEmpty) query['type'] = _mediaType;
    try {
      final response = await widget.api.get('/api/v2/photos', query: query);
      if (!mounted || generation != _listGeneration) return;
      final records = response['assets'];
      final page = <PhotoAsset>[];
      if (records is List) {
        for (final record in records) {
          if (record is Map) {
            try {
              page.add(PhotoAsset.fromJson(Map<String, dynamic>.from(record)));
            } on FormatException {
              // Skip malformed rows while keeping the rest of the page usable.
            }
          }
        }
      }
      final next = response['nextCursor'];
      final parsedNext = next is num
          ? next.toInt()
          : int.tryParse('$next') ?? 0;
      setState(() {
        if (reset) {
          _assets
            ..clear()
            ..addAll(page);
        } else {
          _assets.addAll(page);
        }
        _nextCursor = parsedNext;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted || generation != _listGeneration) return;
      setState(() => _loadError = mediaErrorLabel(error));
    } finally {
      if (mounted && generation == _listGeneration) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  Future<void> _refreshAlbums() async {
    final generation = ++_albumsGeneration;
    try {
      final response = await widget.api.get('/api/v2/photos/albums');
      if (!mounted || generation != _albumsGeneration) return;
      final raw = response['albums'];
      final albums = raw is List
          ? raw
                .whereType<Map>()
                .map(
                  (item) =>
                      MediaAlbum.fromJson(Map<String, dynamic>.from(item)),
                )
                .toList()
          : <MediaAlbum>[];
      setState(() => _albums = albums);
    } catch (_) {
      // Keep previously loaded album navigation visible if a refresh fails.
    }
  }

  Future<void> _refreshPrivateAlbums() async {
    final generation = ++_privateAlbumsGeneration;
    try {
      final response = await widget.api.get('/api/v2/photos/private-albums');
      if (!mounted || generation != _privateAlbumsGeneration) return;
      final raw = response['albums'];
      final albums = raw is List
          ? raw
                .whereType<Map>()
                .map(
                  (item) =>
                      MediaAlbum.fromJson(Map<String, dynamic>.from(item)),
                )
                .toList()
          : <MediaAlbum>[];
      setState(() => _privateAlbums = albums);
    } catch (error) {
      if (mounted && generation == _privateAlbumsGeneration) {
        setState(() {
          _actionMessage = '私人相册加载失败：${mediaErrorLabel(error)}';
          _actionIsError = true;
        });
      }
    }
  }

  Future<void> _refreshStatus() async {
    final generation = ++_statusGeneration;
    try {
      final response = await widget.api.get('/api/v2/photos/status');
      if (!mounted || generation != _statusGeneration) return;
      final status = MediaScanStatus.fromJson(response['status']);
      final finished =
          (_wasScanning && !status.running) ||
          (status.lastDone > 0 && status.lastDone > _lastDone);
      setState(() {
        _scanStatus = status;
        _scanning = status.running;
        _wasScanning = status.running;
        _lastDone = status.lastDone > _lastDone ? status.lastDone : _lastDone;
        _scanError = status.lastError.isEmpty ? null : status.lastError;
      });
      _syncStatusTimer();
      if (finished) {
        await Future.wait([
          _loadAssets(reset: true),
          _refreshAlbums(),
          _refreshPrivateAlbums(),
        ]);
      }
    } catch (_) {
      // Authentication and service health are handled by the application shell.
    }
  }

  Future<void> _startScan() async {
    setState(() {
      _actionMessage = null;
      _actionIsError = false;
    });
    try {
      await widget.api.send('POST', '/api/v2/photos/scan');
      if (!mounted) return;
      setState(() {
        _actionMessage = '媒体扫描已开始。';
        _actionIsError = false;
      });
      await _refreshStatus();
    } catch (error) {
      if (mounted) {
        setState(() {
          _actionMessage = mediaErrorLabel(error);
          _actionIsError = true;
        });
      }
    }
  }

  Future<PhotoAsset> _toggleFavorite(PhotoAsset asset) async {
    if (!widget.isAdmin && !asset.canWrite) {
      throw StateError('当前账号对此媒体只有查看权限。');
    }
    final favorite = !asset.favorite;
    await widget.api.send(
      'POST',
      '/api/v2/photos/${asset.id}/favorite',
      body: <String, Object>{'favorite': favorite},
    );
    if (!mounted) return asset.withFavorite(favorite);
    final updated = asset.withFavorite(favorite);
    setState(() {
      final index = _assets.indexWhere((item) => item.id == asset.id);
      if (index >= 0) {
        if (_favoritesOnly && !favorite) {
          _assets.removeAt(index);
        } else {
          _assets[index] = updated;
        }
      }
      _actionMessage = favorite ? '已加入共享收藏。' : '已从共享收藏移除。';
      _actionIsError = false;
    });
    return updated;
  }

  Future<PhotoAsset> _togglePersonalFavorite(PhotoAsset asset) async {
    final favorite = !asset.personalFavorite;
    await widget.api.send(
      'POST',
      '/api/v2/photos/${asset.id}/personal-favorite',
      body: <String, Object>{'favorite': favorite},
    );
    final updated = asset.withPersonalFavorite(favorite);
    if (!mounted) return updated;
    setState(() {
      final index = _assets.indexWhere((item) => item.id == asset.id);
      if (index >= 0) {
        if (_personalFavoritesOnly && !favorite) {
          _assets.removeAt(index);
        } else {
          _assets[index] = updated;
        }
      }
      _actionMessage = favorite ? '已加入我的收藏。' : '已从我的收藏移除。';
      _actionIsError = false;
    });
    return updated;
  }

  Future<void> _createOrRenameAlbum({MediaAlbum? album}) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlbumNameDialog(initialName: album?.name ?? ''),
    );
    if (name == null || !mounted) return;
    setState(() => _albumBusy = true);
    try {
      if (album == null) {
        await widget.api.send(
          'POST',
          '/api/v2/photos/albums',
          body: <String, String>{'name': name},
        );
        if (!mounted) return;
        setState(() {
          _actionMessage = '相册已创建。';
          _actionIsError = false;
        });
      } else {
        await widget.api.send(
          'PATCH',
          '/api/v2/photos/albums/${album.id}',
          body: <String, String>{'name': name},
        );
        if (!mounted) return;
        setState(() {
          _actionMessage = '相册名称已更新。';
          _actionIsError = false;
        });
      }
      await _refreshAlbums();
    } catch (error) {
      if (mounted) {
        setState(() {
          _actionMessage = mediaErrorLabel(error);
          _actionIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _albumBusy = false);
    }
  }

  Future<void> _createOrRenamePrivateAlbum({MediaAlbum? album}) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) =>
          AlbumNameDialog(initialName: album?.name ?? '', privateAlbum: true),
    );
    if (name == null || !mounted) return;
    setState(() => _albumBusy = true);
    try {
      if (album == null) {
        await widget.api.send(
          'POST',
          '/api/v2/photos/private-albums',
          body: <String, String>{'name': name},
        );
        if (!mounted) return;
        setState(() {
          _actionMessage = '私人相册已创建，仅当前账号可见。';
          _actionIsError = false;
        });
      } else {
        await widget.api.send(
          'PATCH',
          '/api/v2/photos/private-albums/${album.id}',
          body: <String, String>{'name': name},
        );
        if (!mounted) return;
        setState(() {
          _actionMessage = '私人相册名称已更新。';
          _actionIsError = false;
        });
      }
      await _refreshPrivateAlbums();
    } catch (error) {
      if (mounted) {
        setState(() {
          _actionMessage = mediaErrorLabel(error);
          _actionIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _albumBusy = false);
    }
  }

  Future<void> _deleteAlbum(MediaAlbum album) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除相册？'),
        content: Text('只会删除“${album.name}”及其中的关联。原始照片和视频会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除相册'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _albumBusy = true);
    try {
      await widget.api.send('DELETE', '/api/v2/photos/albums/${album.id}');
      if (!mounted) return;
      if (_activeAlbum == album.id) {
        _activeAlbum = 0;
        _favoritesOnly = false;
      }
      setState(() {
        _actionMessage = '相册已删除，原始媒体仍保留。';
        _actionIsError = false;
      });
      await Future.wait([_refreshAlbums(), _loadAssets(reset: true)]);
    } catch (error) {
      if (mounted) {
        setState(() {
          _actionMessage = mediaErrorLabel(error);
          _actionIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _albumBusy = false);
    }
  }

  Future<void> _deletePrivateAlbum(MediaAlbum album) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除私人相册？'),
        content: Text('只会删除“${album.name}”及其中的关联。原始照片、视频和共享相册都会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除私人相册'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _albumBusy = true);
    try {
      await widget.api.send(
        'DELETE',
        '/api/v2/photos/private-albums/${album.id}',
      );
      if (!mounted) return;
      final wasCurrent = _activePrivateAlbum == album.id;
      if (wasCurrent) _activePrivateAlbum = 0;
      setState(() {
        _actionMessage = '私人相册已删除，原始媒体和共享相册仍保留。';
        _actionIsError = false;
      });
      await Future.wait([
        _refreshPrivateAlbums(),
        if (wasCurrent) _loadAssets(reset: true),
      ]);
    } catch (error) {
      if (mounted) {
        setState(() {
          _actionMessage = mediaErrorLabel(error);
          _actionIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _albumBusy = false);
    }
  }

  Future<void> _addToAlbum(int albumId, int assetId) async {
    if (!widget.isAdmin || albumId < 1) return;
    setState(() => _albumBusy = true);
    try {
      await widget.api.send(
        'POST',
        '/api/v2/photos/albums/$albumId/items',
        body: <String, int>{'assetId': assetId},
      );
      if (!mounted) return;
      setState(() {
        _actionMessage = '已加入相册。';
        _actionIsError = false;
      });
      await _refreshAlbums();
    } catch (error) {
      if (mounted) {
        setState(() {
          _actionMessage = mediaErrorLabel(error);
          _actionIsError = true;
        });
      }
      rethrow;
    } finally {
      if (mounted) setState(() => _albumBusy = false);
    }
  }

  Future<void> _removeFromAlbum(int albumId, int assetId) async {
    if (!widget.isAdmin || albumId < 1) return;
    setState(() => _albumBusy = true);
    try {
      await widget.api.send(
        'DELETE',
        '/api/v2/photos/albums/$albumId/items/$assetId',
      );
      if (!mounted) return;
      setState(() {
        _actionMessage = '已从相册移出，原始媒体仍保留。';
        _actionIsError = false;
      });
      await Future.wait([_refreshAlbums(), _loadAssets(reset: true)]);
    } catch (error) {
      if (mounted) {
        setState(() {
          _actionMessage = mediaErrorLabel(error);
          _actionIsError = true;
        });
      }
      rethrow;
    } finally {
      if (mounted) setState(() => _albumBusy = false);
    }
  }

  Future<void> _addToPrivateAlbum(int albumId, int assetId) async {
    if (albumId < 1) return;
    setState(() => _albumBusy = true);
    try {
      await widget.api.send(
        'POST',
        '/api/v2/photos/private-albums/$albumId/items',
        body: <String, int>{'assetId': assetId},
      );
      if (!mounted) return;
      setState(() {
        _actionMessage = '已加入我的私人相册。';
        _actionIsError = false;
      });
      await _refreshPrivateAlbums();
    } catch (error) {
      if (mounted) {
        setState(() {
          _actionMessage = mediaErrorLabel(error);
          _actionIsError = true;
        });
      }
      rethrow;
    } finally {
      if (mounted) setState(() => _albumBusy = false);
    }
  }

  Future<void> _removeFromPrivateAlbum(int albumId, int assetId) async {
    if (albumId < 1) return;
    setState(() => _albumBusy = true);
    try {
      await widget.api.send(
        'DELETE',
        '/api/v2/photos/private-albums/$albumId/items/$assetId',
      );
      if (!mounted) return;
      final wasCurrent = _activePrivateAlbum == albumId;
      if (wasCurrent) _assets.removeWhere((item) => item.id == assetId);
      setState(() {
        _actionMessage = '已从私人相册移出，原始媒体仍保留。';
        _actionIsError = false;
      });
      await Future.wait([
        _refreshPrivateAlbums(),
        if (wasCurrent) _loadAssets(reset: true),
      ]);
    } catch (error) {
      if (mounted) {
        setState(() {
          _actionMessage = mediaErrorLabel(error);
          _actionIsError = true;
        });
      }
      rethrow;
    } finally {
      if (mounted) setState(() => _albumBusy = false);
    }
  }

  Future<void> _selectView({
    int albumId = 0,
    bool favorites = false,
    bool personalFavorites = false,
    int privateAlbumId = 0,
    bool onThisDay = false,
  }) async {
    if (_activeAlbum == albumId &&
        _favoritesOnly == favorites &&
        _personalFavoritesOnly == personalFavorites &&
        _activePrivateAlbum == privateAlbumId &&
        _onThisDay == onThisDay) {
      return;
    }
    setState(() {
      _selecting = false;
      _selectedAssets.clear();
      _activeAlbum = albumId;
      _activePrivateAlbum = privateAlbumId;
      _favoritesOnly = favorites;
      _personalFavoritesOnly = personalFavorites;
      _onThisDay = onThisDay;
      _actionMessage = null;
      _actionIsError = false;
    });
    await _loadAssets(reset: true);
  }

  bool get _fullTimelineSelected =>
      _activeAlbum == 0 &&
      _activePrivateAlbum == 0 &&
      !_favoritesOnly &&
      !_personalFavoritesOnly &&
      !_onThisDay &&
      _query.isEmpty &&
      _mediaType.isEmpty;

  Future<void> _chooseTimelineMonth() async {
    if (!_fullTimelineSelected || _loading) return;
    List<Map<String, dynamic>> months;
    try {
      final response = await widget.api.get('/api/v2/photos/timeline');
      if (!mounted) return;
      final raw = response['months'];
      if (raw is! List) throw const FormatException('缺少年月索引。');
      months =
          [
            for (final value in raw)
              if (value is Map) Map<String, dynamic>.from(value),
          ].where((entry) {
            final year = entry['year'];
            final month = entry['month'];
            final offset = entry['firstIndex'];
            return year is int &&
                year >= 1970 &&
                year <= 9999 &&
                month is int &&
                month >= 1 &&
                month <= 12 &&
                offset is int &&
                offset >= 0;
          }).toList();
    } catch (error) {
      if (mounted) {
        setState(() => _loadError = '读取年月索引失败：${mediaErrorLabel(error)}');
      }
      return;
    }
    if (!mounted) return;
    if (months.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('图库暂无可跳转的拍摄年月。')));
      return;
    }
    final cursor = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * .65,
          child: Column(
            children: [
              const ListTile(
                title: Text('跳转到拍摄年月'),
                subtitle: Text('可直接跳转至尚未加载的历史照片，不必逐页滚动。'),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: months.length,
                  itemBuilder: (context, index) {
                    final month = months[index];
                    return ListTile(
                      leading: const Icon(Icons.calendar_month_outlined),
                      title: Text('${month['year']} 年 ${month['month']} 月'),
                      trailing: Text('${month['count'] ?? 0} 项'),
                      onTap: () => Navigator.pop(
                        sheetContext,
                        month['firstIndex'] as int,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (cursor == null || !mounted) return;
    await _loadAssets(reset: true, startCursor: cursor);
    if (mounted && _timelineScroll.hasClients) {
      _timelineScroll.jumpTo(0);
    }
  }

  Future<void> _openAsset(PhotoAsset asset) async {
    if (_selecting) {
      _toggleSelection(asset);
      return;
    }
    HapticFeedback.selectionClick();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PhotoGalleryViewer(
          api: widget.api,
          offlineAccountId: widget.offlineAccountId,
          assets: List<PhotoAsset>.of(_assets),
          initialIndex: _assets.indexWhere((item) => item.id == asset.id),
          canEditSharedFavorite: (item) => widget.isAdmin || item.canWrite,
          onSharedFavorite: _toggleFavorite,
          onPersonalFavorite: _togglePersonalFavorite,
          onDetails: _showAssetDetails,
          onLoadMore: () async {
            if (_nextCursor > 0 && !_loading && !_loadingMore) {
              await _loadAssets(reset: false);
            }
            return List<PhotoAsset>.of(_assets);
          },
        ),
      ),
    );
  }

  Future<void> _showAssetDetails(PhotoAsset asset) async {
    await showDialog<void>(
      context: context,
      useSafeArea: true,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.65),
      builder: (context) => PhotoDetailDialog(
        api: widget.api,
        asset: asset,
        albums: _albums,
        privateAlbums: _privateAlbums,
        isAdmin: widget.isAdmin,
        currentAlbumId: _activeAlbum,
        currentPrivateAlbumId: _activePrivateAlbum,
        personalFavoritesOnly: _personalFavoritesOnly,
        canToggleFavorite: widget.isAdmin || asset.canWrite,
        onToggleFavorite: _toggleFavorite,
        onTogglePersonalFavorite: _togglePersonalFavorite,
        onAddToAlbum: _addToAlbum,
        onRemoveFromAlbum: _removeFromAlbum,
        onAddToPrivateAlbum: _addToPrivateAlbum,
        onRemoveFromPrivateAlbum: _removeFromPrivateAlbum,
      ),
    );
  }

  Widget _filterChip({
    required String label,
    required bool selected,
    required VoidCallback onSelected,
    IconData? icon,
  }) => MediaFilterChip(
    label: label,
    selected: selected,
    onSelected: onSelected,
    icon: icon,
  );

  Widget _buildGrid() {
    if (_loading && _assets.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(56),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (_assets.isEmpty && _loadError != null) {
      return SliverToBoxAdapter(
        child: MediaEmptyState(
          icon: Icons.photo_library_outlined,
          title: '暂时无法读取图库',
          message: _loadError!,
          action: OutlinedButton.icon(
            onPressed: _loading ? null : () => _loadAssets(reset: true),
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ),
      );
    }
    if (_assets.isEmpty) {
      final album = _currentAlbum;
      final privateAlbum = _currentPrivateAlbum;
      final title = album != null
          ? '此相册还没有媒体'
          : privateAlbum != null
          ? '私人相册还没有媒体'
          : _favoritesOnly
          ? '还没有共享收藏'
          : _personalFavoritesOnly
          ? '还没有个人收藏'
          : _onThisDay
          ? '往年今天还没有照片'
          : _query.isNotEmpty
          ? '没有找到匹配的照片'
          : '这里还没有照片或视频';
      final message = album != null
          ? '在全部照片中打开一项媒体，选择此相册并加入。'
          : privateAlbum != null
          ? '此清单仅当前账号可见。打开全部照片，选择私人相册并加入媒体。'
          : _favoritesOnly
          ? '打开一项你有权编辑的媒体并加入共享收藏。'
          : _personalFavoritesOnly
          ? '预览自己有权限查看的照片，点星形图标保存到仅自己可见的收藏。'
          : _onThisDay
          ? '今天拍摄的往年照片会出现在这里，试试浏览全部照片。'
          : _query.isNotEmpty
          ? '试试其他文件名，或清除搜索条件。'
          : '点击上传，把设备里的照片与视频保存到 NAS。';
      return SliverToBoxAdapter(
        child: MediaEmptyState(
          icon: Icons.photo_library_outlined,
          title: title,
          message: message,
          action:
              (album != null ||
                  privateAlbum != null ||
                  _favoritesOnly ||
                  _personalFavoritesOnly ||
                  _onThisDay)
              ? TextButton.icon(
                  onPressed: () => _selectView(),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('浏览全部照片'),
                )
              : FilledButton.icon(
                  onPressed: _upload,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('上传照片与视频'),
                ),
        ),
      );
    }

    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.crossAxisExtent;
        final baseColumns = width < 420
            ? 3
            : width < 680
            ? 4
            : width < 920
            ? 5
            : (width / 150).floor().clamp(5, 10);
        // Thumbnails are image-based, not text-based; increasing system font
        // size must not turn the gallery back into a sparse file list.
        final columns = baseColumns;
        // Monthly sections keep the flat newest-first grid but give each
        // month a header, mirroring the web timeline.
        final sections = <_AssetMonthSection>[];
        for (final asset in _assets) {
          final key = _assetMonthKey(asset.takenAt);
          if (sections.isEmpty || sections.last.key != key) {
            sections.add(
              _AssetMonthSection(key, formatMediaMonth(asset.takenAt)),
            );
          }
          sections.last.items.add(asset);
        }
        return SliverMainAxisGroup(
          slivers: [
            for (final section in sections) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(_pageInset, 22, _pageInset, 11),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          section.title,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Text(
                        '${section.items.length} 项',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                sliver: SliverGrid.builder(
                  itemCount: section.items.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 2,
                    mainAxisSpacing: 2,
                    childAspectRatio: 1,
                  ),
                  itemBuilder: (context, index) {
                    final asset = section.items[index];
                    return Semantics(
                      button: true,
                      label:
                          '${asset.name}, ${asset.isVideo ? '视频' : '照片'}，${formatMediaDate(asset.takenAt)}${asset.personalFavorite ? '，我的收藏' : ''}${asset.favorite ? '，共享收藏' : ''}',
                      child: InkWell(
                        onTap: () => _openAsset(asset),
                        onLongPress: () => _toggleSelection(asset),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Hero(
                                tag: 'photo_thumb_${asset.id}',
                                child: asset.isRaw
                                    ? Container(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .surfaceContainerLow,
                                        child: const Center(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons
                                                    .insert_drive_file_outlined,
                                                size: 26,
                                              ),
                                              Text(
                                                'RAW',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      )
                                    : AuthenticatedMediaImage(
                                        api: widget.api,
                                        path:
                                            '/api/v2/photos/${asset.id}/thumbnail',
                                        maxBytes: 4 * 1024 * 1024,
                                        fit: BoxFit.cover,
                                        loadingBuilder: (context) => Container(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .surfaceContainerLow,
                                        ),
                                        errorBuilder: (context, error, retry) =>
                                            Container(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .surfaceContainerHigh,
                                              child: Stack(
                                                fit: StackFit.expand,
                                                children: [
                                                  Center(
                                                    child: Icon(
                                                      asset.isVideo
                                                          ? Icons.movie_outlined
                                                          : Icons
                                                                .image_not_supported_outlined,
                                                    ),
                                                  ),
                                                  Positioned(
                                                    left: 0,
                                                    top: 0,
                                                    child: DecoratedBox(
                                                      decoration:
                                                          const BoxDecoration(
                                                            color:
                                                                Colors.black54,
                                                            shape:
                                                                BoxShape.circle,
                                                          ),
                                                      child: IconButton(
                                                        tooltip: '重试缩略图',
                                                        visualDensity:
                                                            VisualDensity
                                                                .compact,
                                                        onPressed: retry,
                                                        icon: const Icon(
                                                          Icons.refresh,
                                                          size: 16,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                      ),
                              ),
                              if (_selecting)
                                Positioned(
                                  top: 5,
                                  left: 5,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: _selectedAssets.contains(asset.id)
                                          ? Theme.of(context)
                                                .colorScheme
                                                .primary
                                          : Colors.black54,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 1.5,
                                      ),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(3),
                                      child: Icon(
                                        _selectedAssets.contains(asset.id)
                                            ? Icons.check_rounded
                                            : Icons.circle_outlined,
                                        size: 16,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              if (asset.isVideo)
                                Positioned(
                                  right: 5,
                                  bottom: 5,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.play_arrow_rounded,
                                        color: Colors.white,
                                        size: 18,
                                        shadows: [
                                          Shadow(
                                            blurRadius: 6,
                                            color: Colors.black87,
                                          ),
                                        ],
                                      ),
                                      if (asset.durationSeconds > 0)
                                        Text(
                                          formatMediaSeconds(
                                            asset.durationSeconds,
                                          ),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                            shadows: [
                                              Shadow(
                                                blurRadius: 6,
                                                color: Colors.black87,
                                              ),
                                            ],
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              if (asset.favorite || asset.personalFavorite)
                                Positioned(
                                  top: 7,
                                  right: 7,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (asset.personalFavorite)
                                        Icon(
                                          Icons.star,
                                          color: Color(0xFFFFD76C),
                                          size: 17,
                                          shadows: [
                                            Shadow(
                                              blurRadius: 5,
                                              color: Colors.black54,
                                            ),
                                          ],
                                        ),
                                      if (asset.favorite &&
                                          asset.personalFavorite)
                                        const SizedBox(width: 4),
                                      if (asset.favorite)
                                        Icon(
                                          Icons.favorite,
                                          color: Colors.white,
                                          size: 18,
                                          shadows: [
                                            Shadow(
                                              blurRadius: 5,
                                              color: Colors.black54,
                                            ),
                                          ],
                                        ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Future<void> _upload() async {
    final count = await openFileUpload(
      context,
      api: widget.api,
      isAdmin: widget.isAdmin,
      directory: widget.uploadDirectory,
      type: FileType.media,
      title: '上传照片与视频',
    );
    if (!mounted || count == 0) return;
    String? indexingError;
    if (widget.isAdmin && !_scanning) {
      await _startScan();
      if (_actionIsError) indexingError = _actionMessage;
    }
    if (!mounted) return;
    setState(() {
      _actionMessage =
          '已上传 $count 项。${indexingError == null ? '索引更新后会显示在全部照片中，可下拉刷新。' : '媒体整理暂未开始：$indexingError'}';
      _actionIsError = indexingError != null;
      _activeAlbum = 0;
      _activePrivateAlbum = 0;
      _favoritesOnly = false;
      _personalFavoritesOnly = false;
      _onThisDay = false;
      _searchTimer?.cancel();
      _query = '';
      _mediaType = '';
      _searchController.clear();
      _showSearch = false;
    });
    await _loadAssets(reset: true);
  }

  Future<void> _browseAlbums() async {
    final value = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .78,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '我的相册',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                IconButton(
                  tooltip: '关闭相册',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '把珍贵照片整理成自己的收藏集',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.add_rounded),
              label: const Text('新建私人相册'),
              onPressed: _albumBusy
                  ? null
                  : () => Navigator.pop(context, 'createPrivate'),
            ),
            if (widget.isAdmin)
              TextButton.icon(
                icon: const Icon(Icons.people_outline_rounded),
                label: const Text('新建相册'),
                onPressed: _albumBusy
                    ? null
                    : () => Navigator.pop(context, 'createShared'),
              ),
            const SizedBox(height: 18),
            Text('我的私人相册', style: Theme.of(context).textTheme.titleMedium),
            Text('仅当前账号可见', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 10),
            if (_privateAlbums.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text('还没有私人相册，可创建一个来整理照片。'),
              ),
            _albumCards(context, _privateAlbums, private: true),
            const SizedBox(height: 24),
            Text('共享相册', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            if (_albums.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('还没有共享相册。'),
              ),
            _albumCards(context, _albums, private: false),
          ],
        ),
      ),
    );
    if (!mounted || value == null) return;
    if (value == 'createPrivate') {
      await _createOrRenamePrivateAlbum();
    } else if (value == 'createShared') {
      await _createOrRenameAlbum();
    } else if (value.startsWith('private:')) {
      _selectView(privateAlbumId: int.parse(value.split(':').last));
    } else {
      _selectView(albumId: int.parse(value.split(':').last));
    }
  }

  void _photoAction(String value) {
    switch (value) {
      case 'map':
        _openPhotoMap();
      case 'offline':
        if (widget.offlineAccountId.isEmpty) {
          setState(
            () => _actionMessage = '当前服务器未提供稳定账号 ID，升级 NAS 后才能安全使用离线照片库。',
          );
        } else {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => OfflinePhotosPage(
                api: widget.api,
                accountId: widget.offlineAccountId,
              ),
            ),
          );
        }
      case 'files':
        openFileManager(
          context,
          api: widget.api,
          isAdmin: widget.isAdmin,
          directory: widget.uploadDirectory,
          title: '照片文件',
        );
      case 'month':
        _chooseTimelineMonth();
      case 'today':
        _selectView(onThisDay: true);
      case 'sharedFavorites':
        _selectView(favorites: true);
      case 'scan':
        _startScan();
      case 'refresh':
        _loadAssets(reset: true);
        _refreshAlbums();
        _refreshPrivateAlbums();
      case 'all':
      case 'photo':
      case 'video':
        setState(() => _mediaType = value == 'all' ? '' : value);
        _loadAssets(reset: true);
      case 'renamePrivate':
        _createOrRenamePrivateAlbum(album: _currentPrivateAlbum!);
      case 'deletePrivate':
        _deletePrivateAlbum(_currentPrivateAlbum!);
      case 'renameShared':
        _createOrRenameAlbum(album: _currentAlbum!);
      case 'deleteShared':
        _deleteAlbum(_currentAlbum!);
      case 'backup':
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => AndroidPhotoBackupPage(
              api: widget.api,
              accountName: widget.accountName,
              baseDirectory: widget.backupDirectory,
            ),
          ),
        );
    }
  }

  Widget _photoNavigation() {
    final selectedAlbum = _currentPrivateAlbum ?? _currentAlbum;
    return Padding(
      padding: EdgeInsets.fromLTRB(_pageInset, 0, _pageInset, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _filterChip(
                  label: '全部照片',
                  selected:
                      _activeAlbum == 0 &&
                      _activePrivateAlbum == 0 &&
                      !_favoritesOnly &&
                      !_personalFavoritesOnly &&
                      !_onThisDay,
                  onSelected: () => _selectView(),
                ),
                const SizedBox(width: 8),
                ActionChip(
                  label: Text(
                    selectedAlbum == null ? '相册' : selectedAlbum.name,
                  ),
                  onPressed: _browseAlbums,
                ),
                const SizedBox(width: 8),
                _filterChip(
                  label: '我的收藏',
                  icon: Icons.star_outline,
                  selected: _personalFavoritesOnly,
                  onSelected: () => _selectView(personalFavorites: true),
                ),
                if (_favoritesOnly || _onThisDay || _mediaType.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  InputChip(
                    label: Text(
                      _favoritesOnly
                          ? '共享收藏'
                          : _onThisDay
                          ? '那年今天'
                          : _mediaType == 'photo'
                          ? '仅照片'
                          : '仅视频',
                    ),
                    onDeleted: () {
                      setState(() => _mediaType = '');
                      _selectView();
                    },
                  ),
                ],
              ],
            ),
          ),
          if (_currentPrivateAlbum != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '私人相册 · 仅当前账号可见',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (_showSearch)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                maxLength: 32,
                textInputAction: TextInputAction.search,
                onChanged: (value) {
                  _searchTimer?.cancel();
                  _searchTimer = Timer(const Duration(milliseconds: 350), () {
                    if (!mounted) return;
                    setState(() => _query = value.trim());
                    _loadAssets(reset: true);
                  });
                },
                decoration: InputDecoration(
                  hintText: '搜索照片或视频文件名',
                  counterText: '',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(
                    tooltip: '关闭搜索',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _searchTimer?.cancel();
                      _searchController.clear();
                      setState(() {
                        _query = '';
                        _showSearch = false;
                      });
                      _loadAssets(reset: true);
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Page-level horizontal inset follows the shared layout baseline; the
  /// photo grid itself stays full-bleed like iOS Photos.
  double get _pageInset =>
      IsleLayout.pageInset(MediaQuery.sizeOf(context).width);

  @override
  Widget build(BuildContext context) {
    // Near-endless scroll: paging fires automatically as the viewport
    // approaches the sentinel; the manual button stays as the fallback.
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollUpdateNotification &&
            (notification.scrollDelta ?? 0) > 0 &&
            notification.metrics.axis == Axis.vertical &&
            notification.depth == 0 &&
            notification.metrics.extentAfter < 650 &&
            _nextCursor > 0 &&
            !_loading &&
            !_loadingMore &&
            _loadError == null) {
          _loadAssets(reset: false);
        }
        return false;
      },
      child: RefreshIndicator(
        onRefresh: () async {
          await Future.wait([
            _loadAssets(reset: true),
            _refreshAlbums(),
            _refreshPrivateAlbums(),
          ]);
        },
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          controller: _timelineScroll,
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(_pageInset, 16, _pageInset, 0),
                    child: IslePageHeader(
                      title: '图库',
                      subtitle:
                          _currentPrivateAlbum?.name ??
                          _currentAlbum?.name ??
                          (_personalFavoritesOnly
                              ? '我的收藏'
                              : _favoritesOnly
                              ? '共享收藏'
                              : _onThisDay
                              ? '那年今天'
                              : '按时间整理的照片和视频'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: _selecting ? '退出选择' : '选择照片',
                            onPressed: _batchBusy
                                ? null
                                : () => setState(() {
                                    _selecting = !_selecting;
                                    _selectedAssets.clear();
                                  }),
                            icon: Icon(
                              _selecting
                                  ? Icons.close_rounded
                                  : Icons.checklist_rounded,
                            ),
                          ),
                          IconButton(
                            tooltip: '搜索照片',
                            onPressed: () =>
                                setState(() => _showSearch = !_showSearch),
                            icon: const Icon(Icons.search_rounded),
                          ),
                          IconButton(
                            tooltip: '上传照片与视频',
                            onPressed: _upload,
                            icon: const Icon(Icons.add_rounded),
                          ),
                          PopupMenuButton<String>(
                            tooltip: '更多照片操作',
                            onSelected: _photoAction,
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                value: 'offline',
                                child: Text('本机离线照片库'),
                              ),
                              const PopupMenuItem(
                                value: 'map',
                                child: Text('地图回溯'),
                              ),
                              if (_fullTimelineSelected &&
                                  _query.isEmpty &&
                                  _mediaType.isEmpty)
                                const PopupMenuItem(
                                  value: 'month',
                                  child: Text('年月跳转'),
                                ),
                              const PopupMenuItem(
                                value: 'today',
                                child: Text('那年今天'),
                              ),
                              const PopupMenuItem(
                                value: 'sharedFavorites',
                                child: Text('共享收藏'),
                              ),
                              const PopupMenuItem(
                                value: 'files',
                                child: Text('管理照片文件'),
                              ),
                              const PopupMenuDivider(),
                              const PopupMenuItem(
                                value: 'all',
                                child: Text('照片与视频'),
                              ),
                              const PopupMenuItem(
                                value: 'photo',
                                child: Text('仅照片'),
                              ),
                              const PopupMenuItem(
                                value: 'video',
                                child: Text('仅视频'),
                              ),
                              if (_currentPrivateAlbum != null) ...[
                                PopupMenuItem(
                                  value: 'renamePrivate',
                                  enabled: !_albumBusy,
                                  child: const Text('重命名私人相册'),
                                ),
                                PopupMenuItem(
                                  value: 'deletePrivate',
                                  enabled: !_albumBusy,
                                  child: const Text('删除私人相册'),
                                ),
                              ],
                              if (widget.isAdmin && _currentAlbum != null) ...[
                                PopupMenuItem(
                                  value: 'renameShared',
                                  enabled: !_albumBusy,
                                  child: const Text('重命名相册'),
                                ),
                                PopupMenuItem(
                                  value: 'deleteShared',
                                  enabled: !_albumBusy,
                                  child: const Text('删除相册'),
                                ),
                              ],
                              if (widget.canBackup &&
                                  (defaultTargetPlatform ==
                                          TargetPlatform.android ||
                                      defaultTargetPlatform ==
                                          TargetPlatform.iOS))
                                const PopupMenuItem(
                                  value: 'backup',
                                  child: Text('手机照片备份'),
                                ),
                              const PopupMenuItem(
                                value: 'refresh',
                                child: Text('刷新图库'),
                              ),
                              if (widget.isAdmin)
                                PopupMenuItem(
                                  value: 'scan',
                                  enabled: !_scanning,
                                  child: Text(_scanning ? '扫描中' : '扫描媒体'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  _photoNavigation(),
                  if (_selecting)
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        _pageInset,
                        0,
                        _pageInset,
                        14,
                      ),
                      child: Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          Text(
                            '已选 ${_selectedAssets.length} 项',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          OutlinedButton.icon(
                            onPressed: _batchBusy || _selectedAssets.isEmpty
                                ? null
                                : _batchFavorite,
                            icon: const Icon(
                              Icons.star_border_rounded,
                              size: 17,
                            ),
                            label: const Text('收藏'),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: _batchBusy || _selectedAssets.isEmpty
                                ? null
                                : _batchAddToPrivateAlbum,
                            icon: const Icon(
                              Icons.add_to_photos_outlined,
                              size: 17,
                            ),
                            label: const Text('加入相册'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _batchBusy || _selectedAssets.isEmpty
                                ? null
                                : _batchExport,
                            icon: const Icon(Icons.download_outlined, size: 17),
                            label: const Text('保存原文件'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _batchBusy || _selectedAssets.isEmpty
                                ? null
                                : _batchShare,
                            icon: const Icon(
                              Icons.ios_share_outlined,
                              size: 17,
                            ),
                            label: const Text('分享'),
                          ),
                        ],
                      ),
                    ),
                  if (_scanning)
                    MediaStatusBanner(
                      message: '正在整理媒体 · 已找到 ${_scanStatus.found} 项',
                      icon: Icons.sync,
                    ),
                  if (_scanError != null)
                    MediaStatusBanner(
                      message: '上次扫描未完成：$_scanError',
                      isError: true,
                    ),
                  if (_actionMessage != null)
                    MediaStatusBanner(
                      message: _actionMessage!,
                      isError: _actionIsError,
                    ),
                  if (_loadError != null && _assets.isNotEmpty)
                    MediaStatusBanner(
                      message: _loadError!,
                      isError: true,
                      icon: Icons.error_outline,
                      trailing: TextButton(
                        onPressed: _loadingMore
                            ? null
                            : () => _loadAssets(reset: false),
                        child: const Text('重试'),
                      ),
                    ),
                ],
              ),
            ),
            _buildGrid(),
            SliverToBoxAdapter(
              child: Column(
                children: [
                  if (_assets.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        _pageInset,
                        20,
                        _pageInset,
                        26,
                      ),
                      child: Center(
                        child: _nextCursor > 0
                            ? OutlinedButton.icon(
                                onPressed: _loadingMore
                                    ? null
                                    : () => _loadAssets(reset: false),
                                icon: _loadingMore
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.expand_more),
                                label: Text(_loadingMore ? '正在加载' : '加载更多媒体'),
                              )
                            : Text(
                                '已显示全部 ${_assets.length} 项',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                      ),
                    ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AlbumNameDialog extends StatefulWidget {
  const AlbumNameDialog({
    this.initialName = '',
    this.privateAlbum = false,
    super.key,
  });

  final String initialName;
  final bool privateAlbum;

  @override
  State<AlbumNameDialog> createState() => _AlbumNameDialogState();
}

class _AlbumNameDialogState extends State<AlbumNameDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    final length = name.runes.length;
    if (length == 0) {
      setState(() => _error = '请输入相册名称。');
      return;
    }
    if (length > 60 || RegExp(r'[\x00-\x1F\x7F-\x9F]').hasMatch(name)) {
      setState(() => _error = '相册名称需为 1–60 个字符，且不能包含控制字符。');
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.initialName.isEmpty
          ? widget.privateAlbum
                ? '新建私人相册'
                : '新建相册'
          : widget.privateAlbum
          ? '修改私人相册名称'
          : '修改相册名称',
    ),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLength: 120,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _submit(),
      decoration: InputDecoration(
        labelText: '相册名称',
        errorText: _error,
        helperText: '最多 60 个字符',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _submit,
        child: Text(widget.initialName.isEmpty ? '创建' : '保存'),
      ),
    ],
  );
}

class _AssetMonthSection {
  _AssetMonthSection(this.key, this.title) : items = <PhotoAsset>[];

  final String key;
  final String title;
  final List<PhotoAsset> items;
}

String _assetMonthKey(int takenAt) {
  if (takenAt <= 0) return 'unknown';
  final value = DateTime.fromMillisecondsSinceEpoch(takenAt * 1000).toLocal();
  return '${value.year}-${value.month}';
}
