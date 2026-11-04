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
}
