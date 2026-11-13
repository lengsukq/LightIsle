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
    required VoidCallback? onPressed,
    Color color = Colors.white,
    double width = 44,
    double height = 44,
    double iconSize = 22,
  }) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    color: color,
    disabledColor: color.withValues(alpha: 0.45),
    padding: EdgeInsets.zero,
    constraints: BoxConstraints.tightFor(width: width, height: height),
    style: IconButton.styleFrom(
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    iconSize: iconSize,
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

  Widget _viewerSettingsMenu({double size = 44, double iconSize = 21}) =>
      PopupMenuButton<String>(
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
        child: SizedBox(
          height: size,
          width: size,
          child: Icon(Icons.tune_rounded, color: Colors.white, size: iconSize),
        ),
      );

  /// Shared action icons rendered in the bottom pill for photos or collapsed into
  /// the top header pill for videos so the video control bar stays unobstructed.
  List<Widget> _buildMediaActionButtons(
    PhotoAsset asset, {
    double buttonSize = 44,
    double iconSize = 22,
  }) => [
    if (!widget.fileBrowserMode)
      _toolbarIcon(
        tooltip: asset.personalFavorite ? '从我的收藏移除' : '加入我的收藏',
        icon: asset.personalFavorite
            ? Icons.star_rounded
            : Icons.star_border_rounded,
        color: asset.personalFavorite ? const Color(0xffffd568) : Colors.white,
        width: buttonSize,
        height: buttonSize,
        iconSize: iconSize,
        onPressed: _busy ? null : () => _favorite(shared: false),
      ),
    if (!widget.fileBrowserMode)
      _toolbarIcon(
        tooltip: '照片信息与相册管理',
        icon: Icons.info_outline_rounded,
        color: _showInfoSidebar ? const Color(0xFF9CDCF5) : Colors.white,
        width: buttonSize,
        height: buttonSize,
        iconSize: iconSize,
        onPressed: _busy ? null : () => _inspectAsset(context),
      ),
    _toolbarIcon(
      tooltip: '分享媒体',
      icon: Icons.ios_share_outlined,
      width: buttonSize,
      height: buttonSize,
      iconSize: iconSize,
      onPressed: _busy ? null : _shareCurrent,
    ),
    PopupMenuButton<String>(
      tooltip: '更多媒体操作',
      enabled: !_busy,
      padding: EdgeInsets.zero,
      onSelected: (value) => unawaited(_mediaAction(value)),
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'export', child: Text('保存原文件')),
        if (!widget.fileBrowserMode && widget.onFolderAlbum != null)
          const PopupMenuItem(value: 'folder', child: Text('复制或移动到相册')),
        if (!widget.fileBrowserMode && widget.canEditSharedFavorite(asset))
          PopupMenuItem(
            value: 'shared',
            child: Text(asset.favorite ? '取消共享收藏' : '加入共享收藏'),
          ),
        if (!asset.isVideo && widget.offlineAccountId.isNotEmpty)
          const PopupMenuItem(value: 'offline', child: Text('离线保存照片原件')),
        if (_hasLiveMotion && !asset.isVideo)
          PopupMenuItem(
            value: 'live',
            child: Text(
              _livePlaying ? '返回 Live Photo 静态照片' : '播放 Live Photo 动态片段',
            ),
          ),
        if (!widget.fileBrowserMode && widget.onRemoveFromCurrentAlbum != null)
          PopupMenuItem(
            value: 'remove_album',
            child: Text(
              widget.currentAlbumName.isNotEmpty
                  ? '从“${widget.currentAlbumName}”移出（保留原片）'
                  : '从当前相册移出（保留原片）',
            ),
          ),
        if (!widget.fileBrowserMode &&
            widget.onDelete != null &&
            widget.canEditSharedFavorite(asset))
          const PopupMenuItem(value: 'trash', child: Text('将原文件移入回收站')),
      ],
      child: SizedBox(
        width: buttonSize,
        height: buttonSize,
        child: Icon(
          Icons.more_horiz_rounded,
          color: _busy ? Colors.white.withValues(alpha: 0.45) : Colors.white,
          size: iconSize,
        ),
      ),
    ),
  ];

  Widget _buildModernHeader(PhotoAsset asset, double safeTop) {
    final isMacOS =
        defaultTargetPlatform == TargetPlatform.macOS ||
        Theme.of(context).platform == TargetPlatform.macOS;
    final leftInset = isMacOS ? 80.0 : 14.0;
    final availableWidth = MediaQuery.sizeOf(context).width - leftInset - 14;
    final compactVideoHeader = asset.isVideo && availableWidth < 360;
    final btnSize = compactVideoHeader ? 36.0 : 44.0;
    final iconSize = compactVideoHeader ? 20.0 : 22.0;
    final gap = compactVideoHeader ? 6.0 : 8.0;
    final subtitle = asset.isVideo
        ? '${asset.name} · ${_index + 1} / ${_items.length}'
        : '${_index + 1} / ${_items.length}';
    return Padding(
      padding: EdgeInsets.fromLTRB(leftInset, safeTop + 10, 14, 30),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              DecoratedBox(
                decoration: _toolbarDecoration,
                child: _toolbarIcon(
                  tooltip: widget.fileBrowserMode ? '返回文件' : '返回图库',
                  icon: Icons.arrow_back_rounded,
                  width: btnSize,
                  height: btnSize,
                  iconSize: iconSize,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              SizedBox(width: gap),
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
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xBFFFFFFF),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: gap),
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
                key: asset.isVideo
                    ? const Key('photoViewerVideoHeaderActions')
                    : null,
                decoration: _toolbarDecoration,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.fileBrowserMode) ...[
                      _toolbarIcon(
                        tooltip: '播放列表',
                        icon: Icons.playlist_play_rounded,
                        width: btnSize,
                        height: btnSize,
                        iconSize: iconSize,
                        onPressed: _showFilePlaylist,
                      ),
                      _viewerSettingsMenu(
                        size: btnSize,
                        iconSize: iconSize - 1,
                      ),
                    ] else if (!asset.isVideo) ...[
                      _slideToggleButton(),
                      _viewerSettingsMenu(
                        size: btnSize,
                        iconSize: iconSize - 1,
                      ),
                    ],
                    if (asset.isVideo)
                      ..._buildMediaActionButtons(
                        asset,
                        buttonSize: btnSize,
                        iconSize: iconSize,
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (asset.isVideo && _error != null) ...[
            const SizedBox(height: 8),
            DecoratedBox(
              decoration: _toolbarDecoration,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xffffb4ab),
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBottomToolbar(
    BuildContext context,
    PhotoAsset asset,
    double safeBottom,
  ) {
    if (asset.isVideo) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 8, 14, safeBottom + 14),
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
          if (_items.length > 1) ...[
            PhotoGalleryViewerFilmstrip(
              api: widget.api,
              memoryCache: _imageCache,
              items: _items,
              currentIndex: _index,
              fileBrowserMode: widget.fileBrowserMode,
              onSelectIndex: (target) {
                if (target == _index) return;
                unawaited(_navigate(target - _index));
              },
            ),
            const SizedBox(height: 8),
          ],
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
                      children: _buildMediaActionButtons(asset),
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
}
