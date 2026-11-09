import 'package:flutter/material.dart';

import '../../core/isle_ui.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';

String mediaErrorLabel(Object error) {
  final rawCode = error is LightIsleApiException
      ? error.code
      : error.toString();
  final code = rawCode.replaceFirst(RegExp(r'^(Exception|StateError):\s*'), '');
  const labels = <String, String>{
    'authentication_required': '登录状态已失效，请重新登录。',
    'file_permission_denied': '当前账号没有查看此媒体的权限。',
    'scan_running': '扫描正在进行，请等待完成。',
    'scan_already_running': '扫描正在进行，请等待完成。',
    'scan_directory_changed': '检查期间目录发生变化，结果尚未核对完成。文件未删除，请在文件操作结束后重新检查。',
    'cancelled': '检查已取消，结果尚未核对完成；可重新检查。',
    'media_worker_unavailable': '媒体预览服务暂时不可用，请稍后重试。',
    'invalid_request': '请求内容无效，请检查后重试。',
    'invalid_asset': '此媒体已不可用，请刷新图库后重试。',
    'invalid_progress': '播放进度无效，请重新播放后再试。',
    'preview_not_supported': '此媒体格式无法在内置预览中播放。',
    'storage_unavailable': '文件存储暂时不可用，请稍后重试。',
    'file_not_found': '此文件已不存在，请刷新后重试。',
    'response_too_large': '媒体响应过大，当前无法预览。',
    'network_error': '无法连接服务器，请检查网络后重试。',
    'network_timeout': '连接服务器超时，请检查网络后重试。',
    'gallery_failed': '图库请求失败，请稍后重试。',
    'cinema_failed': '影视库请求失败，请稍后重试。',
    'album_name_exists': '已有同名相册，请更换名称。',
    'private_album_limit': '私人相册数量已达到当前上限。',
    'invalid_album_name': '相册名称需为 1–60 个字符，且不能包含控制字符。',
    'invalid_or_duplicate_album': '相册名称无效或已存在，请更换名称。',
    'not_found': '此媒体或相册已不存在，请刷新后重试。',
    'film_not_found': '此影片已不存在，请刷新影视库。',
    'nfo_not_found': '未找到同名 .nfo 或影片目录下的 movie.nfo。',
    'invalid_nfo': 'NFO 文件内容无效或超出大小限制。',
    'invalid_tmdb_request': 'TMDB 请求无效，请检查令牌和搜索内容。',
    'tmdb_auth_failed': 'TMDB 拒绝了访问令牌，请检查 Read Access Token 是否有效。',
    'tmdb_access_denied': 'TMDB 不允许此令牌访问，请检查令牌权限或稍后重试。',
    'tmdb_upstream_failed': 'TMDB 暂时无法返回资料，请检查令牌或稍后重试。',
    'browser_playback_unsupported': '当前播放器不支持此视频格式。原始文件未做转换。',
    'asset_changed_rescan_required': '媒体文件已更改，请重新扫描后再试。',
  };
  if (labels.containsKey(code)) return labels[code]!;
  return userFacingError(error);
}

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

/// One set of playback speeds and one accessible picker shared by gallery
/// videos, cinema and local-video playback.
class MediaPlaybackSpeedPicker extends StatelessWidget {
  const MediaPlaybackSpeedPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  static const speeds = <double>[0.75, 1.0, 1.25, 1.5, 2.0];

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: '播放倍速',
    child: DropdownButton<double>(
      value: value,
      dropdownColor: const Color(0xff202124),
      style: Theme.of(
        context,
      ).textTheme.bodyMedium?.copyWith(color: Colors.white),
      iconEnabledColor: Colors.white,
      iconDisabledColor: Colors.white54,
      underline: const SizedBox.shrink(),
      onChanged: (speed) {
        if (speed != null) onChanged(speed);
      },
      items: const [
        DropdownMenuItem(value: 0.75, child: Text('0.75x')),
        DropdownMenuItem(value: 1.0, child: Text('1x')),
        DropdownMenuItem(value: 1.25, child: Text('1.25x')),
        DropdownMenuItem(value: 1.5, child: Text('1.5x')),
        DropdownMenuItem(value: 2.0, child: Text('2x')),
      ],
    ),
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

/// iOS capsule pill filter chip shared by the photo and cinema libraries.
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
    final maxLabelWidth = (MediaQuery.sizeOf(context).width * .58)
        .clamp(160.0, 300.0)
        .toDouble();
    final avatarWidget = icon == null
        ? null
        : Icon(
            icon,
            size: 16,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          );
    final labelWidget = Tooltip(
      message: label,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxLabelWidth),
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
    final selectedBg = scheme.primary.withValues(alpha: dark ? .22 : .13);
    final bg = dark
        ? Colors.white.withValues(alpha: 0.07)
        : scheme.surface.withValues(alpha: 0.85);
    const chipShape = StadiumBorder();
    final chipSide = BorderSide(
      color: selected
          ? scheme.primary.withValues(alpha: dark ? .45 : .32)
          : IsleGlass.rimBorderColor(dark),
      width: selected ? 1.0 : 0.75,
    );
    final textStyle = TextStyle(
      color: selected ? scheme.primary : scheme.onSurface,
      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      letterSpacing: -0.1,
    );
    if (onDeleted != null) {
      return InputChip(
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
    this.isError = false,
    this.trailing,
    this.diagnostic,
    super.key,
  });

  final String message;
  final IconData icon;
  final bool isError;
  final Widget? trailing;
  final String? diagnostic;

  @override
  Widget build(BuildContext context) {
    final inset = IsleLayout.pageInset(MediaQuery.sizeOf(context).width);
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, 0, inset, 10),
      child: Notice(
        message,
        icon: icon,
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
        dense ? 12 : 18,
        dense ? 8 : 16,
        dense ? 12 : 18,
        dense ? 14 : 20,
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
