part of 'cinema_detail_dialog.dart';

extension _CinemaDetailPlayerMenus on _CinemaDetailDialogState {
  void _onCaptionMenuSelected(String value) {
    if (value == 'import') {
      unawaited(_importLocalSubtitles());
    } else if (value.startsWith('size:')) {
      final parsed = double.tryParse(value.substring(5));
      if (parsed != null) {
        _updateState(() => _subtitles.fontSize = parsed);
      }
    } else if (value.startsWith('offset:')) {
      final arg = value.substring(7);
      _updateState(() {
        if (arg == 'reset') {
          _subtitles.offsetSeconds = 0.0;
        } else {
          final delta = double.tryParse(arg) ?? 0.0;
          _subtitles.offsetSeconds = (_subtitles.offsetSeconds + delta).clamp(
            -10.0,
            10.0,
          );
        }
        final sign = _subtitles.offsetSeconds >= 0 ? '+' : '';
        _subtitles.message = _subtitles.offsetSeconds == 0.0
            ? '字幕时间偏移已重置'
            : '字幕时间偏移：$sign${_subtitles.offsetSeconds.toStringAsFixed(1)} 秒';
      });
    } else if (value != 'local') {
      unawaited(_loadSubtitles(value));
    }
  }

  List<PopupMenuEntry<String>> _buildCaptionMenuItems() {
    final lang = _subtitles.captionLanguage;
    return <PopupMenuEntry<String>>[
      _buildPopupChoice(value: 'off', label: '关闭字幕', selected: lang == 'off'),
      _buildPopupChoice(
        value: 'auto',
        label: '同名字幕',
        selected: lang == 'auto',
      ),
      _buildPopupChoice(value: 'zh', label: '中文字幕', selected: lang == 'zh'),
      _buildPopupChoice(value: 'en', label: '英文字幕', selected: lang == 'en'),
      if (lang == 'local')
        _buildPopupChoice(
          value: 'local',
          label: '本机字幕（当前）',
          selected: true,
        ),
      for (final track
          in _playback.tracks?.subtitles ?? const <CinemaSubtitleTrack>[])
        if (track.extractable)
          _buildPopupChoice(
            value: 'emb:${track.streamIndex}',
            label: track.label,
            selected: lang == 'emb:${track.streamIndex}',
          ),
      const PopupMenuDivider(height: 8),
      const PopupMenuItem<String>(
        value: 'import',
        height: 36,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open_rounded, size: 15, color: Colors.white70),
            SizedBox(width: 8),
            Text(
              '导入本机字幕…',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ],
        ),
      ),
      if (lang != 'off') ...[
        const PopupMenuDivider(height: 8),
        for (final (size, label) in const [
          (15.0, '字号：小'),
          (17.0, '字号：标准'),
          (21.0, '字号：大'),
          (25.0, '字号：特大'),
        ])
          _buildPopupChoice(
            value: 'size:$size',
            label: label,
            selected: _subtitles.fontSize == size,
          ),
        const PopupMenuDivider(height: 8),
        const PopupMenuItem<String>(
          value: 'offset:-0.5',
          height: 34,
          child: Text(
            '字幕提前 0.5 秒',
            style: TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
        const PopupMenuItem<String>(
          value: 'offset:+0.5',
          height: 34,
          child: Text(
            '字幕延后 0.5 秒',
            style: TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
        if (_subtitles.offsetSeconds != 0.0)
          PopupMenuItem<String>(
            value: 'offset:reset',
            height: 34,
            child: Text(
              '重置字幕偏移 (${_subtitles.offsetSeconds >= 0 ? '+' : ''}${_subtitles.offsetSeconds.toStringAsFixed(1)}s)',
              style: const TextStyle(color: Colors.white70, fontSize: 12.5),
            ),
          ),
      ],
    ];
  }

  Widget _buildCaptionMenuPill() {
    return _buildPlayerMenuPill<String>(
      icon: Icons.subtitles_outlined,
      label: _captionShortLabel,
      tooltip: '字幕与字号',
      active: _subtitles.captionLanguage != 'off',
      onSelected: _onCaptionMenuSelected,
      items: _buildCaptionMenuItems(),
    );
  }

  Widget _buildQualityMenuPill() {
    return _buildPlayerMenuPill<String>(
      label: _qualityShortLabel,
      tooltip: '清晰度',
      enabled: !_playback.transcodeStarting,
      onSelected: (value) => unawaited(_switchQuality(value)),
      items: <PopupMenuEntry<String>>[
        for (final option in _qualityOptions())
          _buildPopupChoice(
            value: option.$1,
            label: option.$2,
            selected: _currentQualityKey == option.$1,
          ),
      ],
    );
  }

  Widget _buildSpeedMenuPill() {
    return _buildPlayerMenuPill<double>(
      label: _speedShortLabel,
      tooltip: '播放倍速',
      active: _playback.playbackSpeed != 1.0,
      onSelected: (speed) => unawaited(_setPlaybackSpeed(speed)),
      items: <PopupMenuEntry<double>>[
        for (final speed in const [0.75, 1.0, 1.25, 1.5, 2.0])
          _buildPopupChoice(
            value: speed,
            label: speed == 1.0 ? '1.0x（正常）' : '${speed}x',
            selected: _playback.playbackSpeed == speed,
          ),
      ],
    );
  }

  Widget _buildAudioTrackMenuPill() {
    final session = _playback.hlsSession;
    return _buildPlayerMenuPill<int>(
      icon: Icons.graphic_eq_rounded,
      label: _audioShortLabel,
      tooltip: '音轨切换',
      onSelected: (value) => unawaited(_switchAudio(value)),
      items: <PopupMenuEntry<int>>[
        for (final track
            in _playback.tracks?.audio ?? const <CinemaAudioTrack>[])
          _buildPopupChoice(
            value: track.audioIndex,
            label: track.label,
            selected: session?.audioTrack == track.audioIndex,
          ),
      ],
    );
  }
}
