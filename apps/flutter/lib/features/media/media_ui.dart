import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';

String mediaErrorLabel(Object error) {
  final rawCode = error is LightIsleApiException
      ? error.code
      : error.toString();
  final code = rawCode.replaceFirst(RegExp(r'^(Exception|StateError):\s*'), '');
  const labels = <String, String>{
    'authentication_required': '登录状态已失效，请重新登录。',
    'file_permission_denied': '当前账号没有查看此媒体的权限。',
    'volume_offline': '共享磁盘当前不可用，请稍后重试。',
    'share_offline': '共享磁盘当前不可用，请稍后重试。',
    'gallery_unavailable': '图库暂时不可用，请稍后重试。',
    'cinema_unavailable': '影视库暂时不可用，请稍后重试。',
    'scan_running': '扫描正在进行，请等待完成。',
    'scan_already_running': '扫描正在进行，请等待完成。',
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
    'tmdb_upstream_failed': 'TMDB 暂时无法返回资料，请检查令牌或稍后重试。',
    'browser_playback_unsupported': '当前播放器不支持此视频格式。原始文件未做转换。',
    'asset_changed_rescan_required': '媒体文件已更改，请重新扫描后再试。',
  };
  if (labels.containsKey(code)) return labels[code]!;
  if (code.startsWith('HTTP ')) return '请求失败（$code），请重试。';
  return code.isEmpty ? '发生未知错误，请重试。' : code;
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
  final value = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000)
      .toLocal();
  return '${value.year}年${value.month}月${value.day}日';
}

class MediaStatusBanner extends StatelessWidget {
  const MediaStatusBanner({
    required this.message,
    this.icon = Icons.info_outline,
    this.isError = false,
    this.trailing,
    super.key,
  });

  final String message;
  final IconData icon;
  final bool isError;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final foreground = isError ? colors.error : colors.onSurfaceVariant;
    final tint = isError ? colors.error : colors.primary;
    final background = isError
        ? colors.errorContainer.withValues(alpha: isDark ? 0.35 : 0.70)
        : colors.surfaceContainerLow.withValues(alpha: isDark ? 0.65 : 0.85);

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: background,
        border: Border.all(
          color: isError
              ? colors.error.withValues(alpha: isDark ? 0.35 : 0.25)
              : colors.outlineVariant.withValues(alpha: isDark ? 0.25 : 0.55),
          width: 0.8,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: isDark ? 0.20 : 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: tint),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: foreground, fontSize: 13.5, height: 1.45),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
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
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 22),
      child: IsleSurface(
        padding: const EdgeInsets.fromLTRB(28, 48, 28, 52),
        radius: IsleTokens.cardRadius,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(
                      alpha: isDark ? 0.18 : 0.08,
                    ),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: colors.primary.withValues(
                        alpha: isDark ? 0.28 : 0.16,
                      ),
                      width: 0.75,
                    ),
                  ),
                  child: Center(
                    child: Icon(icon, size: 28, color: colors.primary),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
                if (action != null) ...[const SizedBox(height: 20), action!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
