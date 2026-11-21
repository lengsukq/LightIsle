import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import 'cinema_detail_controller.dart';
import 'cinema_detail_header.dart';
import 'cinema_detail_inline_player.dart';
import 'cinema_detail_metadata.dart';
import 'cinema_detail_player_controls.dart';
import 'cinema_detail_player_sheets.dart';
import 'cinema_detail_player_shortcuts.dart';
import 'cinema_detail_player_view.dart';
import 'cinema_detail_session_actions.dart';
import 'cinema_metadata_cards.dart';
import 'media_models.dart';
import 'media_ui.dart';
import 'shared_video_player_controls.dart';

class CinemaDetailDialog extends StatefulWidget {
  const CinemaDetailDialog({
    required this.api,
    required this.film,
    required this.isAdmin,
    this.accountName = '',
    this.playlist = const [],
    required this.onRename,
    required this.onProgressUpdated,
    this.playerOnly = false,
    super.key,
  });

  final LightIsleApi api;
  final CinemaFilm film;
  final bool isAdmin;
  final String accountName;
  final List<CinemaFilm> playlist;
  final Future<CinemaFilm> Function(CinemaFilm film) onRename;
  final ValueChanged<CinemaFilm> onProgressUpdated;

  /// The normal viewing flow uses a dedicated media-first player route.
  /// Existing direct detail callers retain the legacy information view.
  final bool playerOnly;

  @override
  State<CinemaDetailDialog> createState() => _CinemaDetailDialogState();
}

