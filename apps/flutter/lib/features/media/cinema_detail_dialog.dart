import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import '../files/file_export_service.dart';
import '../files/file_share_dialog.dart';
import 'android_pip_session.dart';
import 'cinema_decode_preference.dart';
import 'cinema_detail_header.dart';
import 'cinema_detail_state_models.dart';
import 'cinema_dlna_cast_service.dart';
import 'cinema_episode_navigator.dart';
import 'cinema_hls_session_service.dart';
import 'cinema_metadata_repository.dart';
import 'cinema_pip_lifecycle_policy.dart';
import 'cinema_progress_save_queue.dart';
import 'cinema_subtitle_repository.dart';
import 'dlna_cast.dart';
import 'media_models.dart';
import 'media_ui.dart';
import 'offline_video_store.dart';

part 'cinema_detail_session_actions.dart';
part 'cinema_detail_player_state.dart';
part 'cinema_detail_metadata.dart';
part 'cinema_detail_player_view.dart';
part 'cinema_detail_player_controls.dart';
part 'cinema_detail_player_menus.dart';
part 'cinema_detail_player_sheets.dart';
part 'cinema_detail_player_shortcuts.dart';
part 'cinema_detail_player_progress.dart';

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
  late final AndroidPipSession _pip;
  late CinemaFilm _film;
  final CinemaPlaybackSessionState _playback = CinemaPlaybackSessionState();
  final CinemaSubtitleViewState _subtitles = CinemaSubtitleViewState();
  final CinemaDirectoryPlaylistState _playlistState =
      CinemaDirectoryPlaylistState();
  late final CinemaMetadataMatchState _metaMatch;
  final CinemaPlayerChromeState _chrome = CinemaPlayerChromeState();
  final CinemaShortcutHudState _hud = CinemaShortcutHudState();
  final CinemaExternalActionState _externalActions =
      CinemaExternalActionState();
  final CinemaProgressSaveQueue _progressQueue = CinemaProgressSaveQueue();

  CinemaMetadataRepository get _metadataRepository =>
      CinemaMetadataRepository(widget.api);
  CinemaSubtitleRepository get _subtitleRepository =>
      CinemaSubtitleRepository(widget.api);

  void _updateState(VoidCallback fn) => setState(fn);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pip = _createPipSession()..attach();
    _film = widget.film;
    _metaMatch = CinemaMetadataMatchState(initialQuery: _film.title);
    _restorePlaybackSpeed();
    _restorePlaybackVolume();
    _restoreAutoplayNext();
    unawaited(CinemaDecodePreference.load());
    _loadDetailAndPlayer();
  }

  AndroidPipSession _createPipSession() {
    return AndroidPipSession(
      onChanged: () {
        if (mounted) setState(() {});
      },
      onTimeout: () {
        if (!mounted) return;
        setState(() {
          _playback.playbackMessage = '未确认进入画中画，请在设备设置中检查权限。';
        });
        if (CinemaPipLifecyclePolicy.shouldPauseAfterPipExit(
          WidgetsBinding.instance.lifecycleState,
        )) {
          unawaited(_queueProgressSave(force: true));
          unawaited(_playback.controller?.pause());
        }
      },
      onError: (error) {
        if (mounted) {
          setState(
            () => _playback.playbackMessage = error == null
                ? '无法进入画中画，请检查系统权限。'
                : mediaErrorLabel(error),
          );
        }
      },
      onExit: () {
        if (mounted &&
            CinemaPipLifecyclePolicy.shouldPauseAfterPipExit(
              WidgetsBinding.instance.lifecycleState,
            )) {
          unawaited(_queueProgressSave(force: true));
          unawaited(_playback.controller?.pause());
        }
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Entering native PiP must not pause the underlying video. An exit event
    // restores the ordinary background pause / save-progress behavior.
    if (CinemaPipLifecyclePolicy.shouldPauseOnLifecycle(
      state,
      pipRequested: _pip.requested,
      pipActive: _pip.active,
    )) {
      unawaited(_queueProgressSave(force: true));
      final controller = _playback.controller;
      if (controller?.value.isPlaying == true) unawaited(controller!.pause());
    }
  }

  /// Switches the quality tier. Lower tiers force a transcode session even
  /// for directly playable sources; 原画 tears a session down when the film
  /// can play directly, keeping the resume point.
  static const _qualityTiers = <(String, String, int)>[
    ('1080', '1080P', 1080),
    ('720', '720P', 720),
    ('480', '480P', 480),
  ];

  Future<void> _close({bool allowUnsaved = false}) async {
    if (_playback.closing) return;
    HapticFeedback.lightImpact();
    if (allowUnsaved && _playback.progressSaveMessage != null) {
      _playback.hasQueuedFinalSave = true;
      unawaited(_exitNativeFullscreen());
      Navigator.pop(context);
      return;
    }
    setState(() => _playback.closing = true);
    try {
      await _playback.controller?.pause();
    } catch (_) {
      // Still try to persist the last known position if the native player
      // cannot pause cleanly.
    }
    final saved = await _queueProgressSave(force: true);
    if (!mounted) return;
    if (!saved) {
      setState(() => _playback.closing = false);
      return;
    }
    _playback.hasQueuedFinalSave = true;
    unawaited(_exitNativeFullscreen());
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _hud.cancelTimers();
    _chrome.dispose();
    if (_chrome.windowFullscreen) {
      unawaited(_exitNativeFullscreen());
    }
    WidgetsBinding.instance.removeObserver(this);
    final castSession = _externalActions.castSession;
    if (castSession != null) {
      unawaited(castSession.stop().catchError((Object _) {}));
      _externalActions.castSession = null;
    }
    _pip.dispose();
    _playlistState.generation++;
    _metaMatch.dispose();
    _subtitles.generation++;
    if (!_playback.hasQueuedFinalSave) {
      _playback.hasQueuedFinalSave = true;
      unawaited(_queueProgressSave(force: true));
    }
    final controller = _playback.controller;
    controller?.removeListener(_onVideoChanged);
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.playerOnly) return _buildPlayerPage(context);
    final position = _playback.controller?.value.position;
    final resume = _film.canResume && position == null;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final compact = MediaQuery.sizeOf(context).width < 600;
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_close());
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
  }

  Widget _buildDialogSurface(
    BuildContext context, {
    required bool compact,
    required bool isDark,
    required bool resume,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(compact ? 0 : 24),
      child: BackdropFilter(
        enabled: !(compact || IsleLayout.opaqueNavigation(context)),
        filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          constraints: BoxConstraints(
            maxWidth: 1040,
            maxHeight: MediaQuery.sizeOf(context).height * (compact ? 1 : .94),
          ),
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: isDark ? 0.88 : 0.94),
            borderRadius: BorderRadius.circular(compact ? 0 : 24),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.16)
                  : scheme.outlineVariant.withValues(alpha: 0.45),
              width: 0.85,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.15),
                blurRadius: 36,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDetailHeader(),
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
      film: _film,
      isAdmin: widget.isAdmin,
      canRename: !_playback.busy,
      mediaActionsEnabled:
          !_externalActions.mediaActionBusy && !_playback.closing,
      canSaveOffline: widget.accountName.isNotEmpty,
      casting: _externalActions.castSession != null,
      canClose: !_playback.closing,
      onRename: () => unawaited(_renameFilm()),
      onMediaAction: (value) => unawaited(_mediaAction(value)),
      canDelete: widget.isAdmin || _film.canWrite,
      onClose: () => unawaited(_close()),
      darkOverlay: darkOverlay,
      reserveMacTrafficLights: reserveMacTrafficLights,
      trailingActions: trailingActions,
    );
  }

  Widget _buildDialogScrollBody(BuildContext context, {required bool resume}) {
    final theme = Theme.of(context);
    final offlineProgress = _externalActions.offlineProgress;
    final playbackMessage = _playback.playbackMessage;
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
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
          if (resume && _film.position > 5)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                '上次观看至 ${_timeLabel(Duration(seconds: _film.position.round()))}。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (playbackMessage != null)
            MediaStatusBanner(
              message: playbackMessage,
              icon: _film.canAttemptPlayback
                  ? Icons.warning_amber_outlined
                  : Icons.info_outline,
            ),
          const SizedBox(height: 10),
          Container(
            constraints: const BoxConstraints(minHeight: 180),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: _player(context),
          ),
          if (_playback.progressSaveMessage != null)
            _buildProgressFailureBanner(
              message: _playback.progressSaveMessage!,
              retryLabel: '重试',
              dismissLabel: '仍然关闭',
            ),
          if (_subtitles.message != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _subtitles.message!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 18),
          Text(
            _film.canAttemptPlayback ? '播放进度' : '媒体信息',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          _metadata(context),
          if (_film.overview.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text('简介', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(_film.overview),
          ],
          if (_film.metadataSource.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '${_film.metadataSource.startsWith('nfo:') ? '资料来源：本地 NFO' : '资料来源：TMDB'}${_film.rating > 0 ? ' · 评分 ${_film.rating.toStringAsFixed(1)} / 10' : ''}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (widget.isAdmin) ...[
            const SizedBox(height: 18),
            _metadataMatchingPanel(context),
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
            onPressed: _playback.closing
                ? null
                : () => unawaited(_queueProgressSave(force: true)),
            child: Text(retryLabel),
          ),
          TextButton(
            onPressed: _playback.closing
                ? null
                : () => _close(allowUnsaved: true),
            child: Text(dismissLabel),
          ),
        ],
      ),
    );
  }

  bool _shouldShowPlayerChrome(bool videoReady) {
    final controller = _playback.controller;
    return !_chrome.dockManuallyCollapsed &&
        (_chrome.visible ||
            _playback.loading ||
            !videoReady ||
            controller == null ||
            !controller.value.isPlaying ||
            _chrome.showPlayerDetails ||
            _chrome.showPlaylistSheet ||
            _playback.progressSaveMessage != null ||
            _externalActions.offlineProgress != null);
  }

  Widget _buildPlayerPage(BuildContext context) {
    final videoReady = _playback.isVideoReady;
    final showChrome = _shouldShowPlayerChrome(videoReady);

    return Focus(
      focusNode: _chrome.playerFocusNode,
      autofocus: true,
      onKeyEvent: _onPlayerKey,
      child: PopScope<void>(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_close());
        },
        child: Scaffold(
          key: const ValueKey('cinemaPlayerPage'),
          backgroundColor: Colors.black,
          body: MouseRegion(
            onHover: (_) => _revealChrome(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: RepaintBoundary(child: _fullscreenStage(context)),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: RepaintBoundary(
                    child: _buildPlayerTopChromeOverlay(
                      showChrome: showChrome,
                      videoReady: videoReady,
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
                        child: AnimatedOpacity(
                          opacity: showChrome ? 1.0 : 0.0,
                          duration: IsleMotion.reducedMotion(context)
                              ? Duration.zero
                              : IsleMotion.quick,
                          curve: IsleMotion.curve,
                          child: _buildBottomTransportDeck(context),
                        ),
                      ),
                    ),
                  ),
                if (videoReady && _chrome.dockManuallyCollapsed)
                  _buildRestoreDockButton(),
                if (_chrome.showPlaylistSheet) _buildPlaylistSheet(context),
                if (_chrome.showPlayerDetails)
                  _buildPlayerDetailsSheet(context),
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
  }) {
    final hasBanner =
        _externalActions.offlineProgress != null ||
        (_playback.playbackMessage != null && videoReady) ||
        _playback.progressSaveMessage != null ||
        _subtitles.message != null;

    return IgnorePointer(
      ignoring: !showChrome,
      child: AnimatedOpacity(
        opacity: showChrome ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
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
                  reserveMacTrafficLights: !_chrome.windowFullscreen,
                  trailingActions: _buildPlayerHeaderTrailingActions(),
                ),
                if (hasBanner)
                  _buildPlayerOverlayBanners(videoReady: videoReady),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildPlayerHeaderTrailingActions() {
    return [
      if (_film.isSeries)
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
            onPressed: _playback.closing || _playlistState.nextEpisodeBusy
                ? null
                : () => unawaited(_goToNextEpisode()),
            icon: const Icon(Icons.skip_next_rounded, size: 18),
            label: Text(_playlistState.nextEpisodeBusy ? '查找下一集…' : '下一集'),
          ),
        ),
      Padding(
        padding: const EdgeInsets.only(right: 4),
        child: TextButton.icon(
          key: const ValueKey('cinemaPlayerDetailsToggle'),
          style: TextButton.styleFrom(
            backgroundColor: _chrome.showPlayerDetails
                ? const Color(0x47FFFFFF)
                : const Color(0x24FFFFFF),
            foregroundColor: Colors.white,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          onPressed: () {
            final opening = !_chrome.showPlayerDetails;
            if (opening) {
              unawaited(_playback.controller?.pause());
              unawaited(_queueProgressSave(force: true));
            }
            setState(() => _chrome.showPlayerDetails = opening);
          },
          icon: Icon(
            _chrome.showPlayerDetails
                ? Icons.keyboard_arrow_up_rounded
                : Icons.tune_rounded,
            size: 18,
          ),
          label: Text(_chrome.showPlayerDetails ? '收起播放信息' : '播放信息与设置'),
        ),
      ),
    ];
  }

  Widget _buildPlayerOverlayBanners({required bool videoReady}) {
    final offlineProgress = _externalActions.offlineProgress;
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
            if (_playback.playbackMessage != null && videoReady)
              MediaStatusBanner(
                message: _playback.playbackMessage!,
                isError: _film.canAttemptPlayback,
                icon: _film.canAttemptPlayback
                    ? Icons.warning_amber_outlined
                    : Icons.info_outline,
              ),
            if (_playback.progressSaveMessage != null)
              _buildProgressFailureBanner(
                message: _playback.progressSaveMessage!,
                retryLabel: '重试保存',
                dismissLabel: '仍然退出',
              ),
            if (_subtitles.message != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _subtitles.message!,
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
          onPressed: () {
            _updateState(() => _chrome.dockManuallyCollapsed = false);
            _revealChrome();
          },
          icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 18),
          label: const Text('控制栏', style: TextStyle(fontSize: 12)),
        ),
      ),
    );
  }
}
