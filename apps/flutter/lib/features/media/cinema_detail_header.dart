import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/lightisle_api.dart';
import 'media_models.dart';

/// The film header is only a view. Playback, casting and metadata mutations
/// remain in the detail controller and are passed in as explicit callbacks.
class CinemaDetailHeader extends StatelessWidget {
  const CinemaDetailHeader({
    super.key,
    required this.api,
    required this.film,
    required this.isAdmin,
    required this.canRename,
    required this.mediaActionsEnabled,
    required this.canSaveOffline,
    required this.casting,
    required this.canClose,
    required this.onRename,
    required this.onMediaAction,
    this.canDelete = false,
    required this.onClose,
    this.darkOverlay = false,
    this.reserveMacTrafficLights = false,
    this.trailingActions = const <Widget>[],
  });

  final LightIsleApi api;
  final CinemaFilm film;
  final bool isAdmin;
  final bool canRename;
  final bool mediaActionsEnabled;
  final bool canSaveOffline;
  final bool casting;
  final bool canClose;
  final VoidCallback onRename;
  final ValueChanged<String> onMediaAction;
  final bool canDelete;
  final VoidCallback onClose;
  final bool darkOverlay;
  final bool reserveMacTrafficLights;
  final List<Widget> trailingActions;

  String get _subtitleText {
    if (film.isSeries) {
      return '第 ${film.season} 季 · 第 ${film.episode} 集';
    }
    if (!darkOverlay) return '电影详情';
    final parts = <String>[
      if (film.year > 0) '${film.year}',
      if (film.width > 0 && film.height > 0) '${film.width}×${film.height}',
      if (film.videoCodec.isNotEmpty) film.videoCodec.toUpperCase(),
    ];
    return parts.isEmpty ? '影院播放' : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final isMacOS =
        defaultTargetPlatform == TargetPlatform.macOS ||
        Theme.of(context).platform == TargetPlatform.macOS;
    final macTrafficLightInset = reserveMacTrafficLights && isMacOS
        ? 78.0
        : 0.0;
    final fgColor = darkOverlay ? Colors.white : null;
    final subColor = darkOverlay
        ? const Color(0xBFFFFFFF)
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final buttonStyle = darkOverlay
        ? IconButton.styleFrom(
            foregroundColor: Colors.white,
            disabledForegroundColor: Colors.white38,
            backgroundColor: const Color(0x24FFFFFF),
            hoverColor: const Color(0x38FFFFFF),
          )
        : null;

    return Padding(
      padding: EdgeInsets.fromLTRB(20 + macTrafficLightInset, 14, 20, 10),
      child: Row(
        children: [
          Hero(
            tag: 'cinema_poster_${film.id}',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 38,
                height: 54,
                child: AuthenticatedMediaImage(
                  api: api,
                  path: '/api/v2/cinema/${film.id}/poster',
                  maxBytes: 2 * 1024 * 1024,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  film.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                    color: fgColor,
                    shadows: darkOverlay
                        ? const [
                            Shadow(
                              color: Color(0x99000000),
                              blurRadius: 8,
                              offset: Offset(0, 1),
                            ),
                          ]
                        : null,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _subtitleText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: subColor),
                ),
              ],
            ),
          ),
          ...trailingActions,
          if (isAdmin) ...[
            const SizedBox(width: 4),
            darkOverlay
                ? IconButton(
                    tooltip: '修改展示名称',
                    style: buttonStyle,
                    onPressed: canRename ? onRename : null,
                    icon: const Icon(Icons.edit_outlined, size: 20),
                  )
                : IconButton.filledTonal(
                    tooltip: '修改展示名称',
                    onPressed: canRename ? onRename : null,
                    icon: const Icon(Icons.edit_outlined),
                  ),
          ],
          const SizedBox(width: 4),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            enabled: mediaActionsEnabled,
            iconColor: fgColor,
            style: buttonStyle,
            onSelected: onMediaAction,
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'toggleWatched',
                child: Row(
                  children: [
                    Icon(
                      film.completed
                          ? Icons.visibility_off_outlined
                          : Icons.check_circle_outline,
                      size: 18,
                      color: film.completed ? null : const Color(0xFF46D369),
                    ),
                    const SizedBox(width: 10),
                    Text(film.completed ? '标记为未看' : '标记为已看'),
                  ],
                ),
              ),
              if (isAdmin && canRename)
                const PopupMenuItem(
                  value: 'rename',
                  child: Row(
                    children: [
                      Icon(Icons.drive_file_rename_outline, size: 18),
                      SizedBox(width: 10),
                      Text('修改影片名称'),
                    ],
                  ),
                ),
              const PopupMenuItem(
                value: 'details',
                child: Row(
                  children: [
                    Icon(Icons.tune_rounded, size: 18),
                    SizedBox(width: 10),
                    Text('播放信息与资料匹配…'),
                  ],
                ),
              ),
              const PopupMenuDivider(height: 8),
              const PopupMenuItem(
                value: 'share',
                child: Row(
                  children: [
                    Icon(Icons.ios_share_outlined, size: 18),
                    SizedBox(width: 10),
                    Text('分享影片（限时链接）'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'export',
                child: Row(
                  children: [
                    Icon(Icons.download_rounded, size: 18),
                    SizedBox(width: 10),
                    Text('保存原始视频'),
                  ],
                ),
              ),
              if (canSaveOffline)
                const PopupMenuItem(
                  value: 'offline',
                  child: Row(
                    children: [
                      Icon(Icons.offline_pin_outlined, size: 18),
                      SizedBox(width: 10),
                      Text('保存到离线库'),
                    ],
                  ),
                ),
              if (!casting)
                const PopupMenuItem(
                  value: 'cast',
                  child: Row(
                    children: [
                      Icon(Icons.tv_rounded, size: 18),
                      SizedBox(width: 10),
                      Text('投屏到 DLNA 设备'),
                    ],
                  ),
                )
              else
                const PopupMenuItem(
                  value: 'stopCast',
                  child: Row(
                    children: [
                      Icon(Icons.tv_off_rounded, size: 18),
                      SizedBox(width: 10),
                      Text('停止 DLNA 投屏'),
                    ],
                  ),
                ),
              if (canDelete) ...[
                const PopupMenuDivider(height: 8),
                const PopupMenuItem(
                  value: 'trash',
                  child: Row(
                    children: [
                      Icon(
                        Icons.delete_outline_rounded,
                        size: 18,
                        color: Colors.redAccent,
                      ),
                      SizedBox(width: 10),
                      Text('移入回收站', style: TextStyle(color: Colors.redAccent)),
                    ],
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '关闭',
            style: buttonStyle,
            onPressed: canClose ? onClose : null,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}
