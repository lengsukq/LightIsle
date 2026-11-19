import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/widgets.dart';

/// Shared visual tokens, subtitle overlay, and responsive glass transport dock
/// reused across Cinema, Gallery/File-Browser video playback, and LocalVideoPage.
abstract final class SharedVideoPlayerStyle {
  static const Color crimsonAccent = Color(0xFFE50914);

  static const TextStyle tabularTimeStyle = TextStyle(
    color: Colors.white,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    fontFeatures: [ui.FontFeature.tabularFigures()],
  );

  static ButtonStyle compactTransportIconStyle() {
    final touch =
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android;
    return IconButton.styleFrom(
      foregroundColor: Colors.white,
      disabledForegroundColor: Colors.white38,
      hoverColor: const Color(0x24FFFFFF),
      padding: EdgeInsets.all(touch ? 8 : 6),
      minimumSize: Size(touch ? 44 : 34, touch ? 44 : 34),
      tapTargetSize: touch
          ? MaterialTapTargetSize.padded
          : MaterialTapTargetSize.shrinkWrap,
    );
  }

  static String formatClock(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  static String formatSpeedLabel(double speed) {
    if (speed == 1.0) return '1.0x';
    final text = speed
        .toStringAsFixed(2)
        .replaceAll(RegExp(r'0+$'), '')
        .replaceAll(RegExp(r'\.$'), '');
    return '${text}x';
  }

  static bool isCompactWidth(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    return screenWidth < 640 || MediaQuery.textScalerOf(context).scale(14) > 20;
  }
}

PopupMenuItem<T> buildSharedPlayerPopupChoice<T>({
  required T value,
  required String label,
  required bool selected,
}) => PopupMenuItem<T>(
  value: value,
  height: 36,
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        Icons.check_rounded,
        size: 16,
        color: selected
            ? SharedVideoPlayerStyle.crimsonAccent
            : Colors.transparent,
      ),
      const SizedBox(width: 8),
      Flexible(
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : const Color(0xD9FFFFFF),
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    ],
  ),
);

class SharedPlayerMenuPill<T> extends StatelessWidget {
  const SharedPlayerMenuPill({
    super.key,
    required this.label,
    required this.tooltip,
    required this.items,
    required this.onSelected,
    this.icon,
    this.active = false,
    this.enabled = true,
  });

  final String label;
  final String tooltip;
  final List<PopupMenuEntry<T>> items;
  final ValueChanged<T> onSelected;
  final IconData? icon;
  final bool active;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      tooltip: tooltip,
      enabled: enabled,
      color: const Color(0xF2161A24),
      surfaceTintColor: Colors.transparent,
      elevation: 16,
      position: PopupMenuPosition.over,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0x2EFFFFFF), width: 0.8),
      ),
      onSelected: onSelected,
      itemBuilder: (_) => items,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: active ? const Color(0x38FFFFFF) : const Color(0x1FFFFFFF),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active ? const Color(0x4DFFFFFF) : const Color(0x24FFFFFF),
            width: 0.75,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: Colors.white70),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                height: 1.1,
              ),
            ),
            const SizedBox(width: 2),
            const Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 15,
              color: Colors.white70,
            ),
          ],
        ),
      ),
    );
  }
}

class SharedPlayerSpeedMenuPill extends StatelessWidget {
  const SharedPlayerSpeedMenuPill({
    super.key,
    required this.value,
    required this.onSelected,
    this.speeds = const <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0],
  });

  final double value;
  final ValueChanged<double> onSelected;
  final List<double> speeds;

  @override
  Widget build(BuildContext context) {
    return SharedPlayerMenuPill<double>(
      label: SharedVideoPlayerStyle.formatSpeedLabel(value),
      tooltip: '播放倍速',
      active: (value - 1.0).abs() > 0.01,
      onSelected: onSelected,
      items: [
        for (final speed in speeds)
          buildSharedPlayerPopupChoice<double>(
            value: speed,
            label: '${SharedVideoPlayerStyle.formatSpeedLabel(speed)}${speed == 1.0 ? ' (正常)' : ''}',
            selected: (value - speed).abs() < 0.01,
          ),
      ],
    );
  }
}

class SharedVideoProgressBar extends StatelessWidget {
  const SharedVideoProgressBar({super.key, required this.controller});

  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: VideoProgressIndicator(
        controller,
        allowScrubbing: true,
        padding: const EdgeInsets.symmetric(vertical: 5),
        colors: const VideoProgressColors(
          playedColor: SharedVideoPlayerStyle.crimsonAccent,
          bufferedColor: Color(0x59FFFFFF),
          backgroundColor: Color(0x2EFFFFFF),
        ),
      ),
    );
  }
}

class SharedVideoSubtitleOverlay extends StatelessWidget {
  const SharedVideoSubtitleOverlay({
    super.key,
    required this.text,
    this.fontSize = 16,
  });

