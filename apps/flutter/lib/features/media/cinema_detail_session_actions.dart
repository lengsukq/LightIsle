import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import '../files/file_export_service.dart';
import '../files/file_share_dialog.dart';
import 'cinema_decode_preference.dart';
import 'cinema_detail_controller.dart';
import 'cinema_dlna_cast_service.dart';
import 'dlna_cast.dart';
import 'media_models.dart';
import 'media_ui.dart';
import 'offline_video_store.dart';

/// Orchestrates [BuildContext]-dependent modal confirmations, route exits,
/// DLNA casting, offline saving, file sharing, and episode switches for
/// [CinemaDetailController].
abstract final class CinemaDetailSessionActions {
  static Future<void> close(
    BuildContext context,
    CinemaDetailController controller, {
    bool allowUnsaved = false,
  }) async {
    if (controller.playback.closing) return;
    HapticFeedback.lightImpact();
    if (allowUnsaved && controller.playback.progressSaveMessage != null) {
      controller.playback.hasQueuedFinalSave = true;
      unawaited(controller.exitNativeFullscreen());
      if (context.mounted) Navigator.pop(context);
      return;
    }
    controller.mutate(() => controller.playback.closing = true);
    try {
      await controller.playback.controller?.pause();
    } catch (_) {
      // Still try to persist the last known position.
    }
    final saved = await controller.queueProgressSave(force: true);
    if (!context.mounted || controller.isDisposed) return;
    if (!saved) {
      controller.mutate(() => controller.playback.closing = false);
      return;
    }
    controller.playback.hasQueuedFinalSave = true;
    unawaited(controller.exitNativeFullscreen());
    Navigator.pop(context);
  }

  static Future<void> stopDlna(CinemaDetailController controller) async {
    final session = controller.externalActions.castSession;
    if (session == null) return;
    try {
      await session.stop();
      controller.externalActions.castSession = null;
      if (controller.isActive) {
        controller.mutate(
          () => controller.playback.playbackMessage = '已停止投屏并撤销临时链接。',
        );
      }
    } catch (error) {
      if (session.revoked) controller.externalActions.castSession = null;
      if (controller.isActive) {
        controller.mutate(
          () => controller.playback.playbackMessage = session.revoked
              ? '临时链接已撤销。电视停止指令未得到确认，请在电视上手动停止播放。'
              : '未能撤销公开链接。请保持此页面并重试“停止投屏”；链接最多 1 小时失效：${mediaErrorLabel(error)}',
        );
      }
    }
  }

