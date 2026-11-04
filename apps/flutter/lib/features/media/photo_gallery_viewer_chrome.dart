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

  Widget _buildModernHeader(PhotoAsset asset, double safeTop) => Padding(
    padding: EdgeInsets.fromLTRB(14, safeTop + 10, 14, 30),
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
                style: const TextStyle(color: Color(0xBFFFFFFF), fontSize: 11),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
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