  final String text;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.76),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: fontSize,
              height: 1.3,
              fontWeight: FontWeight.w500,
              shadows: const [
                Shadow(
                  color: Colors.black,
                  blurRadius: 4,
                  offset: Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SharedVideoTransportDeck extends StatelessWidget {
  const SharedVideoTransportDeck({
    super.key,
    required this.seekBar,
    required this.playing,
    required this.onTogglePlay,
    required this.onSeekBackward,
    required this.onSeekForward,
    required this.muted,
    required this.volume,
    required this.onToggleMute,
    this.controller,
    this.timeReadout,
    this.currentTimeLabel,
    this.totalTimeLabel,
    this.onVolumeChanged,
    this.busy = false,
    this.showPrevNext = false,
    this.prevKey,
    this.nextKey,
    this.onPrev,
    this.onNext,
    this.headerRow,
    this.rightClusterItems = const <Widget>[],
    this.wrapInSafeArea = true,
    this.outerPadding,
    this.maxWidth = 920,
    this.buttonStyle,
  });

  final Widget seekBar;
  final bool playing;
  final VideoPlayerController? controller;
  final Widget? timeReadout;
  final String? currentTimeLabel;
  final String? totalTimeLabel;
  final VoidCallback? onTogglePlay;
  final VoidCallback? onSeekBackward;
  final VoidCallback? onSeekForward;
  final bool muted;
  final double volume;
  final VoidCallback onToggleMute;
  final ValueChanged<double>? onVolumeChanged;
  final bool busy;
  final bool showPrevNext;
  final Key? prevKey;
  final Key? nextKey;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final Widget? headerRow;
  final List<Widget> rightClusterItems;
  final bool wrapInSafeArea;
  final EdgeInsetsGeometry? outerPadding;
  final double maxWidth;
  final ButtonStyle? buttonStyle;

  Widget _buildClockText(String current, String total) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(current, style: SharedVideoPlayerStyle.tabularTimeStyle),
        const Text(
          ' / ',
          style: TextStyle(color: Color(0x80FFFFFF), fontSize: 11.5),
        ),
        Text(
          total,
          style: SharedVideoPlayerStyle.tabularTimeStyle.copyWith(
            color: const Color(0xB3FFFFFF),
          ),
        ),
      ],
    );
  }

  Widget _buildResolvedTimeReadout() {
    if (timeReadout != null) return timeReadout!;
    final player = controller;
    if (player != null) {
      return RepaintBoundary(
        child: ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: player,
          builder: (_, value, _) => _buildClockText(
            SharedVideoPlayerStyle.formatClock(value.position),
            SharedVideoPlayerStyle.formatClock(value.duration),
          ),
        ),
      );
    }
    return _buildClockText(
      currentTimeLabel ?? '00:00',
      totalTimeLabel ?? '00:00',
    );
  }

  @override
  Widget build(BuildContext context) {
    final compactControls = SharedVideoPlayerStyle.isCompactWidth(context);
    final resolvedButtonStyle =
        buttonStyle ?? SharedVideoPlayerStyle.compactTransportIconStyle();
    final leftCluster = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: playing ? '暂停' : '播放',
            style: resolvedButtonStyle,
            onPressed: onTogglePlay,
            icon: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 24,
            ),
          ),
          if (showPrevNext) ...[
            IconButton(
              key: prevKey,
              tooltip: '上一部',
              style: resolvedButtonStyle,
              onPressed: busy ? null : onPrev,
              icon: const Icon(Icons.skip_previous_rounded, size: 21),
            ),
            IconButton(
              key: nextKey,
              tooltip: '下一部',
              style: resolvedButtonStyle,
              onPressed: busy ? null : onNext,
              icon: const Icon(Icons.skip_next_rounded, size: 21),
            ),
          ],
          const SizedBox(width: 2),
          IconButton(
            tooltip: '快退 10 秒',
            style: resolvedButtonStyle,
            onPressed: busy ? null : onSeekBackward,
            icon: const Icon(Icons.replay_10_rounded, size: 19),
          ),
          IconButton(
            tooltip: '快进 10 秒',
            style: resolvedButtonStyle,
            onPressed: busy ? null : onSeekForward,
            icon: const Icon(Icons.forward_10_rounded, size: 19),
          ),
          const SizedBox(width: 2),
          IconButton(
            tooltip: muted || volume == 0 ? '取消静音' : '静音',
            style: resolvedButtonStyle,
            onPressed: onToggleMute,
            icon: Icon(
              muted || volume == 0
                  ? Icons.volume_off_rounded
                  : Icons.volume_up_rounded,
              size: 18,
            ),
          ),
          if (!compactControls && onVolumeChanged != null)
            Semantics(
              label: '音量',
              child: SizedBox(
                width: 78,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2.8,
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: const Color(0x40FFFFFF),
                    thumbColor: Colors.white,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 4.5,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 9,
                    ),
                  ),
                  child: Slider(
                    value: volume.clamp(0.0, 1.0),
                    min: 0.0,
                    max: 1.0,
                    onChanged: onVolumeChanged,
                  ),
                ),
              ),
            ),
          const SizedBox(width: 8),
          _buildResolvedTimeReadout(),
        ],
      ),
    );

    final rightCluster = Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: rightClusterItems,
    );

    final deckBody = FocusScope(
      canRequestFocus: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?headerRow,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: seekBar,
          ),
          const SizedBox(height: 2),
          Wrap(
            spacing: compactControls ? 8 : 12,
            runSpacing: 6,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [leftCluster, rightCluster],
          ),
        ],
      ),
    );

    final shell = Padding(
      padding:
          outerPadding ??
          EdgeInsets.fromLTRB(
            compactControls ? 12 : 24,
            8,
            compactControls ? 12 : 24,
            compactControls ? 10 : 16,
          ),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: DecoratedBox(
            decoration: const BoxDecoration(
              borderRadius: BorderRadius.all(Radius.circular(16)),
              boxShadow: [
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 24,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: IsleGlassBackdrop(
                blur: 24,
                child: Container(
                  padding: EdgeInsets.fromLTRB(
                    compactControls ? 10 : 14,
                    headerRow != null ? 4 : 8,
                    compactControls ? 10 : 14,
                    8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xB80E121A),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: const Color(0x26FFFFFF),
                      width: 0.8,
                    ),
                  ),
                  child: deckBody,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    if (!wrapInSafeArea) return shell;
    return SafeArea(top: false, child: shell);
  }
}
