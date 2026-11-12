part of 'photo_gallery_viewer.dart';

extension _PhotoGalleryViewerChrome on _PhotoGalleryViewerState {
  BoxDecoration get _toolbarDecoration => BoxDecoration(
    color: const Color(0xA51A2533),
    borderRadius: BorderRadius.circular(18),
    border: Border.all(color: const Color(0x36FFFFFF), width: .75),
  );

  Widget _toolbarIcon({
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
  }) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    color: Colors.white,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 44, height: 44),
    iconSize: 22,
    icon: Icon(icon),
  );

  Widget _slideToggleButton() {
    if (_slideshow) {
      return AnimatedBuilder(
        animation: _slideProgress,
        builder: (context, _) {
          final remaining = (_slideSeconds * (1 - _slideProgress.value))
              .ceil()
              .clamp(0, _slideSeconds);
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 44,
                height: 44,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: CircularProgressIndicator(
                          key: const Key('slideshowCountdownRing'),
                          value: _slideProgress.value,
                          backgroundColor: const Color(0x42FFFFFF),
                          color: const Color(0xFF9CDCF5),
                          strokeWidth: 2.5,
                          strokeCap: StrokeCap.round,
                        ),
                      ),
                    ),
                    _toolbarIcon(
                      tooltip: '暂停幻灯片',
                      icon: Icons.pause_rounded,
                      onPressed: _toggleSlideshow,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 7),
                child: Text(
                  '${remaining}s',
                  key: const Key('slideshowCountdownLabel'),
                  semanticsLabel: '距离下一张照片还有 $remaining 秒',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          );
        },
      );
    }
    return _toolbarIcon(
      tooltip: '播放幻灯片',
      icon: Icons.play_arrow_rounded,
      onPressed: _toggleSlideshow,
    );
  }

  Widget _viewerSettingsMenu() => PopupMenuButton<String>(
    tooltip: widget.fileBrowserMode ? '视频连续播放' : '幻灯片设置',
    padding: EdgeInsets.zero,
    onSelected: (value) {
      if (widget.fileBrowserMode) {
        _updateState(() => _continuousVideo = !_continuousVideo);
      } else if (value == 'loop') {
        _updateState(() => _loop = !_loop);
      } else {
        _updateState(() => _slideSeconds = int.parse(value));
      }
      _scheduleSlide();
    },
    itemBuilder: (_) => widget.fileBrowserMode
        ? [
            CheckedPopupMenuItem<String>(
              value: 'continuous',
              checked: _continuousVideo,
              child: const Text('视频播完自动播放下一个'),
            ),
          ]
        : [
            for (final seconds in [3, 5, 10])
              CheckedPopupMenuItem<String>(
                value: '$seconds',
                checked: _slideSeconds == seconds,
                child: Text('每 $seconds 秒切换'),
              ),
            CheckedPopupMenuItem<String>(
              value: 'loop',
              checked: _loop,
              child: const Text('循环播放'),
            ),
            const PopupMenuItem<String>(
              enabled: false,
              child: Text('幻灯片自动跳过视频'),
            ),
          ],
    child: const SizedBox(
      height: 44,
      width: 44,
      child: Icon(Icons.tune_rounded, color: Colors.white, size: 21),
    ),
  );

  Widget _buildModernHeader(PhotoAsset asset, double safeTop) {
    final isMacOS =
        defaultTargetPlatform == TargetPlatform.macOS ||
        Theme.of(context).platform == TargetPlatform.macOS;
    final leftInset = isMacOS ? 80.0 : 14.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(leftInset, safeTop + 10, 14, 30),
      child: Row(
        children: [
          DecoratedBox(
            decoration: _toolbarDecoration,
            child: _toolbarIcon(
              tooltip: widget.fileBrowserMode ? '返回文件' : '返回图库',
              icon: Icons.arrow_back_rounded,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatMediaDate(asset.takenAt),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_index + 1} / ${_items.length}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xBFFFFFFF),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (_hasLiveMotion && !asset.isVideo) ...[
            DecoratedBox(
              decoration: _toolbarDecoration,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: _livePlaying
                      ? const Color(0xFFFFD568)
                      : Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: const Size(0, 40),
                ),
                onPressed: () {
                  _stopSlideshow();
                  _updateState(() => _livePlaying = !_livePlaying);
                },
                icon: const Icon(Icons.motion_photos_on_rounded, size: 17),
                label: Text(
                  _livePlaying ? '实况播放中' : 'LIVE',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          DecoratedBox(
            decoration: _toolbarDecoration,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.fileBrowserMode)
                  _toolbarIcon(
                    tooltip: '播放列表',
                    icon: Icons.playlist_play_rounded,
                    onPressed: _showFilePlaylist,
                  )
                else
                  _slideToggleButton(),
                _viewerSettingsMenu(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomToolbar(PhotoAsset asset, double safeBottom) => Padding(
    padding: EdgeInsets.fromLTRB(14, 12, 14, safeBottom + 16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xffffb4ab)),
            ),
          ),
        Text(
          asset.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xCCFFFFFF),
            fontSize: 12,
            shadows: [Shadow(color: Color(0xD9000000), blurRadius: 8)],
          ),
        ),
        const SizedBox(height: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ClipRRect(
            key: const Key('photoViewerBottomToolbar'),
            borderRadius: BorderRadius.circular(18),
            child: IsleGlassBackdrop(
              blur: 12,
              child: DecoratedBox(
                decoration: _toolbarDecoration,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 2,
                    runSpacing: 0,
                    children: [
                      if (!widget.fileBrowserMode)
                        IconButton(
                          tooltip: asset.personalFavorite
                              ? '从我的收藏移除'
                              : '加入我的收藏',
                          onPressed: _busy
                              ? null
                              : () => _favorite(shared: false),
                          color: asset.personalFavorite
                              ? const Color(0xffffd568)
                              : Colors.white,
                          icon: Icon(
                            asset.personalFavorite
                                ? Icons.star_rounded
                                : Icons.star_border_rounded,
                          ),
                        ),
                      if (!widget.fileBrowserMode)
                        IconButton(
                          tooltip: '照片信息与相册管理',
                          onPressed: _busy
                              ? null
                              : () async {
                                  _stopSlideshow();
                                  final currentId = _current.id;
                                  await widget.onDetails(_current);
                                  if (!mounted || widget.onSyncAsset == null) {
                                    return;
                                  }
                                  final synced = widget.onSyncAsset!(currentId);
                                  if (synced == null) {
                                    _removeCurrentItem();
                                  } else {
                                    final idx = _items.indexWhere(
                                      (item) => item.id == currentId,
                                    );
                                    if (idx >= 0) {
                                      _updateState(() => _items[idx] = synced);
                                    }
                                  }
                                },
                          color: Colors.white,
                          icon: const Icon(Icons.info_outline_rounded),
                        ),
                      IconButton(
                        tooltip: '分享媒体',
                        onPressed: _busy ? null : _shareCurrent,
                        color: Colors.white,
                        icon: const Icon(Icons.ios_share_outlined),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '更多媒体操作',
                        enabled: !_busy,
                        icon: const Icon(
                          Icons.more_horiz_rounded,
                          color: Colors.white,
                        ),
                        onSelected: (value) => unawaited(_mediaAction(value)),
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'export',
                            child: Text('保存原文件'),
                          ),
                          if (!widget.fileBrowserMode &&
                              widget.onFolderAlbum != null)
                            const PopupMenuItem(
                              value: 'folder',
                              child: Text('复制或移动到相册'),
                            ),
                          if (!widget.fileBrowserMode &&
                              widget.canEditSharedFavorite(asset))
                            PopupMenuItem(
                              value: 'shared',
                              child: Text(asset.favorite ? '取消共享收藏' : '加入共享收藏'),
                            ),
                          if (!asset.isVideo &&
                              widget.offlineAccountId.isNotEmpty)
                            const PopupMenuItem(
                              value: 'offline',
                              child: Text('离线保存照片原件'),
                            ),
                          if (_hasLiveMotion)
                            PopupMenuItem(
                              value: 'live',
                              child: Text(
                                _livePlaying
                                    ? '返回 Live Photo 静态照片'
                                    : '播放 Live Photo 动态片段',
                              ),
                            ),
                          if (!widget.fileBrowserMode &&
                              widget.onDelete != null &&
                              widget.canEditSharedFavorite(asset))
                            const PopupMenuItem(
                              value: 'trash',
                              child: Text('将原文件移入回收站'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
