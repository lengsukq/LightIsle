import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import 'cinema_detail_controller.dart';
import 'cinema_metadata_cards.dart';
import 'cinema_metadata_repository.dart';
import 'media_models.dart';
import 'media_ui.dart';

/// Executes NFO import, TMDB search/match, and Douban search/match operations
/// against [CinemaDetailController].
abstract final class CinemaMetadataActions {
  static Future<void> importLocalNfo(CinemaDetailController controller) async {
    final match = controller.metaMatch;
    if (!controller.isAdmin ||
        match.busy ||
        match.tmdbSearching ||
        match.tmdbMatching) {
      return;
    }
    final generation = ++match.generation;
    final filmId = controller.film.id;
    controller.mutate(() {
      match.busy = true;
      match.message = null;
      match.isError = false;
    });
    try {
      final updated = await controller.metadataRepository.importNfo(filmId);
      if (!controller.isActive || generation != match.generation) return;
      controller.mutate(() {
        controller.film = updated;
        match.message = '已导入本地 NFO 资料，原视频和观看进度未修改。';
      });
      controller.onProgressUpdated(updated);
    } catch (error) {
      if (!controller.isActive || generation != match.generation) return;
      controller.mutate(() {
        match.message = mediaErrorLabel(error);
        match.isError = true;
      });
    } finally {
      if (controller.isActive && generation == match.generation) {
        controller.mutate(() => match.busy = false);
      }
    }
  }

  static Future<void> searchTmdb(CinemaDetailController controller) async {
    final match = controller.metaMatch;
    if (!controller.isAdmin ||
        match.busy ||
        match.tmdbSearching ||
        match.tmdbMatching) {
      return;
    }
    final token = match.tmdbTokenController.text.trim();
    final query = match.tmdbQueryController.text.trim();
    if (query.isEmpty) {
      controller.mutate(() => match.tmdbMessage = '请输入影视名称搜索关键词。');
      return;
    }
    if (_isInvalidTmdbToken(token)) {
      controller.mutate(() {
        match.tmdbMessage =
            '填写的 TMDB Read Access Token 格式无效（留空可直接使用 Mac 端已配置的 Token）。';
      });
      return;
    }
    final generation = ++match.generation;
    final filmId = controller.film.id;
    controller.mutate(() {
      match.tmdbSearching = true;
      match.tmdbCandidates = const [];
      match.tmdbMessage = null;
    });
    try {
      final candidates = await controller.metadataRepository.search(
        filmId,
        token: token,
        query: query,
      );
      if (!controller.isActive || generation != match.generation) return;
      controller.mutate(() {
        match.tmdbCandidates = candidates;
        if (candidates.isEmpty) {
          match.tmdbMessage = '没有找到相关影视资料，可以调整关键词后再搜索。';
        }
      });
    } catch (error) {
      if (!controller.isActive || generation != match.generation) return;
      controller.mutate(
        () => match.tmdbMessage = '搜索失败：${mediaErrorLabel(error)}',
      );
    } finally {
      if (controller.isActive && generation == match.generation) {
        controller.mutate(() => match.tmdbSearching = false);
      }
    }
  }