class _CinemaDetailDialogState extends State<CinemaDetailDialog>
    with WidgetsBindingObserver {
  late final CinemaDetailController _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = CinemaDetailController(
      api: widget.api,
      initialFilm: widget.film,
      isAdmin: widget.isAdmin,
      accountName: widget.accountName,
      playlist: widget.playlist,
      onRename: widget.onRename,
      onProgressUpdated: widget.onProgressUpdated,
      playerOnly: widget.playerOnly,
      onAutoAdvanceNextEpisode: () async {
        if (!mounted) return;
        await CinemaDetailSessionActions.goToNextEpisode(
          context,
          _controller,
          alreadySaved: true,
        );
      },
    )..initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _controller.handleAppLifecycleState(state);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  void _close({bool allowUnsaved = false}) {
    unawaited(
      CinemaDetailSessionActions.close(
        context,
        _controller,
        allowUnsaved: allowUnsaved,
      ),
    );
  }

  void _goToPreviousEpisode() {
    unawaited(
      CinemaDetailSessionActions.goToPreviousEpisode(context, _controller),
    );
  }

  void _goToNextEpisode() {
    unawaited(CinemaDetailSessionActions.goToNextEpisode(context, _controller));
  }

  void _switchToFilm(CinemaFilm film) {
    unawaited(
      CinemaDetailSessionActions.switchToPlaylistFilm(
        context,
        _controller,
        film,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        if (widget.playerOnly) return _buildPlayerPage(context);
        final position = _controller.playback.controller?.value.position;
        final resume = _controller.film.canResume && position == null;
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final compact = MediaQuery.sizeOf(context).width < 600;
        return PopScope<void>(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _close();
          },
          child: Dialog(
            backgroundColor: Colors.transparent,
            elevation: 0,
            insetPadding: compact ? EdgeInsets.zero : const EdgeInsets.all(14),
            child: _buildDialogSurface(
              context,
              compact: compact,
              isDark: isDark,
              resume: resume,
            ),
          ),
        );
      },
    );
  }

  Widget _buildDialogSurface(
    BuildContext context, {
    required bool compact,
    required bool isDark,
    required bool resume,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final radius = compact ? BorderRadius.zero : IsleRadius.brCard;
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        enabled: !(compact || IsleLayout.opaqueNavigation(context)),
        filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          constraints: BoxConstraints(
            maxWidth: 960,
            maxHeight: MediaQuery.sizeOf(context).height * (compact ? 1 : .94),
          ),
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: isDark ? 0.90 : 0.96),
            borderRadius: radius,
            border: compact
                ? null
                : Border.all(
                    color: IsleGlass.rimBorderColor(isDark),
                    width: 1.0,
                  ),
            boxShadow: compact ? null : IsleShadows.floating(isDark),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDetailHeader(),
              Divider(height: 1, color: IsleGlass.rimBorderColor(isDark)),
              Flexible(child: _buildDialogScrollBody(context, resume: resume)),
            ],
          ),
        ),
      ),
    );
  }

  CinemaDetailHeader _buildDetailHeader({
    bool darkOverlay = false,
    bool reserveMacTrafficLights = false,
    List<Widget> trailingActions = const [],
  }) {
    return CinemaDetailHeader(
      api: widget.api,
      film: _controller.film,
      isAdmin: widget.isAdmin,
      canRename: !_controller.playback.busy,
      mediaActionsEnabled:
          !_controller.externalActions.mediaActionBusy &&
          !_controller.playback.closing,
      canSaveOffline: widget.accountName.isNotEmpty,
      casting: _controller.externalActions.castSession != null,
      canClose: !_controller.playback.closing,
      onRename: () => unawaited(_controller.renameFilm()),
      onMediaAction: (value) => unawaited(
        CinemaDetailSessionActions.handleMediaAction(
          context,
          _controller,
          value,
        ),
      ),
      canDelete: widget.isAdmin || _controller.film.canWrite,
      onClose: _close,
      darkOverlay: darkOverlay,
      reserveMacTrafficLights: reserveMacTrafficLights,
      trailingActions: trailingActions,
    );
  }

  Widget _buildDialogScrollBody(BuildContext context, {required bool resume}) {
    final theme = Theme.of(context);
    final film = _controller.film;
    final offlineProgress = _controller.externalActions.offlineProgress;
    final playbackMessage = _controller.playback.playbackMessage;
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (offlineProgress != null) ...[
            Text('正在保存离线影片：${(offlineProgress * 100).clamp(0, 100).round()}%'),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: offlineProgress.clamp(0, 1)),
            const SizedBox(height: 12),
          ],
          if (resume && film.position > 5)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '上次观看至 ${SharedVideoPlayerStyle.formatClock(Duration(seconds: film.position.round()))}。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (playbackMessage != null)
            MediaStatusBanner(
              message: playbackMessage,
              icon: film.canAttemptPlayback
                  ? Icons.warning_amber_outlined
                  : Icons.info_outline,
            ),
          const SizedBox(height: 10),
          Container(
            constraints: const BoxConstraints(minHeight: 180),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: IsleRadius.brSm,
            ),
            clipBehavior: Clip.antiAlias,
            child: CinemaInlinePlayerView(controller: _controller),
          ),
          if (_controller.playback.progressSaveMessage != null)
            _buildProgressFailureBanner(
              message: _controller.playback.progressSaveMessage!,
              retryLabel: '重试',
              dismissLabel: '仍然关闭',
            ),
          if (_controller.subtitles.message != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _controller.subtitles.message!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 16),
          Text(
            film.canAttemptPlayback ? '播放进度' : '媒体信息',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          CinemaTechnicalMetadataCard(film: film),
          if (film.overview.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              '简介',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(film.overview),
          ],
          if (film.metadataSource.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '${film.metadataSource.startsWith('nfo:') ? '资料来源：本地 NFO' : (film.metadataSource.startsWith('douban') ? '资料来源：豆瓣' : '资料来源：TMDB')}${film.rating > 0 ? ' · 评分 ${film.rating.toStringAsFixed(1)} / 10' : ''}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (widget.isAdmin) ...[
            const SizedBox(height: 16),
            CinemaMetadataMatchingPanel(
              controller: _controller,
              onNextEpisode: _goToNextEpisode,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildProgressFailureBanner({
    required String message,
    required String retryLabel,
    required String dismissLabel,
  }) {
    return MediaStatusBanner(
      message: message,
      icon: Icons.cloud_off_outlined,
      isError: true,
      trailing: Wrap(
        alignment: WrapAlignment.end,
        spacing: 6,
        children: [
          TextButton(
            onPressed: _controller.playback.closing
                ? null
                : () => unawaited(_controller.queueProgressSave(force: true)),
            child: Text(retryLabel),
          ),
          TextButton(
            onPressed: _controller.playback.closing
                ? null
                : () => _close(allowUnsaved: true),
            child: Text(dismissLabel),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerPage(BuildContext context) {
    final videoReady = _controller.playback.isVideoReady;
    final showChrome = _controller.shouldShowPlayerChrome(videoReady);
    final motionDuration = IsleMotion.reducedMotion(context)
        ? Duration.zero
        : IsleMotion.quick;

    return Focus(
      focusNode: _controller.chrome.playerFocusNode,
      autofocus: true,
      onKeyEvent: (node, event) => CinemaPlayerShortcuts.handleKeyEvent(
        context: context,
        controller: _controller,
        node: node,
        event: event,
        onClose: _close,
      ),
      child: PopScope<void>(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _close();
        },
        child: Scaffold(
          key: const ValueKey('cinemaPlayerPage'),
          backgroundColor: Colors.black,
          body: MouseRegion(
            onHover: (_) => _controller.revealChrome(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: RepaintBoundary(
                    child: CinemaFullscreenStage(controller: _controller),
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: RepaintBoundary(
                    child: _buildPlayerTopChromeOverlay(
                      showChrome: showChrome,
                      videoReady: videoReady,
                      duration: motionDuration,
                    ),
                  ),
                ),
                if (videoReady)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: RepaintBoundary(
                      child: IgnorePointer(
                        ignoring: !showChrome,
                        child: AnimatedSlide(
                          offset: showChrome
                              ? Offset.zero
                              : const Offset(0, 0.10),
                          duration: motionDuration,
                          curve: IsleMotion.silk,
                          child: AnimatedOpacity(
                            opacity: showChrome ? 1.0 : 0.0,
                            duration: motionDuration,
                            curve: IsleMotion.silk,
                            child: CinemaBottomTransportDeck(
                              controller: _controller,
                              onPreviousEpisode: _goToPreviousEpisode,
                              onNextEpisode: _goToNextEpisode,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (videoReady && _controller.chrome.dockManuallyCollapsed)
                  _buildRestoreDockButton(),
                if (_controller.chrome.showPlaylistSheet)
                  CinemaPlaylistSheet(
                    controller: _controller,
                    onSelectFilm: _switchToFilm,
                  ),
                if (_controller.chrome.showPlayerDetails)
                  CinemaPlayerDetailsSheet(
                    controller: _controller,
                    onNextEpisode: _goToNextEpisode,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlayerTopChromeOverlay({
    required bool showChrome,
    required bool videoReady,
    required Duration duration,
  }) {
    final hasBanner =
        _controller.externalActions.offlineProgress != null ||
        (_controller.playback.playbackMessage != null && videoReady) ||
        _controller.playback.progressSaveMessage != null ||
        _controller.subtitles.message != null;

    return IgnorePointer(
      ignoring: !showChrome,
      child: AnimatedSlide(
        offset: showChrome ? Offset.zero : const Offset(0, -0.08),
        duration: duration,
        curve: IsleMotion.silk,
        child: AnimatedOpacity(
          opacity: showChrome ? 1.0 : 0.0,
          duration: duration,
          curve: IsleMotion.silk,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xD8000000),
                  Color(0x78000000),
                  Colors.transparent,
                ],
                stops: [0.0, 0.62, 1.0],
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildDetailHeader(
                    darkOverlay: true,
                    reserveMacTrafficLights:
                        !_controller.chrome.windowFullscreen,
                    trailingActions: _buildPlayerHeaderTrailingActions(),
                  ),
                  if (hasBanner)
                    _buildPlayerOverlayBanners(videoReady: videoReady),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildPlayerHeaderTrailingActions() {
    final film = _controller.film;
    final showDetails = _controller.chrome.showPlayerDetails;
    return [
      if (film.isSeries)
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: FilledButton.tonalIcon(
            key: const ValueKey('cinemaPlayerNextEpisode'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0x29FFFFFF),
              foregroundColor: Colors.white,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            onPressed:
                _controller.playback.closing ||
                    _controller.playlistState.nextEpisodeBusy
                ? null
                : _goToNextEpisode,
            icon: const Icon(Icons.skip_next_rounded, size: 18),
            label: Text(
              _controller.playlistState.nextEpisodeBusy ? '查找下一集…' : '下一集',
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.only(right: 4),
        child: TextButton.icon(
          key: const ValueKey('cinemaPlayerDetailsToggle'),
          style: TextButton.styleFrom(
            backgroundColor: showDetails
                ? const Color(0x47FFFFFF)
                : const Color(0x24FFFFFF),
            foregroundColor: Colors.white,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          onPressed: () => _controller.setShowPlayerDetails(
            !showDetails,
            pauseWhenOpening: true,
          ),
          icon: Icon(
            showDetails ? Icons.keyboard_arrow_up_rounded : Icons.tune_rounded,
            size: 18,
          ),
          label: Text(showDetails ? '收起播放信息' : '播放信息与设置'),
        ),
      ),
    ];
  }

  Widget _buildPlayerOverlayBanners({required bool videoReady}) {
    final offlineProgress = _controller.externalActions.offlineProgress;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Theme(
        data: buildIsleTheme(Brightness.dark),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (offlineProgress != null) ...[
              Text(
                '正在保存离线影片：${(offlineProgress * 100).clamp(0, 100).round()}%',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(value: offlineProgress.clamp(0, 1)),
              const SizedBox(height: 8),
            ],
            if (_controller.playback.playbackMessage != null && videoReady)
              MediaStatusBanner(
                message: _controller.playback.playbackMessage!,
                isError: _controller.film.canAttemptPlayback,
                icon: _controller.film.canAttemptPlayback
                    ? Icons.warning_amber_outlined
                    : Icons.info_outline,
              ),
            if (_controller.playback.progressSaveMessage != null)
              _buildProgressFailureBanner(
                message: _controller.playback.progressSaveMessage!,
                retryLabel: '重试保存',
                dismissLabel: '仍然退出',
              ),
            if (_controller.subtitles.message != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _controller.subtitles.message!,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRestoreDockButton() {
    return Positioned(
      right: 18,
      bottom: 16,
      child: SafeArea(
        top: false,
        child: FilledButton.tonalIcon(
          key: const ValueKey('cinemaRestoreDockButton'),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xA60E121A),
            foregroundColor: Colors.white,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          ),
          onPressed: _controller.restoreDock,
          icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 18),
          label: const Text('控制栏', style: TextStyle(fontSize: 12)),
        ),
      ),
    );
  }
}
