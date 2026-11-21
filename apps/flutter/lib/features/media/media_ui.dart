import 'package:flutter/material.dart';

import '../../core/isle_ui.dart';
import '../../core/user_facing_error.dart';
import 'shared_video_player_controls.dart';

String mediaErrorLabel(Object error) => userFacingError(error);

/// Unified selection bar for photos and films, backed by [IsleSelectionBar].
class MediaSelectionActionBar extends StatelessWidget {
  const MediaSelectionActionBar({
    super.key,
    required this.label,
    required this.actions,
  });

  final String label;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => IsleSelectionBar(
    key: const ValueKey('mediaSelectionActionBar'),
    label: label,
    actions: actions,
  );
}

/// One set of playback speeds and one accessible pill menu shared by gallery
/// videos, cinema and local-video playback.
class MediaPlaybackSpeedPicker extends StatelessWidget {
  const MediaPlaybackSpeedPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.speeds = defaultSpeeds,
  });

  static const defaultSpeeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  final double value;
  final ValueChanged<double> onChanged;
  final List<double> speeds;

  @override
  Widget build(BuildContext context) => SharedPlayerMenuPill<double>(
    label: SharedVideoPlayerStyle.formatSpeedLabel(value),
    tooltip: '播放倍速',
    active: (value - 1.0).abs() > 0.01,
    onSelected: onChanged,
    items: [
      for (final speed in speeds)
        buildSharedPlayerPopupChoice<double>(
          value: speed,
          label:
              '${SharedVideoPlayerStyle.formatSpeedLabel(speed)}${speed == 1.0 ? ' (正常)' : ''}',
          selected: (value - speed).abs() < 0.01,
        ),
    ],
  );
}

String formatMediaSize(int bytes) {
  if (bytes < 0) return '未知大小';
  if (bytes < 1024) return '$bytes B';
  const units = <String>['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unit]}';
}

String formatMediaSeconds(num seconds) {
  if (!seconds.isFinite || seconds <= 0) return '时长未知';
  final duration = Duration(seconds: seconds.round());
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  if (hours > 0) return '$hours小时$minutes分';
  if (duration.inSeconds < 60) {
    return duration.inSeconds == 0 ? '不足 1 秒' : '${duration.inSeconds} 秒';
  }
  return '${duration.inMinutes} 分钟';
}

String formatMediaDate(int unixSeconds) {
  if (unixSeconds <= 0) return '拍摄时间未知';
  final value = DateTime.fromMillisecondsSinceEpoch(
    unixSeconds * 1000,
  ).toLocal();
  return '${value.year}年${value.month}月${value.day}日';
}

String formatMediaMonth(int unixSeconds) {
  if (unixSeconds <= 0) return '日期未知';
  final value = DateTime.fromMillisecondsSinceEpoch(
    unixSeconds * 1000,
  ).toLocal();
  return '${value.year}年${value.month}月';
}

/// Crisp capsule pill filter chip shared by the photo and cinema libraries.
class MediaFilterChip extends StatelessWidget {
  const MediaFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.icon,
    this.onDeleted,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;
  final IconData? icon;
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final palette = IslePalette(dark);
    final maxLabelWidth = (MediaQuery.sizeOf(context).width * .58)
        .clamp(160.0, 300.0)
        .toDouble();
    final avatarWidget = icon == null
        ? null
        : Icon(
            icon,
            size: 15,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          );
    final labelWidget = Tooltip(
      message: label,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxLabelWidth),
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
    final selectedBg = scheme.primary.withValues(alpha: dark ? .22 : .12);
    final bg = dark
        ? Colors.white.withValues(alpha: 0.06)
        : palette['cardTop'].withValues(alpha: 0.95);
    const chipShape = StadiumBorder();
    final chipSide = BorderSide(
      color: selected
          ? scheme.primary.withValues(alpha: dark ? .50 : .36)
          : IsleGlass.rimBorderColor(dark),
      width: 1.0,
    );
    final textStyle = TextStyle(
      fontSize: 12.5,
      color: selected ? scheme.primary : scheme.onSurface,
      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      letterSpacing: -0.1,
    );
    if (onDeleted != null) {
      return InputChip(
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        showCheckmark: false,
        avatar: avatarWidget,
        label: labelWidget,
        selected: selected,
        onPressed: onSelected,
        onDeleted: onDeleted,
        deleteIconColor: selected ? scheme.primary : scheme.onSurfaceVariant,
        deleteButtonTooltipMessage: '返回全部照片',
        selectedColor: selectedBg,
        backgroundColor: bg,
        shape: chipShape,
        side: chipSide,
        labelStyle: textStyle,
      );
    }
    return ChoiceChip(
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      showCheckmark: false,
      avatar: avatarWidget,
      label: labelWidget,
      selected: selected,
      onSelected: (_) => onSelected(),
      selectedColor: selectedBg,
      backgroundColor: bg,
      shape: chipShape,
      side: chipSide,
      labelStyle: textStyle,
    );
  }
}

class MediaStatusBanner extends StatelessWidget {
  const MediaStatusBanner({
    required this.message,
    this.icon = Icons.info_outline,
    this.leading,
    this.isError = false,
    this.trailing,
    this.diagnostic,
    super.key,
  });

  final String message;
  final IconData icon;
  final Widget? leading;
  final bool isError;
  final Widget? trailing;
  final String? diagnostic;

  @override
  Widget build(BuildContext context) {
    final inset = IsleLayout.pageInset(MediaQuery.sizeOf(context).width);
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, 0, inset, 8),
      child: Notice(
        message,
        icon: icon,
        leading: leading,
        error: isError,
        trailing: trailing,
        diagnostic: diagnostic,
      ),
    );
  }
}

class MediaEmptyState extends StatelessWidget {
  const MediaEmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final dense = viewport.width < 420 && viewport.height < 700;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        dense ? 12 : 16,
        dense ? 8 : 14,
        dense ? 12 : 16,
        dense ? 12 : 18,
      ),
      child: IsleEmptyStateCard(
        message,
        icon: icon,
        title: title,
        action: action,
        margin: EdgeInsets.zero,
      ),
    );
  }
}