  static Future<void> castToDlna(
    BuildContext context,
    CinemaDetailController controller,
  ) async {
    if (controller.externalActions.castSession != null) {
      throw StateError('请先停止当前投屏。');
    }
    if (!RegExp(
      r'\.(mp4|m4v)$',
      caseSensitive: false,
    ).hasMatch(controller.film.path)) {
      throw StateError('DLNA 目前仅支持 MP4/M4V 原始文件。');
    }
    final cast = DlnaCast();
    var retained = false;
    final currentFilmId = controller.film.id;
    final currentRootIdentity =
        controller.api.selectedRoot?.identity ?? 'default';
    try {
      if (controller.isActive) {
        controller.mutate(
          () => controller.playback.playbackMessage = '正在发现局域网 DLNA 电视…',
        );
      }
      final devices = await cast.discover();
      if (!context.mounted || controller.isDisposed) return;
      if (devices.isEmpty) {
        controller.mutate(
          () => controller.playback.playbackMessage =
              '未发现支持 DLNA 的设备，请检查电视与本机是否位于同一局域网。',
        );
        return;
      }
      final renderer = await showDialog<DlnaRenderer>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('选择 DLNA 设备'),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final device in devices)
                  ListTile(
                    leading: const Icon(Icons.tv_rounded),
                    title: Text(device.name),
                    subtitle: Text(device.controlUri.host),
                    onTap: () => Navigator.pop(dialogContext, device),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
          ],
        ),
      );
      if (renderer == null || !context.mounted || controller.isDisposed) return;
      final approved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('确认通过临时链接投屏？'),
          content: Text(
            '将为“${controller.film.title}”创建有效期 1 小时、无需登录的公开下载链接，'
            '发送给“${renderer.name}”。任何拿到链接的人在有效期内均可下载原文件。'
            '电视需能访问 NAS 地址并支持当前编码。停止投屏会撤销链接。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确认投屏'),
            ),
          ],
        ),
      );
      if (approved != true || !context.mounted || controller.isDisposed) return;
      controller.externalActions.castSession =
          await CinemaDlnaCastService(controller.api).start(
            cast: cast,
            renderer: renderer,
            filmPath: controller.film.path,
            stillCurrent: () =>
                controller.isActive &&
                !controller.playback.closing &&
                controller.film.id == currentFilmId &&
                (controller.api.selectedRoot?.identity ?? 'default') ==
                    currentRootIdentity,
          );
      retained = true;
      await controller.playback.controller?.pause();
      if (controller.isActive) {
        controller.mutate(
          () => controller.playback.playbackMessage =
              '已投屏到 ${renderer.name}。停止投屏将撤销链接。',
        );
      }
    } finally {
      if (!retained) {
        cast.close();
      }
    }
  }

  static Future<void> handleMediaAction(
    BuildContext context,
    CinemaDetailController controller,
    String action,
  ) async {
    if (controller.externalActions.mediaActionBusy ||
        controller.playback.closing) {
      return;
    }
    controller.mutate(() => controller.externalActions.mediaActionBusy = true);
    try {
      final fileName = controller.film.path.split('/').last;
      if (action == 'toggleWatched') {
        final next = !controller.film.completed;
        await controller.markWatched(completed: next);
        if (controller.isActive) {
          controller.mutate(() {
            controller.playback.playbackMessage = next
                ? '已标记为已看完。'
                : '已标记为未看完。';
          });
        }
      } else if (action == 'rename') {
        await controller.renameFilm();
      } else if (action == 'details') {
        await controller.playback.controller?.pause();
        unawaited(controller.queueProgressSave(force: true));
        controller.setShowPlayerDetails(true);
      } else if (action == 'cast') {
        await castToDlna(context, controller);
      } else if (action == 'stopCast') {
        await stopDlna(controller);
      } else if (action == 'share') {
        await openMediaFileShare(
          context,
          api: controller.api,
          path: controller.film.path,
          name: fileName,
        );
      } else if (action == 'externalPlayer') {
        await showCinemaExternalPlayerDialog(
          context,
          api: controller.api,
          film: controller.film,
        );
      } else if (action == 'trash') {
        await trashCurrentFilm(context, controller);
        return;
      } else if (action == 'export') {
        final result = await exportMediaFile(
          controller.api,
          path: controller.film.path,
          name: fileName,
        );
        if (context.mounted) {
          ScaffoldMessenger.maybeOf(context)
              ?.showSnackBar(SnackBar(content: Text(result)));
        }
      } else if (action == 'offline') {
        await saveFilmOffline(context, controller);
      }
    } catch (error) {
      if (controller.isActive) {
        controller.mutate(
          () => controller.playback.playbackMessage = mediaErrorLabel(error),
        );
      }
    } finally {
      if (controller.isActive) {
        controller.mutate(() {
          controller.externalActions.mediaActionBusy = false;
          controller.externalActions.offlineProgress = null;
        });
      }
    }
  }

  static Future<void> trashCurrentFilm(
    BuildContext context,
    CinemaDetailController controller,
  ) async {
    if (!controller.isAdmin && !controller.film.canWrite) {
      throw StateError('没有该影片原件的写入权限，请联系管理员。');
    }
    final root = controller.api.selectedRoot?.identity ?? 'default';
    final approved = await confirmAction(
      context,
      '移入回收站',
      '将“${controller.film.title}”的原始视频移入回收站？可在文件管理中恢复。',
      action: '移入回收站',
    );
    if (approved != true ||
        !context.mounted ||
        controller.isDisposed ||
        (controller.api.selectedRoot?.identity ?? 'default') != root) {
      return;
    }
    final result = await controller.api.send(
      'POST',
      '/api/v2/files/batch',
      body: {
        'action': 'trash',
        'paths': [controller.film.path],
      },
    );
    if (!context.mounted ||
        controller.isDisposed ||
        (controller.api.selectedRoot?.identity ?? 'default') != root) {
      return;
    }
    final items = result['results'];
    if (items is List &&
        items.length == 1 &&
        items.single is Map &&
        (items.single['error'] == 'storage_operation_uncertain' ||
            items.single['error'] == 'root_unavailable')) {
      throw const LightIsleApiException(
        code: 'storage_operation_uncertain',
        message: '操作可能已在原硬盘上执行，请检查原目录和回收站。',
      );
    }
    if (items is! List ||
        items.length != 1 ||
        items.single is! Map ||
        items.single['success'] != true) {
      throw StateError('移动失败，请检查当前目录权限和原文件状态');
    }
    controller.playback.hasQueuedFinalSave = true;
    Navigator.of(context).pop();
  }

  static Future<void> saveFilmOffline(
    BuildContext context,
    CinemaDetailController controller,
  ) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('保存到离线库？'),
        content: Text(
          '会将“${controller.film.title}”的原始视频保存到本设备的应用私有空间，'
          '仅当前服务器、账号和存储根可在应用内查看；离线库最多 5 GiB，'
          '单个影片最多 2 GiB。若文件太大请使用“保存原始视频”。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (approved != true || !context.mounted || controller.isDisposed) return;
    final store = OfflineVideoStore(
      api: controller.api,
      accountName: controller.accountName,
    );
    await store.save(
      controller.film,
      onProgress: (received, total) {
        if (controller.isActive && total > 0) {
          controller.mutate(
            () => controller.externalActions.offlineProgress = received / total,
          );
        }
      },
    );
    if (controller.isActive) {
      controller.mutate(
        () => controller.playback.playbackMessage = '已保存到本设备离线影片库，可在断网时播放。',
      );
    }
  }

  static Future<void> switchToPlaylistFilm(
    BuildContext context,
    CinemaDetailController controller,
    CinemaFilm target, {
    bool alreadySaved = false,
  }) async {
    if (controller.playback.closing ||
        controller.playlistState.nextEpisodeBusy ||
        !context.mounted ||
        controller.isDisposed) {
      return;
    }
    if (target.id == controller.film.id) {
      controller.setShowPlaylistSheet(false);
      return;
    }
    final currentID = controller.film.id;
    final currentRoot = controller.api.selectedRoot?.identity ?? 'default';
    bool stillCurrent() =>
        context.mounted &&
        controller.isActive &&
        !controller.playback.closing &&
        controller.film.id == currentID &&
        (controller.api.selectedRoot?.identity ?? 'default') == currentRoot;
    controller.mutate(() => controller.playlistState.nextEpisodeBusy = true);
    try {
      await controller.playback.controller?.pause();
      if (!alreadySaved && !await controller.queueProgressSave(force: true)) {
        return;
      }
      if (!stillCurrent()) return;
      controller.playback.hasQueuedFinalSave = true;
      unawaited(controller.exitNativeFullscreen());
      if (context.mounted) Navigator.pop(context, target);
    } finally {
      if (controller.isActive && !controller.playback.hasQueuedFinalSave) {
        controller.mutate(
          () => controller.playlistState.nextEpisodeBusy = false,
        );
      }
    }
  }

  static Future<void> goToPreviousEpisode(
    BuildContext context,
    CinemaDetailController controller,
  ) async {
    final previous = controller.previousPlaylistFilm;
    if (previous == null) return;
    await switchToPlaylistFilm(context, controller, previous);
  }

  static Future<void> goToNextEpisode(
    BuildContext context,
    CinemaDetailController controller, {
    bool alreadySaved = false,
  }) async {
    if (controller.playback.closing ||
        controller.playlistState.nextEpisodeBusy ||
        !context.mounted ||
        controller.isDisposed) {
      return;
    }
    if (!controller.film.isSeries &&
        controller.sameDirectoryFilms.length <= 1 &&
        controller.playlistState.loaded) {
      return;
    }
    final currentID = controller.film.id;
    final currentRoot = controller.api.selectedRoot?.identity ?? 'default';
    bool stillCurrent() =>
        context.mounted &&
        controller.isActive &&
        !controller.playback.closing &&
        controller.film.id == currentID &&
        (controller.api.selectedRoot?.identity ?? 'default') == currentRoot;
    controller.mutate(() => controller.playlistState.nextEpisodeBusy = true);
    try {
      CinemaFilm? next = controller.nextPlaylistFilm;
      if (next == null && controller.film.isSeries) {
        next = await controller.findNextEpisode();
        if (!stillCurrent()) return;
      }
      if (next == null && !controller.playlistState.loaded) {
        await controller.refreshDirectoryPlaylist();
        if (!stillCurrent()) return;
        next = controller.nextPlaylistFilm;
      }
      if (next == null) {
        controller.mutate(
          () => controller.playback.playbackMessage = controller.film.isSeries
              ? '本季已播完，或者还没有扫描到下一集。可从剧集库选择。'
              : '已是当前目录最后一个视频。',
        );
        return;
      }
      await controller.playback.controller?.pause();
      if (!alreadySaved && !await controller.queueProgressSave(force: true)) {
        return;
      }
      if (!stillCurrent()) return;
      controller.playback.hasQueuedFinalSave = true;
      unawaited(controller.exitNativeFullscreen());
      if (context.mounted) Navigator.pop(context, next);
    } catch (error) {
      if (stillCurrent()) {
        controller.mutate(
          () => controller.playback.playbackMessage =
              '无法读取下一集：${mediaErrorLabel(error)}',
        );
      }
    } finally {
      if (controller.isActive && !controller.playback.hasQueuedFinalSave) {
        controller.mutate(
          () => controller.playlistState.nextEpisodeBusy = false,
        );
      }
    }
  }
}
