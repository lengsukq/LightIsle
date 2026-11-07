part of 'photos_page.dart';

extension _PhotosPageNavigation on _PhotosPageState {
  Future<void> _openPhotoMap() async {
    final selected = await Navigator.of(context).push<PhotoAsset>(
      MaterialPageRoute<PhotoAsset>(
        builder: (_) => PhotoMapPage(api: widget.api),
      ),
    );
    if (mounted && selected != null) await _openAsset(selected);
  }

  Future<void> _upload() async {
    final count = await openFileUpload(
      context,
      api: widget.api,
      isAdmin: widget.isAdmin,
      directory: widget.uploadDirectory,
      type: FileType.media,
      title: '上传照片与视频',
      taskCenter: widget.taskCenter,
      accountName: widget.accountName,
    );
    if (!mounted || count == 0) return;
    String? indexingError;
    if (widget.isAdmin && !_scanning) {
      await _startScan();
      if (_actionIsError) indexingError = _actionMessage;
    }
    if (!mounted) return;
    _updateState(() {
      _actionMessage =
          '已上传 $count 项。${indexingError == null ? '索引更新后会显示在全部照片中，可下拉刷新。' : '媒体整理暂未开始：$indexingError'}';
      _actionIsError = indexingError != null;
      _activeAlbum = 0;
      _activePrivateAlbum = 0;
      _activeFolderPath = '';
      _activeFolderName = '';
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

  void _photoAction(String value) {
    switch (value) {
      case 'select':
        _updateState(() {
          _selecting = !_selecting;
          _selectedAssets.clear();
        });
      case 'map':
        _openPhotoMap();
      case 'offline':
        if (widget.offlineAccountId.isEmpty) {
          _updateState(
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
        _updateState(() => _mediaType = value == 'all' ? '' : value);
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
                      _activeFolderPath.isEmpty &&
                      !_favoritesOnly &&
                      !_personalFavoritesOnly &&
                      !_onThisDay,
                  onSelected: () => _selectView(),
                ),
                if (_fullTimelineSelected) ...[
                  const SizedBox(width: 8),
                  ActionChip(
                    tooltip: '快速跳转到指定拍摄年月',
                    avatar: const Icon(Icons.calendar_month_outlined, size: 18),
                    label: const Text('年月'),
                    onPressed: _chooseTimelineMonth,
                  ),
                ],
                const SizedBox(width: 8),
                _filterChip(
                  label: _activeFolderName.isNotEmpty
                      ? _activeFolderName
                      : selectedAlbum == null
                      ? '相册'
                      : selectedAlbum.name,
                  selected:
                      selectedAlbum != null || _activeFolderPath.isNotEmpty,
                  icon: Icons.photo_album_outlined,
                  onSelected: _browseAlbums,
                ),
                const SizedBox(width: 8),
                _filterChip(
                  label: '我的收藏',
                  icon: Icons.star_outline,
                  selected: _personalFavoritesOnly,
                  onSelected: () => _selectView(personalFavorites: true),
                ),
                const SizedBox(width: 8),
                ActionChip(
                  tooltip: '按相机型号、定位、年份筛选',
                  avatar: const Icon(Icons.tune_rounded, size: 18),
                  label: const Text('筛选'),
                  onPressed: _openExifFilterSheet,
                ),
                if (_cameraFilter.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  InputChip(
                    label: Text(_cameraFilter),
                    onDeleted: () {
                      _updateState(() => _cameraFilter = '');
                      _loadAssets(reset: true);
                    },
                  ),
                ],
                if (_locationFilter.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  InputChip(
                    label: Text(_locationFilter == '1' ? '含定位' : '无定位'),
                    onDeleted: () {
                      _updateState(() => _locationFilter = '');
                      _loadAssets(reset: true);
                    },
                  ),
                ],
                if (_yearFilter > 0) ...[
                  const SizedBox(width: 8),
                  InputChip(
                    label: Text('$_yearFilter 年'),
                    onDeleted: () {
                      _updateState(() => _yearFilter = 0);
                      _loadAssets(reset: true);
                    },
                  ),
                ],
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
                      _updateState(() => _mediaType = '');
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
                    _updateState(() => _query = value.trim());
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
                      _updateState(() {
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

  Future<void> _openExifFilterSheet() async {
    if (_facetCameras.isEmpty && _facetYears.isEmpty) {
      await _refreshFacets();
    }
    if (!mounted) return;
    var cam = _cameraFilter;
    var loc = _locationFilter;
    var yr = _yearFilter;
    final applied = await showModalBottomSheet<bool>(
      context: context,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('多维筛选', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                if (_facetCameras.isNotEmpty)
                  DropdownButtonFormField<String>(
                    initialValue: cam,
                    decoration: const InputDecoration(labelText: '相机型号'),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('全部相机')),
                      for (final model in _facetCameras)
                        DropdownMenuItem(value: model, child: Text(model)),
                    ],
                    onChanged: (v) => setSheetState(() => cam = v ?? ''),
                  ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: loc,
                  decoration: const InputDecoration(labelText: '地理位置'),
                  items: const [
                    DropdownMenuItem(value: '', child: Text('全部位置')),
                    DropdownMenuItem(value: '1', child: Text('含定位')),
                    DropdownMenuItem(value: '0', child: Text('无定位')),
                  ],
                  onChanged: (v) => setSheetState(() => loc = v ?? ''),
                ),
                if (_facetYears.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: yr,
                    decoration: const InputDecoration(labelText: '拍摄年份'),
                    items: [
                      const DropdownMenuItem(value: 0, child: Text('全部年份')),
                      for (final y in _facetYears)
                        DropdownMenuItem(value: y, child: Text('$y 年')),
                    ],
                    onChanged: (v) => setSheetState(() => yr = v ?? 0),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () {
                        cam = '';
                        loc = '';
                        yr = 0;
                        Navigator.pop(sheetContext, true);
                      },
                      child: const Text('重置'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.pop(sheetContext, true),
                      child: const Text('应用筛选'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (applied == true && mounted) {
      _updateState(() {
        _cameraFilter = cam;
        _locationFilter = loc;
        _yearFilter = yr;
      });
      await _loadAssets(reset: true);
    }
  }
}
