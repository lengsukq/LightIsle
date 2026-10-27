import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import 'media_models.dart';
import 'photo_map_page.dart';
import 'media_ui.dart';
import '../files/android_photo_backup_page.dart';

class PhotosPage extends StatefulWidget {
  const PhotosPage({required this.api, required this.isAdmin,
    this.accountName = '', this.backupDirectory = 'PhonePhotos',
    this.canBackup = false, super.key});

  final LightIsleApi api;
  final bool isAdmin;
  final String accountName;
  final String backupDirectory;
  final bool canBackup;

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

  bool get _fullTimelineSelected => _activeAlbum == 0 &&
      _activePrivateAlbum == 0 && !_favoritesOnly &&
      !_personalFavoritesOnly && !_onThisDay;

  Future<void> _chooseTimelineMonth() async {
    if (!_fullTimelineSelected || _loading) return;
    List<Map<String, dynamic>> months;
    try {
      final response = await widget.api.get('/api/v2/photos/timeline');
      if (!mounted) return;
      final raw = response['months'];
      if (raw is! List) throw const FormatException('缺少年月索引。');
      months = [
        for (final value in raw)
          if (value is Map)
            Map<String, dynamic>.from(value),
      ].where((entry) {
        final year = entry['year'];
        final month = entry['month'];
        final offset = entry['firstIndex'];
        return year is int && year >= 1970 && year <= 9999 &&
            month is int && month >= 1 && month <= 12 &&
            offset is int && offset >= 0;
      }).toList();
    } catch (error) {
      if (mounted) setState(() => _loadError = '读取年月索引失败：${mediaErrorLabel(error)}');
      return;
    }
    if (!mounted) return;
    if (months.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('图库暂无可跳转的拍摄年月。')),
      );
      return;
    }
    final cursor = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * .65,
          child: Column(children: [
            const ListTile(title: Text('跳转到拍摄年月'),
              subtitle: Text('可直接跳转至尚未加载的历史照片，不必逐页滚动。')),
            Expanded(child: ListView.builder(
              itemCount: months.length,
              itemBuilder: (context, index) {
                final month = months[index];
                return ListTile(
                  leading: const Icon(Icons.calendar_month_outlined),
                  title: Text('${month['year']} 年 ${month['month']} 月'),
                  trailing: Text('${month['count'] ?? 0} 项'),
                  onTap: () => Navigator.pop(sheetContext, month['firstIndex'] as int),
                );
              },
            )),
          ]),
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
    HapticFeedback.selectionClick();
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
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;
    final maxLabelWidth = (MediaQuery.sizeOf(context).width * .58)
        .clamp(160.0, 300.0)
        .toDouble();

    return ChoiceChip(
      avatar: icon == null
          ? null
          : Icon(
              icon,
              size: 16,
              color: selected ? primary : theme.colorScheme.onSurfaceVariant,
            ),
      label: Tooltip(
        message: label,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxLabelWidth),
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
      selected: selected,
      onSelected: (_) => onSelected(),
      selectedColor: primary.withValues(alpha: isDark ? 0.22 : 0.12),
      backgroundColor: theme.colorScheme.surfaceContainerHigh.withValues(
        alpha: isDark ? 0.5 : 0.6,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      side: BorderSide(
        color: selected
            ? primary.withValues(alpha: isDark ? 0.50 : 0.38)
            : (isDark
                  ? Colors.white.withValues(alpha: 0.10)
                  : theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
        width: selected ? 1.0 : 0.8,
      ),
      labelStyle: TextStyle(
        color: selected ? primary : theme.colorScheme.onSurface,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        letterSpacing: -0.2,
      ),
    );
  }

  Widget _buildGrid() {
    if (_loading && _assets.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(56),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_assets.isEmpty && _loadError != null) {
      return MediaEmptyState(
        icon: Icons.photo_library_outlined,
        title: '暂时无法读取图库',
        message: _loadError!,
        action: OutlinedButton.icon(
          onPressed: _loading ? null : () => _loadAssets(reset: true),
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
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
          : widget.isAdmin
          ? '将媒体放入共享目录后，扫描媒体以建立图库。'
          : '请联系管理员检查共享目录并扫描媒体。';
      return MediaEmptyState(
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
            : null,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final baseColumns = width < 420
            ? 3
            : width < 680
            ? 4
            : width < 920
            ? 5
            : (width / 168).floor().clamp(5, 9);
        final textScale = (MediaQuery.textScalerOf(context).scale(14) / 14)
            .clamp(1.0, 2.5)
            .toDouble();
        final columns = (baseColumns / textScale).round().clamp(2, 9).toInt();
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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final section in sections) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: Text(
                  section.title,
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              GridView.builder(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: section.items.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  childAspectRatio: .93,
                ),
                itemBuilder: (context, index) {
                  final asset = section.items[index];
                  return Semantics(
                    button: true,
                    label:
                        '${asset.name}, ${asset.isVideo ? '视频' : '照片'}，${formatMediaDate(asset.takenAt)}${asset.personalFavorite ? '，我的收藏' : ''}${asset.favorite ? '，共享收藏' : ''}',
                    child: InkWell(
                      onTap: () => _openAsset(asset),
                      borderRadius: BorderRadius.circular(12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Hero(
                              tag: 'photo_thumb_${asset.id}',
                              child: AuthenticatedMediaImage(
                                api: widget.api,
                                path: '/api/v2/photos/${asset.id}/thumbnail',
                                maxBytes: 4 * 1024 * 1024,
                                fit: BoxFit.cover,
                                loadingBuilder: (context) => Container(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerLow,
                                  child: const Center(
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                ),
                                errorBuilder: (context, error, retry) => Container(
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
                                          decoration: const BoxDecoration(
                                            color: Colors.black54,
                                            shape: BoxShape.circle,
                                          ),
                                          child: IconButton(
                                            tooltip: '重试缩略图',
                                            visualDensity:
                                                VisualDensity.compact,
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
                            if (asset.isVideo)
                              const Align(
                                alignment: Alignment.center,
                                child: Icon(
                                  Icons.play_circle_outline,
                                  color: Colors.white,
                                  size: 36,
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
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: DecoratedBox(
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.transparent,
                                      Color(0xB3000000),
                                    ],
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    7,
                                    18,
                                    7,
                                    6,
                                  ),
                                  child: Text(
                                    formatMediaDate(asset.takenAt),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(color: Colors.white),
                                  ),
                                ),
                              ),
                            ),
                            Positioned.fill(
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outlineVariant
                                          .withValues(alpha: .7),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentAlbum = _currentAlbum;
    final currentPrivateAlbum = _currentPrivateAlbum;
    // Near-endless scroll: paging fires automatically as the viewport
    // approaches the sentinel; the manual button stays as the fallback.
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 650 &&
            _nextCursor > 0 &&
            !_loading &&
            !_loadingMore &&
            _loadError == null) {
          _loadAssets(reset: false);
        }
        return false;
      },
      child: SingleChildScrollView(
        controller: _timelineScroll,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: IslePageHeader(
                title: '照片图库',
                subtitle: '浏览共享照片与视频，原始媒体保存在授权目录中。',
                icon: Icons.photo_library_rounded,
                trailing: Wrap(spacing: 8, children: [
                  if(widget.canBackup && (defaultTargetPlatform == TargetPlatform.android ||
                      defaultTargetPlatform == TargetPlatform.iOS))
                    OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => AndroidPhotoBackupPage(
                            api:widget.api, accountName:widget.accountName,
                            baseDirectory:widget.backupDirectory,
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                      label: const Text('手机照片备份'),
                    ),
                  if(widget.isAdmin)
                    OutlinedButton.icon(
                        onPressed: _scanning ? null : _startScan,
                        icon: _scanning
                            ? const SizedBox(
                                width: 17,
                                height: 17,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh, size: 18),
                        label: Text(_scanning ? '扫描中' : '扫描媒体'),
                      )
                ]),
              ),
            ),
            if (_scanning)
              MediaStatusBanner(
                message: widget.isAdmin
                    ? '正在后台扫描 · 已检查 ${_scanStatus.scanned} 项 · 找到 ${_scanStatus.found} 项。'
                    : '正在后台扫描授权的共享目录。',
                icon: Icons.sync,
              ),
            if (_scanError != null)
              MediaStatusBanner(
                message: '上次扫描未完成：$_scanError',
                icon: Icons.warning_amber_outlined,
                isError: true,
              ),
            if (_actionMessage != null)
              MediaStatusBanner(
                message: _actionMessage!,
                icon: _actionIsError
                    ? Icons.error_outline
                    : Icons.check_circle_outline,
                isError: _actionIsError,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
              child: LayoutBuilder(
                builder: (context, constraints) => Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _openPhotoMap,
                      icon: const Icon(Icons.map_outlined, size: 18),
                      label: const Text('地图回溯'),
                    ),
                    if (_fullTimelineSelected)
                      OutlinedButton.icon(
                        onPressed: _loading ? null : () => unawaited(_chooseTimelineMonth()),
                        icon: const Icon(Icons.calendar_month_outlined, size: 18),
                        label: const Text('年月跳转'),
                      ),
                    _filterChip(
                      label: '全部照片',
                      icon: Icons.photo_library_outlined,
                      selected:
                          _activeAlbum == 0 &&
                          _activePrivateAlbum == 0 &&
                          !_favoritesOnly &&
                          !_personalFavoritesOnly &&
                          !_onThisDay,
                      onSelected: () => _selectView(),
                    ),
                    _filterChip(
                      label: '共享收藏',
                      icon: Icons.favorite_border,
                      selected: _favoritesOnly,
                      onSelected: () => _selectView(favorites: true),
                    ),
                    _filterChip(
                      label: '我的收藏',
                      icon: Icons.star_outline,
                      selected: _personalFavoritesOnly,
                      onSelected: () => _selectView(personalFavorites: true),
                    ),
                    _filterChip(
                      label: '那年今天',
                      icon: Icons.history_rounded,
                      selected: _onThisDay,
                      onSelected: () => _selectView(onThisDay: true),
                    ),
                    for (final album in _albums)
                      _filterChip(
                        label: '${album.name} · ${album.count}',
                        selected: _activeAlbum == album.id,
                        onSelected: () => _selectView(albumId: album.id),
                      ),
                    for (final album in _privateAlbums)
                      _filterChip(
                        label: '${album.name} · ${album.count}',
                        icon: Icons.folder_special_outlined,
                        selected: _activePrivateAlbum == album.id,
                        onSelected: () => _selectView(privateAlbumId: album.id),
                      ),
                    if (widget.isAdmin)
                      OutlinedButton.icon(
                        onPressed: _albumBusy
                            ? null
                            : () => _createOrRenameAlbum(),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('新建相册'),
                      ),
                    OutlinedButton.icon(
                      onPressed: _albumBusy
                          ? null
                          : () => _createOrRenamePrivateAlbum(),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('新建私人相册'),
                    ),
                  ],
                ),
              ),
            ),
            if (widget.isAdmin && currentAlbum != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '当前相册：${currentAlbum.name}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    OutlinedButton.icon(
                      onPressed: _albumBusy
                          ? null
                          : () => _createOrRenameAlbum(album: currentAlbum),
                      icon: const Icon(Icons.edit_outlined, size: 17),
                      label: const Text('改名'),
                    ),
                    TextButton.icon(
                      onPressed: _albumBusy
                          ? null
                          : () => _deleteAlbum(currentAlbum),
                      icon: const Icon(Icons.delete_outline, size: 17),
                      label: const Text('删除相册'),
                    ),
                  ],
                ),
              ),
            if (currentPrivateAlbum != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '我的私人相册：${currentPrivateAlbum.name}（仅当前账号可见）',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    OutlinedButton.icon(
                      onPressed: _albumBusy
                          ? null
                          : () => _createOrRenamePrivateAlbum(
                              album: currentPrivateAlbum,
                            ),
                      icon: const Icon(Icons.edit_outlined, size: 17),
                      label: const Text('改名'),
                    ),
                    TextButton.icon(
                      onPressed: _albumBusy
                          ? null
                          : () => _deletePrivateAlbum(currentPrivateAlbum),
                      icon: const Icon(Icons.delete_outline, size: 17),
                      label: const Text('删除私人相册'),
                    ),
                  ],
                ),
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
            _buildGrid(),
            if (_assets.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 26),
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
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 22),
              child: Text(
                '缩略图按需生成，图库不会修改或复制原始媒体。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
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

  @override
  State<PhotoDetailDialog> createState() => _PhotoDetailDialogState();
}

class _PhotoDetailDialogState extends State<PhotoDetailDialog>
    with WidgetsBindingObserver {
  late PhotoAsset _asset;
  VideoPlayerController? _videoController;
  Future<void>? _videoInitialization;
  int? _selectedAlbum;
  int? _selectedPrivateAlbum;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _asset = widget.asset;
    if (_asset.isVideo) {
      _videoInitialization = _initializeVideo();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      final controller = _videoController;
      if (controller?.value.isPlaying == true) {
        unawaited(controller!.pause());
      }
    }
  }

  Future<void> _initializeVideo() async {
    try {
      final source = await widget.api.mediaUri(
        '/api/v2/files/preview',
        query: <String, String>{'path': _asset.path},
      );
      if (!mounted) return;
      _videoController = VideoPlayerController.networkUrl(
        source,
        httpHeaders: widget.api.nativeMediaHeaders,
      );
      await _videoController!.initialize();
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) setState(() => _error = '无法播放此视频：${mediaErrorLabel(error)}');
    }
  }

  @override
  void dispose() {
    _detailZoomController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _videoController?.dispose();
    super.dispose();
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

  final TransformationController _detailZoomController =
      TransformationController();
  bool _detailZoomed = false;

  void _toggleDetailZoom(Offset tapPosition) {
    if (_detailZoomed) {
      _detailZoomController.value = Matrix4.identity();
    } else {
      _detailZoomController.value = Matrix4.identity()
        ..translateByDouble(-tapPosition.dx * 1.5, -tapPosition.dy * 1.5, 0, 1)
        ..scaleByDouble(2.5, 2.5, 2.5, 1);
    }
    _detailZoomed = !_detailZoomed;
  }

  Widget _mediaPreview(BuildContext context) {
    if (!_asset.isVideo) {
      return AspectRatio(
        aspectRatio: _asset.width > 0 && _asset.height > 0
            ? (_asset.width / _asset.height).clamp(.5, 2.5).toDouble()
            : 1.4,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: GestureDetector(
            // Double-tap toggles between the overview and a 2.5x close-up;
            // pinch continues to work through the InteractiveViewer.
            onDoubleTapDown: (details) =>
                _toggleDetailZoom(details.localPosition),
            onDoubleTap: () {},
            child: InteractiveViewer(
              minScale: 1.0,
              maxScale: 4.5,
              transformationController: _detailZoomController,
              child: Hero(
                tag: 'photo_thumb_${_asset.id}',
                child: AuthenticatedMediaImage(
                  api: widget.api,
                  // The 2048px server preview keeps HEIC and very large
                  // photos legible; the grid Hero still shows the 512px tile.
                  path: '/api/v2/files/thumbnail',
                  query: {'path': _asset.path, 'size': '2048'},
                  maxBytes: 12 * 1024 * 1024,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, retry) => Center(
                    child: IconButton(
                      tooltip: '重试加载照片',
                      onPressed: retry,
                      icon: const Icon(Icons.broken_image_outlined, size: 48),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return FutureBuilder<void>(
      future: _videoInitialization,
      builder: (context, snapshot) {
        if (snapshot.hasError || _error != null) {
          return Center(
            child: Text(_error ?? '此视频无法播放。', textAlign: TextAlign.center),
          );
        }
        final controller = _videoController;
        if (controller == null || !controller.value.isInitialized) {
          return const Center(child: CircularProgressIndicator());
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: controller.value.aspectRatio,
              child: VideoPlayer(controller),
            ),
            Row(
              children: [
                IconButton(
                  tooltip: controller.value.isPlaying ? '暂停' : '播放',
                  onPressed: () async {
                    if (controller.value.isPlaying) {
                      await controller.pause();
                    } else {
                      await controller.play();
                    }
                    if (mounted) setState(() {});
                  },
                  icon: Icon(
                    controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                  ),
                ),
                Expanded(
                  child: VideoProgressIndicator(
                    controller,
                    allowScrubbing: true,
                    colors: VideoProgressColors(
                      playedColor: Theme.of(context).colorScheme.primary,
                      bufferedColor: Color(0x66888888),
                      backgroundColor: Color(0x33888888),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: controller.value.volume > 0 ? '静音' : '开启声音',
                  onPressed: () async {
                    await controller.setVolume(
                      controller.value.volume > 0 ? 0 : 1,
                    );
                    if (mounted) setState(() {});
                  },
                  icon: Icon(
                    controller.value.volume > 0
                        ? Icons.volume_up
                        : Icons.volume_off,
                  ),
                ),
              ],
            ),
          ],
        );
      },
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
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(height: 6),
                        Container(
                          constraints: BoxConstraints(
                            maxHeight: width < 600 ? 340 : 520,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: _mediaPreview(context),
                        ),
                        if (_error != null && !_asset.isVideo)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        const SizedBox(height: 18),
                        Text(
                          '媒体信息',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        _metadata(context),
                        if (widget.isAdmin) ...[
                          const SizedBox(height: 18),
                          const Divider(height: 1),
                          const SizedBox(height: 14),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              SizedBox(
                                width: width < 540 ? double.infinity : 260,
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
                                      : (value) => setState(
                                          () => _selectedAlbum = value,
                                        ),
                                ),
                              ),
                              OutlinedButton.icon(
                                onPressed: _busy || _selectedAlbum == null
                                    ? null
                                    : _addToAlbum,
                                icon: _busy
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
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
                                width: width < 540 ? double.infinity : 260,
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
                                      : (value) => setState(
                                          () => _selectedPrivateAlbum = value,
                                        ),
                                ),
                              ),
                              OutlinedButton.icon(
                                onPressed:
                                    _busy || _selectedPrivateAlbum == null
                                    ? null
                                    : _addToPrivateAlbum,
                                icon: const Icon(Icons.folder_special_outlined),
                                label: const Text('加入私人相册'),
                              ),
                              if (widget.currentPrivateAlbumId > 0)
                                OutlinedButton.icon(
                                  onPressed: _busy
                                      ? null
                                      : _removeFromPrivateAlbum,
                                  icon: const Icon(Icons.remove_circle_outline),
                                  label: const Text('移出此私人相册'),
                                ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '私人相册仅当前账号可见，不会影响共享收藏或原始文件。',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                        ] else if (widget.onAddToPrivateAlbum != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            '还没有私人相册。返回图库后可创建，仅当前账号可见。',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                        ],
                        if (_error != null && _asset.isVideo)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                      ],
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