  static Future<void> matchTmdb(
    BuildContext context,
    CinemaDetailController controller,
    TMDBCandidate candidate,
  ) async {
    final match = controller.metaMatch;
    if (!controller.isAdmin ||
        match.busy ||
        match.tmdbSearching ||
        match.tmdbMatching) {
      return;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: IsleShapes.card(
          side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
        ),
        title: const Text('确认匹配影视资料？'),
        content: Text(
          '将“${candidate.title}”的 TMDB 简介、评分和海报资料匹配到“${controller.film.title}”。手动设置的影片名称会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认匹配'),
          ),
        ],
      ),
    );
    if (confirmed != true || !controller.isActive) return;
    final token = match.tmdbTokenController.text.trim();
    if (_isInvalidTmdbToken(token)) {
      controller.mutate(() {
        match.tmdbMessage =
            '填写的 TMDB Read Access Token 格式无效（留空可直接使用 Mac 端已配置的 Token）。';
      });
      return;
    }
    final hadPageToken = token.isNotEmpty;
    final generation = ++match.generation;
    final filmId = controller.film.id;
    controller.mutate(() {
      match.tmdbMatching = true;
      match.tmdbMessage = null;
    });
    try {
      final updated = await controller.metadataRepository.match(
        filmId,
        token: token,
        tmdbId: candidate.id,
      );
      if (!controller.isActive || generation != match.generation) return;
      controller.mutate(() {
        controller.film = updated;
        match.tmdbCandidates = const [];
        match.tmdbTokenController.clear();
        match.message = hadPageToken
            ? '已匹配 TMDB 资料；页面输入的临时凭据已清除。'
            : '已匹配 TMDB 资料。';
        match.isError = false;
      });
      controller.onProgressUpdated(updated);
    } catch (error) {
      if (!controller.isActive || generation != match.generation) return;
      controller.mutate(
        () => match.tmdbMessage = '匹配失败：${mediaErrorLabel(error)}',
      );
    } finally {
      if (controller.isActive && generation == match.generation) {
        controller.mutate(() => match.tmdbMatching = false);
      }
    }
  }

  static Future<void> searchDouban(CinemaDetailController controller) async {
    final match = controller.metaMatch;
    if (!controller.isAdmin || match.isAnyBusy) return;
    final query = match.tmdbQueryController.text.trim();
    if (query.runes.length < 2) {
      controller.mutate(() {
        match.doubanMessage = '请输入至少 2 个字符的影视名称进行豆瓣搜索。';
      });
      return;
    }
    final generation = ++match.generation;
    final filmId = controller.film.id;
    controller.mutate(() {
      match.doubanSearching = true;
      match.doubanCandidates = const [];
      match.doubanMessage = null;
    });
    try {
      final results = await controller.metadataRepository.searchDouban(
        filmId,
        query: query,
      );
      if (!controller.isActive || generation != match.generation) return;
      controller.mutate(() {
        match.doubanCandidates = results;
        if (results.isEmpty) {
          match.doubanMessage = '豆瓣未返回匹配条目，可尝试调整关键词或使用 TMDB 搜索。';
        }
      });
    } catch (error) {
      if (!controller.isActive || generation != match.generation) return;
      controller.mutate(
        () => match.doubanMessage = '豆瓣搜索失败：${mediaErrorLabel(error)}',
      );
    } finally {
      if (controller.isActive && generation == match.generation) {
        controller.mutate(() => match.doubanSearching = false);
      }
    }
  }

  static Future<void> matchDouban(
    BuildContext context,
    CinemaDetailController controller,
    DoubanCandidate candidate,
  ) async {
    final match = controller.metaMatch;
    if (!controller.isAdmin || match.isAnyBusy) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: IsleShapes.card(
          side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
        ),
        title: const Text('确认匹配豆瓣资料？'),
        content: Text(
          '将“${candidate.title}”的豆瓣资料匹配到“${controller.film.title}”。手动设置的影片名称会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认匹配'),
          ),
        ],
      ),
    );
    if (confirmed != true || !controller.isActive) return;
    final generation = ++match.generation;
    final filmId = controller.film.id;
    controller.mutate(() {
      match.busy = true;
      match.doubanMessage = null;
    });
    try {
      final updated = await controller.metadataRepository.matchDouban(
        filmId,
        query: match.tmdbQueryController.text.trim(),
        doubanId: candidate.id,
      );
      if (!controller.isActive || generation != match.generation) return;
      controller.mutate(() {
        controller.film = updated;
        match.doubanCandidates = const [];
        match.message = '已匹配豆瓣资料。';
        match.isError = false;
      });
      controller.onProgressUpdated(updated);
    } catch (error) {
      if (!controller.isActive || generation != match.generation) return;
      controller.mutate(
        () => match.doubanMessage = '匹配失败：${mediaErrorLabel(error)}',
      );
    } finally {
      if (controller.isActive && generation == match.generation) {
        controller.mutate(() => match.busy = false);
      }
    }
  }

  static bool _isInvalidTmdbToken(String token) =>
      token.isNotEmpty &&
      (token.length < 20 ||
          token.length > 2048 ||
          RegExp(r'\s').hasMatch(token));
}

