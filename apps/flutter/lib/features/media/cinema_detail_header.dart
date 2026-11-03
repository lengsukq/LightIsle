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
    required this.onClose,
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
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 14, 12, 10),
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
            children: [
              Text(
                film.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                film.isSeries
                    ? '第 ${film.season} 季 · 第 ${film.episode} 集'
                    : '电影详情',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        if (isAdmin)
          IconButton.filledTonal(
            tooltip: '修改展示名称',
            onPressed: canRename ? onRename : null,
            icon: const Icon(Icons.edit_outlined),
          ),
        PopupMenuButton<String>(
          tooltip: '分享或保存影片',
          enabled: mediaActionsEnabled,
          onSelected: onMediaAction,
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'share',
              child: Text('分享影片（限时链接）'),
            ),
            const PopupMenuItem(
              value: 'export',
              child: Text('保存原始视频'),
            ),
            if (canSaveOffline)
              const PopupMenuItem(
                value: 'offline',
                child: Text('保存到离线库'),
              ),
            if (!casting)
              const PopupMenuItem(
                value: 'cast',
                child: Text('投屏到 DLNA 设备'),
              )
            else
              const PopupMenuItem(
                value: 'stopCast',
                child: Text('停止 DLNA 投屏'),
              ),
          ],
        ),
        IconButton(
          tooltip: '关闭',
          onPressed: canClose ? onClose : null,
          icon: const Icon(Icons.close),
        ),
      ],
    ),
  );
}
