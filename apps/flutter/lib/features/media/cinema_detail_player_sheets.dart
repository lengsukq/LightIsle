import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/widgets.dart';
import 'cinema_decode_preference.dart';
import 'cinema_detail_controller.dart';
import 'cinema_detail_metadata.dart';
import 'cinema_episode_navigator.dart';
import 'cinema_metadata_cards.dart';
import 'media_models.dart';
import 'shared_video_player_controls.dart';

/// Overlay sheet listing same-directory films/episodes with autoplay toggle.
class CinemaPlaylistSheet extends StatelessWidget {
  const CinemaPlaylistSheet({
    super.key,
    required this.controller,
    required this.onSelectFilm,
  });

  final CinemaDetailController controller;
  final ValueChanged<CinemaFilm> onSelectFilm;

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final isWide = screenSize.width >= 680;
    final items = controller.sameDirectoryFilms;
    final dirLabel = CinemaEpisodeNavigator.directoryLabel(
      controller.film.path,
    );

    return Positioned.fill(
      key: const ValueKey('cinemaPlaylistSheet'),
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => controller.setShowPlaylistSheet(false),
            child: const ColoredBox(color: Color(0x73000000)),
          ),
          SafeArea(
            child: Align(
              alignment: isWide ? Alignment.centerRight : Alignment.center,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: isWide ? 400 : 480,
                  maxHeight: screenSize.height * 0.8,
                ),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 20, isWide ? 24 : 16, 24),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: IsleGlassBackdrop(
                      blur: 28,
                      child: Theme(
                        data: buildIsleTheme(Brightness.dark),
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xE6121620),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: const Color(0x2EFFFFFF),
                              width: 0.85,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x80000000),
                                blurRadius: 36,
                                offset: Offset(0, 14),
                              ),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildHeader(
                                dirLabel: dirLabel,
                                itemCount: items.length,
                              ),
                              const Divider(
                                height: 1,
                                color: Color(0x22FFFFFF),
                              ),
                              Flexible(
                                child: ListView.separated(
                                  shrinkWrap: true,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 10,
                                  ),
                                  itemCount: items.length,
                                  separatorBuilder: (_, _) =>
                                      const SizedBox(height: 6),
                                  itemBuilder: (context, index) =>
                                      _buildItemTile(items[index], index),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
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

  Widget _buildHeader({required String dirLabel, required int itemCount}) {
    final autoPlay = controller.playlistState.autoPlayNext;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 10),
      child: Row(
        children: [
          const Icon(
            Icons.playlist_play_rounded,
            color: Colors.white,
            size: 22,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '同目录播放列表',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$dirLabel · 共 $itemCount 个视频${controller.playlistState.loading ? ' · 同步中…' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ],
            ),
          ),
          InkWell(
            key: const ValueKey('cinemaPlaylistAutoplayToggle'),
            borderRadius: BorderRadius.circular(999),
            onTap: () => unawaited(controller.setAutoplayNext(!autoPlay)),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: autoPlay
                    ? const Color(0x38E50914)
                    : const Color(0x1FFFFFFF),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: autoPlay
                      ? const Color(0x80E50914)
                      : const Color(0x26FFFFFF),
                  width: 0.8,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    autoPlay
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    size: 14,
                    color: autoPlay ? const Color(0xFFFF4D57) : Colors.white70,
                  ),
                  const SizedBox(width: 4),
                  const Text(
                    '自动连播',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '收起播放列表',
            color: Colors.white70,
            onPressed: () => controller.setShowPlaylistSheet(false),
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _buildItemTile(CinemaFilm item, int index) {
    final isCurrent = item.id == controller.film.id;
    final fileName = item.path.split('/').last;
    final durationSec = item.durationSeconds > 0
        ? item.durationSeconds
        : item.duration;
    final durationText = durationSec > 0
        ? SharedVideoPlayerStyle.formatClock(
            Duration(milliseconds: (durationSec * 1000).round()),
          )
        : '';
    final badgeText = item.isSeries
        ? 'S${item.season}E${item.episode}'
        : (index + 1).toString().padLeft(2, '0');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('cinemaPlaylistItem_${item.id}'),
        borderRadius: BorderRadius.circular(14),
        onTap: controller.playlistState.nextEpisodeBusy
            ? null
            : () => onSelectFilm(item),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isCurrent
                ? const Color(0x2EE50914)
                : const Color(0x14FFFFFF),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isCurrent
                  ? const Color(0x80E50914)
                  : const Color(0x1AFFFFFF),
              width: 0.8,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isCurrent
                      ? const Color(0xFFE50914)
                      : const Color(0x26FFFFFF),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: isCurrent
                    ? const Icon(
                        Icons.play_arrow_rounded,
                        size: 18,
                        color: Colors.white,
                      )
                    : Text(
                        badgeText,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13.5,
                        fontWeight: isCurrent
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        fileName,
                        if (durationText.isNotEmpty) durationText,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (isCurrent)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE50914),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    '正在播放',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
              else if (item.completed)
                const Text(
                  '已看完',
                  style: TextStyle(
                    color: Color(0xFF81C995),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                )
              else if (item.canResume)
                Text(
                  '已看 ${(item.progressRatio * 100).round().clamp(1, 99)}%',
                  style: const TextStyle(
                    color: Color(0xFF9CDCF5),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Overlay sheet presenting playback decode preferences, technical metadata,
/// synopsis, and admin NFO/TMDB/Douban matching tools.
class CinemaPlayerDetailsSheet extends StatelessWidget {
  const CinemaPlayerDetailsSheet({
    super.key,
    required this.controller,
    required this.onNextEpisode,
  });

  final CinemaDetailController controller;
  final VoidCallback onNextEpisode;

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final film = controller.film;
    return Positioned.fill(
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => controller.setShowPlayerDetails(false),
            child: const ColoredBox(color: Color(0x8A000000)),
          ),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 780,
                  maxHeight: screenHeight * 0.8,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 24,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: IsleGlassBackdrop(
                      blur: 28,
                      child: Theme(
                        data: buildIsleTheme(Brightness.dark),
                        child: Builder(
                          builder: (darkContext) => Container(
                            decoration: BoxDecoration(
                              color: const Color(0xE0141821),
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(
                                color: const Color(0x2EFFFFFF),
                                width: 0.85,
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x80000000),
                                  blurRadius: 36,
                                  offset: Offset(0, 14),
                                ),
                              ],
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    22,
                                    16,
                                    14,
                                    10,
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.tune_rounded,
                                        color: Colors.white,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          '播放信息与设置',
                                          style: Theme.of(darkContext)
                                              .textTheme
                                              .titleMedium
                                              ?.copyWith(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: '收起播放信息',
                                        color: Colors.white70,
                                        onPressed: () => controller
                                            .setShowPlayerDetails(false),
                                        icon: const Icon(Icons.close_rounded),
                                      ),
                                    ],
                                  ),
                                ),
                                const Divider(
                                  height: 1,
                                  color: Color(0x22FFFFFF),
                                ),
                                Flexible(
                                  child: SingleChildScrollView(
                                    padding: const EdgeInsets.fromLTRB(
                                      22,
                                      18,
                                      22,
                                      22,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        CinemaDecodePreferenceCard(
                                          controller: controller,
                                        ),
                                        CinemaTechnicalMetadataCard(film: film),
                                        if (film.overview.isNotEmpty) ...[
                                          const SizedBox(height: 18),
                                          Text(
                                            '简介',
                                            style: Theme.of(darkContext)
                                                .textTheme
                                                .titleMedium,
                                          ),
                                          const SizedBox(height: 6),
                                          Text(film.overview),
                                        ],
                                        if (film.metadataSource.isNotEmpty) ...[
                                          const SizedBox(height: 10),
                                          Text(
                                            '${film.metadataSource.startsWith('nfo:') ? '资料来源：本地 NFO' : (film.metadataSource.startsWith('douban') ? '资料来源：豆瓣' : '资料来源：TMDB')}${film.rating > 0 ? ' · 评分 ${film.rating.toStringAsFixed(1)} / 10' : ''}',
                                            style: Theme.of(darkContext)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                  color: Colors.white70,
                                                ),
                                          ),
                                        ],
                                        if (controller.isAdmin) ...[
                                          const SizedBox(height: 20),
                                          CinemaMetadataMatchingPanel(
                                            controller: controller,
                                            onNextEpisode: onNextEpisode,
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
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

/// Toggle card for local-first decoding preference and external player launch.
class CinemaDecodePreferenceCard extends StatelessWidget {
  const CinemaDecodePreferenceCard({super.key, required this.controller});

  final CinemaDetailController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: CinemaDecodePreference.preferLocalDecode,
      builder: (context, preferLocal, _) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        decoration: BoxDecoration(
          color: const Color(0x18FFFFFF),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0x26FFFFFF), width: 0.8),
        ),
        child: Material(
          color: Colors.transparent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile.adaptive(
                key: const ValueKey('cinemaSheetPreferLocalDecodeSwitch'),
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  '优先本地解码（原画直传）',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: const Text(
                  '即使服务器已安装 FFmpeg，也优先直接传输原始视频由当前设备硬解播放；未安装 FFmpeg 时会自动启用。',
                  style: TextStyle(color: Colors.white70, fontSize: 11.5),
                ),
                value: preferLocal,
                onChanged: (next) async {
                  await CinemaDecodePreference.setPreferLocalDecode(next);
                  if (!controller.isActive) return;
                  unawaited(
                    controller.switchQuality(next ? 'local' : 'source'),
                  );
                },
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('cinemaSheetExternalPlayerButton'),
                    onPressed: () => unawaited(
                      showCinemaExternalPlayerDialog(
                        context,
                        api: controller.api,
                        film: controller.film,
                      ),
                    ),
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: const Text('外部播放器串流 (IINA / Infuse / VLC)'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