/// Admin-only panel for watched quick actions, local NFO import, TMDB search,
/// and Douban matching.
class CinemaMetadataMatchingPanel extends StatelessWidget {
  const CinemaMetadataMatchingPanel({
    super.key,
    required this.controller,
    required this.onNextEpisode,
  });

  final CinemaDetailController controller;
  final VoidCallback onNextEpisode;

  @override
  Widget build(BuildContext context) {
    if (!controller.isAdmin) return const SizedBox.shrink();
    final match = controller.metaMatch;
    final busy = match.isAnyBusy;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return IsleSurface(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '影视资料',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '资料来源可在本地 NFO 和 TMDB 之间手动选择。不会自动联网查询。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          _buildPlaybackQuickActions(busy: busy),
          if (match.message != null) ...[
            const SizedBox(height: 8),
            MediaStatusBanner(
              message: match.message!,
              icon: match.isError
                  ? Icons.error_outline
                  : Icons.check_circle_outline,
              isError: match.isError,
            ),
          ],
          const SizedBox(height: 14),
          Divider(height: 1, color: IsleGlass.rimBorderColor(isDark)),
          const SizedBox(height: 14),
          _buildTmdbSearchSection(context, theme, busy: busy),
          const SizedBox(height: 14),
          Divider(height: 1, color: IsleGlass.rimBorderColor(isDark)),
          const SizedBox(height: 14),
          _buildDoubanSearchSection(context, theme, busy: busy),
        ],
      ),
    );
  }

  Widget _buildPlaybackQuickActions({required bool busy}) {
    final film = controller.film;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => unawaited(
                  controller.markWatched(completed: !film.completed),
                ),
                icon: Icon(
                  film.completed
                      ? Icons.visibility_off_outlined
                      : Icons.check_circle_outline,
                  size: 17,
                ),
                label: Text(film.completed ? '标记未看' : '标记已看'),
              ),
              if (film.position > 5 && !film.completed)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => unawaited(controller.restartFromBeginning()),
                  icon: const Icon(Icons.replay_rounded, size: 17),
                  label: const Text('从头播放'),
                ),
              if (film.isSeries)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed:
                      controller.playback.closing ||
                          controller.playlistState.nextEpisodeBusy
                      ? null
                      : onNextEpisode,
                  icon: const Icon(Icons.skip_next_rounded, size: 17),
                  label: Text(
                    controller.playlistState.nextEpisodeBusy ? '查找下一集…' : '下一集',
                  ),
                ),
            ],
          ),
        ),
        if (film.isSeries)
          SwitchListTile.adaptive(
            dense: true,
            title: const Text('播完自动下一集'),
            subtitle: const Text('默认关闭；先保存本集进度，再开始下一集。'),
            value: controller.playlistState.autoPlayNext,
            onChanged: (value) => unawaited(controller.setAutoplayNext(value)),
            contentPadding: EdgeInsets.zero,
          ),
        const SizedBox(height: 4),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
            onPressed: busy
                ? null
                : () => unawaited(
                    CinemaMetadataActions.importLocalNfo(controller),
                  ),
            icon: controller.metaMatch.busy
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.description_outlined, size: 17),
            label: const Text('导入本地 NFO 资料'),
          ),
        ),
      ],
    );
  }

  Widget _buildTmdbSearchSection(
    BuildContext context,
    ThemeData theme, {
    required bool busy,
  }) {
    final match = controller.metaMatch;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'TMDB 在线匹配（自愿联网）',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '只有点击“搜索 TMDB”或确认匹配时，令牌和请求才会发送到当前 LightIsle 服务器，由服务器联系 TMDB。令牌仅保存在当前页面内存，不写入 LightIsle 数据库；关闭详情页会清除令牌。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'This product uses the TMDB API but is not endorsed or certified by TMDB.',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: match.tmdbTokenController,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          enabled: !busy,
          decoration: const InputDecoration(
            labelText: 'TMDB API Read Access Token（可选）',
            hintText: '留空将默认使用 Mac 端已配置的 Token',
            isDense: true,
            prefixIcon: Icon(Icons.key_outlined, size: 18),
          ),
        ),
        const SizedBox(height: 10),
        _buildResponsiveQueryRow(
          labelText: '影视名称',
          prefixIcon: Icons.search,
          busy: busy,
          onSubmitted: () =>
              unawaited(CinemaMetadataActions.searchTmdb(controller)),
          button: FilledButton.icon(
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: busy
                ? null
                : () => unawaited(CinemaMetadataActions.searchTmdb(controller)),
            icon: match.tmdbSearching
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.travel_explore_outlined, size: 17),
            label: Text(match.tmdbSearching ? '搜索中…' : '搜索 TMDB'),
          ),
        ),
        if (match.tmdbMessage != null) ...[
          const SizedBox(height: 8),
          MediaStatusBanner(
            message: match.tmdbMessage!,
            icon: Icons.info_outline,
            isError:
                match.tmdbCandidates.isEmpty &&
                !match.tmdbSearching &&
                match.tmdbMessage!.startsWith('搜索失败'),
          ),
        ],
        if (match.tmdbCandidates.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final candidate in match.tmdbCandidates)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: CinemaTmdbCandidateCard(
                api: controller.api,
                candidate: candidate,
                busy: busy,
                onMatch: () => unawaited(
                  CinemaMetadataActions.matchTmdb(
                    context,
                    controller,
                    candidate,
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildDoubanSearchSection(
    BuildContext context,
    ThemeData theme, {
    required bool busy,
  }) {
    final match = controller.metaMatch;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '豆瓣快捷匹配（免凭据）',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '无需 TMDB 令牌，直接使用豆瓣公共条目快捷匹配封面海报与基本信息。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        _buildResponsiveQueryRow(
          labelText: '影视片名关键词',
          prefixIcon: Icons.search_rounded,
          busy: busy,
          onSubmitted: () =>
              unawaited(CinemaMetadataActions.searchDouban(controller)),
          button: FilledButton.tonalIcon(
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: busy
                ? null
                : () =>
                      unawaited(CinemaMetadataActions.searchDouban(controller)),
            icon: match.doubanSearching
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.movie_filter_outlined, size: 17),
            label: Text(match.doubanSearching ? '搜索中…' : '搜索豆瓣（免凭据）'),
          ),
        ),
        if (match.doubanMessage != null) ...[
          const SizedBox(height: 8),
          MediaStatusBanner(
            message: match.doubanMessage!,
            icon: Icons.info_outline,
            isError:
                match.doubanCandidates.isEmpty &&
                !match.doubanSearching &&
                match.doubanMessage!.startsWith('豆瓣搜索失败'),
          ),
        ],
        if (match.doubanCandidates.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final candidate in match.doubanCandidates)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: CinemaDoubanCandidateCard(
                candidate: candidate,
                busy: busy,
                onApply: () => unawaited(
                  CinemaMetadataActions.matchDouban(
                    context,
                    controller,
                    candidate,
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildResponsiveQueryRow({
    required String labelText,
    required IconData prefixIcon,
    required bool busy,
    required VoidCallback onSubmitted,
    required Widget button,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final field = TextField(
          controller: controller.metaMatch.tmdbQueryController,
          maxLength: 120,
          enabled: !busy,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => onSubmitted(),
          decoration: InputDecoration(
            labelText: labelText,
            isDense: true,
            prefixIcon: Icon(prefixIcon, size: 18),
            counterText: '',
          ),
        );
        if (constraints.maxWidth < 460) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [field, const SizedBox(height: 8), button],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: field),
            const SizedBox(width: 10),
            button,
          ],
        );
      },
    );
  }
}
