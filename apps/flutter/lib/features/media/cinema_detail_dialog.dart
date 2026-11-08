import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'cinema_detail_header.dart';
import 'cinema_hls_session_service.dart';
import 'cinema_progress_save_queue.dart';
import 'cinema_metadata_repository.dart';
import 'cinema_subtitle_repository.dart';
import 'cinema_episode_navigator.dart';
import 'cinema_pip_lifecycle_policy.dart';

import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/isle_theme.dart';
import '../../core/widgets.dart';
import '../../core/lightisle_api.dart';
import 'media_models.dart';
import 'media_ui.dart';
import 'android_pip_session.dart';
import 'offline_video_store.dart';
import 'dlna_cast.dart';
import 'cinema_dlna_cast_service.dart';
import '../files/file_export_service.dart';
import '../files/file_share_dialog.dart';

part 'cinema_detail_session_actions.dart';
part 'cinema_detail_player_state.dart';
part 'cinema_detail_metadata.dart';
part 'cinema_detail_player_view.dart';

class CinemaDetailDialog extends StatefulWidget {
  const CinemaDetailDialog({
    required this.api,
    required this.film,
    required this.isAdmin,
    this.accountName = '',
    required this.onRename,
    required this.onProgressUpdated,
    this.playerOnly = false,
    super.key,
  });

  final LightIsleApi api;
  final CinemaFilm film;
  final bool isAdmin;
  final String accountName;
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
  final TextEditingController _tmdbTokenController = TextEditingController();
  late final TextEditingController _tmdbQueryController;
  late CinemaFilm _film;
  VideoPlayerController? _controller;
  bool _loading = true;
  bool _busy = false;
  bool _closing = false;
  bool _completionSaved = false;
  bool _autoPlayNext = false;
  bool _nextEpisodeBusy = false;
  bool _showPlayerDetails = false;
  bool _mediaActionBusy = false;
  double? _offlineProgress;
  DlnaCastSession? _castSession;
  String? _playbackMessage;
  String? _progressSaveMessage;
  String? _subtitleMessage;
  String _captionLanguage = 'off';
  List<SubtitleCue> _cues = const [];
  int _subtitleGeneration = 0;
  final CinemaProgressSaveQueue _progressQueue = CinemaProgressSaveQueue();
  CinemaMetadataRepository get _metadataRepository =>
      CinemaMetadataRepository(widget.api);
  CinemaSubtitleRepository get _subtitleRepository =>
      CinemaSubtitleRepository(widget.api);
  bool _hasQueuedFinalSave = false;
  bool _metadataBusy = false;
  bool _tmdbSearching = false;
  bool _tmdbMatching = false;
  int _metadataGeneration = 0;
  List<TMDBCandidate> _tmdbCandidates = const [];
  String? _metadataMessage;
  String? _tmdbMessage;
  bool _metadataIsError = false;
  // HLS playback starts at its requested offset; saved positions remain
  // relative to the original file.
  CinemaHlsSession? _hlsSession;
  CinemaTrackInfo? _tracks;
  bool _transcodeStarting = false;
  double _playbackSpeed = 1.0;
  double _subtitleFontSize = 17.0;
  double? _seekDraft;

  void _updateState(VoidCallback fn) => setState(fn);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pip = AndroidPipSession(
      onChanged: () {
        if (mounted) setState(() {});
      },
      onTimeout: () {
        if (!mounted) return;
        setState(() {
          _playbackMessage = '未确认进入画中画，请在设备设置中检查权限。';
        });
        if (CinemaPipLifecyclePolicy.shouldPauseAfterPipExit(
          WidgetsBinding.instance.lifecycleState,
        )) {
          unawaited(_queueProgressSave(force: true));
          unawaited(_controller?.pause());
        }
      },
      onError: (error) {
        if (mounted) {
          setState(
            () => _playbackMessage = error == null
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
          unawaited(_controller?.pause());
        }
      },
    )..attach();
    _film = widget.film;
    _tmdbQueryController = TextEditingController(text: _film.title);
    _restorePlaybackSpeed();
    _restoreAutoplayNext();
    _loadDetailAndPlayer();
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
      final controller = _controller;
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
    if (_closing) return;
    HapticFeedback.lightImpact();
    if (allowUnsaved && _progressSaveMessage != null) {
      _hasQueuedFinalSave = true;
      Navigator.pop(context);
      return;
    }
    setState(() => _closing = true);
    try {
      await _controller?.pause();
    } catch (_) {
      // Still try to persist the last known position if the native player
      // cannot pause cleanly.
    }
    final saved = await _queueProgressSave(force: true);
    if (!mounted) return;
    if (!saved) {
      setState(() => _closing = false);
      return;
    }
    _hasQueuedFinalSave = true;
    Navigator.pop(context);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final castSession = _castSession;
    if (castSession != null) {
      unawaited(castSession.stop().catchError((Object _) {}));
      _castSession = null;
    }
    _pip.dispose();
    _metadataGeneration++;
    _tmdbTokenController.clear();
    _tmdbTokenController.dispose();
    _tmdbQueryController.dispose();
    _subtitleGeneration++;
    if (!_hasQueuedFinalSave) {
      _hasQueuedFinalSave = true;
      unawaited(_queueProgressSave(force: true));
    }
    final controller = _controller;
    controller?.removeListener(_onVideoChanged);
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.playerOnly) return _buildPlayerPage(context);
    final position = _controller?.value.position;
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
        child: ClipRRect(
          borderRadius: BorderRadius.circular(compact ? 0 : 24),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(
              sigmaX: compact ? 0 : 24,
              sigmaY: compact ? 0 : 24,
            ),
            child: Container(
              constraints: BoxConstraints(
                maxWidth: 1040,
                maxHeight:
                    MediaQuery.sizeOf(context).height * (compact ? 1 : .94),
              ),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface
                    .withValues(alpha: isDark ? 0.88 : 0.94),
                borderRadius: BorderRadius.circular(compact ? 0 : 24),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.16)
                      : Theme.of(context).colorScheme.outlineVariant
                            .withValues(alpha: 0.45),
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
                  CinemaDetailHeader(
                    api: widget.api,
                    film: _film,
                    isAdmin: widget.isAdmin,
                    canRename: !_busy,
                    mediaActionsEnabled: !_mediaActionBusy && !_closing,
                    canSaveOffline: widget.accountName.isNotEmpty,
                    casting: _castSession != null,
                    canClose: !_closing,
                    onRename: () => unawaited(_renameFilm()),
                    onMediaAction: (value) => unawaited(_mediaAction(value)),
                    canDelete: widget.isAdmin || _film.canWrite,
                    onClose: () => unawaited(_close()),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_offlineProgress != null) ...[
                            Text(
                              '正在保存离线影片：${(_offlineProgress! * 100).clamp(0, 100).round()}%',
                            ),
                            const SizedBox(height: 6),
                            LinearProgressIndicator(
                              value: _offlineProgress!.clamp(0, 1),
                            ),
                            const SizedBox(height: 12),
                          ],
                          if (resume && _film.position > 5)
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Text(
                                '上次观看至 ${_timeLabel(Duration(seconds: _film.position.round()))}。',
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ),
                          if (_playbackMessage != null &&
                              !_film.canAttemptPlayback)
                            MediaStatusBanner(
                              message: _playbackMessage!,
                              icon: Icons.info_outline,
                            ),
                          if (_playbackMessage != null &&
                              _film.canAttemptPlayback)
                            MediaStatusBanner(
                              message: _playbackMessage!,
                              icon: Icons.warning_amber_outlined,
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
                          if (_progressSaveMessage != null)
                            MediaStatusBanner(
                              message: _progressSaveMessage!,
                              icon: Icons.cloud_off_outlined,
                              isError: true,
                              trailing: Wrap(
                                alignment: WrapAlignment.end,
                                spacing: 4,
                                children: [
                                  TextButton(
                                    onPressed: _closing
                                        ? null
                                        : () => unawaited(
                                            _queueProgressSave(force: true),
                                          ),
                                    child: const Text('重试'),
                                  ),
                                  TextButton(
                                    onPressed: _closing
                                        ? null
                                        : () => _close(allowUnsaved: true),
                                    child: const Text('仍然关闭'),
                                  ),
                                ],
                              ),
                            ),
                          if (_subtitleMessage != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                _subtitleMessage!,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                              ),
                            ),
                          if (_film.canAttemptPlayback) ...[
                            const SizedBox(height: 18),
                            Text(
                              '播放进度',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 12),
                            _metadata(context),
                          ] else ...[
                            const SizedBox(height: 18),
                            Text(
                              '媒体信息',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 12),
                            _metadata(context),
                          ],
                          if (_film.overview.isNotEmpty) ...[
                            const SizedBox(height: 18),
                            Text(
                              '简介',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 6),
                            Text(_film.overview),
                          ],
                          if (_film.metadataSource.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Text(
                              '${_film.metadataSource.startsWith('nfo:') ? '资料来源：本地 NFO' : '资料来源：TMDB'}${_film.rating > 0 ? ' · 评分 ${_film.rating.toStringAsFixed(1)} / 10' : ''}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                          ],
                          if (widget.isAdmin) ...[
                            const SizedBox(height: 18),
                            _metadataMatchingPanel(context),
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
    );
  }

  KeyEventResult _onPlayerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _closing || !widget.playerOnly) {
      return KeyEventResult.ignored;
    }
    // Pop-up routes, text editing and input sliders own their own keys.
    if (ModalRoute.of(context)?.isCurrent == false) {
      return KeyEventResult.ignored;
    }
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      unawaited(_close());
      return KeyEventResult.handled;
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      unawaited(_seekRelative(-10));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      unawaited(_seekRelative(10));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.space) {
      if (controller.value.isPlaying) {
        unawaited(controller.pause());
        unawaited(_queueProgressSave(force: true));
      } else {
        unawaited(controller.play());
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _buildPlayerPage(BuildContext context) {
    final theme = Theme.of(context);
    return Focus(
      autofocus: true,
      onKeyEvent: _onPlayerKey,
      child: PopScope<void>(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_close());
        },
        child: Scaffold(
          key: const ValueKey('cinemaPlayerPage'),
          backgroundColor: theme.colorScheme.surface,
          body: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CinemaDetailHeader(
                  api: widget.api,
                  film: _film,
                  isAdmin: widget.isAdmin,
                  canRename: !_busy,
                  mediaActionsEnabled: !_mediaActionBusy && !_closing,
                  canSaveOffline: widget.accountName.isNotEmpty,
                  casting: _castSession != null,
                  canClose: !_closing,
                  onRename: () => unawaited(_renameFilm()),
                  onMediaAction: (value) => unawaited(_mediaAction(value)),
                  canDelete: widget.isAdmin || _film.canWrite,
                  onClose: () => unawaited(_close()),
                ),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1120),
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 28),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_offlineProgress != null) ...[
                              Text(
                                '正在保存离线影片：${(_offlineProgress! * 100).clamp(0, 100).round()}%',
                              ),
                              const SizedBox(height: 6),
                              LinearProgressIndicator(
                                value: _offlineProgress!.clamp(0, 1),
                              ),
                              const SizedBox(height: 10),
                            ],
                            if (_playbackMessage != null)
                              MediaStatusBanner(
                                message: _playbackMessage!,
                                isError: _film.canAttemptPlayback,
                                icon: _film.canAttemptPlayback
                                    ? Icons.warning_amber_outlined
                                    : Icons.info_outline,
                              ),
                            const SizedBox(height: 6),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: ColoredBox(
                                color: Colors.black,
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    minHeight: 190,
                                  ),
                                  child: _player(context),
                                ),
                              ),
                            ),
                            if (_progressSaveMessage != null)
                              MediaStatusBanner(
                                message: _progressSaveMessage!,
                                isError: true,
                                icon: Icons.cloud_off_outlined,
                                trailing: Wrap(
                                  spacing: 6,
                                  children: [
                                    TextButton(
                                      onPressed: _closing
                                          ? null
                                          : () => unawaited(
                                              _queueProgressSave(force: true),
                                            ),
                                      child: const Text('重试保存'),
                                    ),
                                    TextButton(
                                      onPressed: _closing
                                          ? null
                                          : () => _close(allowUnsaved: true),
                                      child: const Text('仍然退出'),
                                    ),
                                  ],
                                ),
                              ),
                            if (_subtitleMessage != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(_subtitleMessage!),
                              ),
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Wrap(
                                spacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  if (_film.isSeries)
                                    OutlinedButton.icon(
                                      key: const ValueKey(
                                        'cinemaPlayerNextEpisode',
                                      ),
                                      onPressed: _closing || _nextEpisodeBusy
                                          ? null
                                          : () => unawaited(_goToNextEpisode()),
                                      icon: const Icon(Icons.skip_next_rounded),
                                      label: Text(
                                        _nextEpisodeBusy ? '查找下一集…' : '下一集',
                                      ),
                                    ),
                                  TextButton.icon(
                                    key: const ValueKey(
                                      'cinemaPlayerDetailsToggle',
                                    ),
                                    onPressed: () {
                                      final opening = !_showPlayerDetails;
                                      if (opening) {
                                        unawaited(_controller?.pause());
                                        unawaited(
                                          _queueProgressSave(force: true),
                                        );
                                      }
                                      setState(
                                        () => _showPlayerDetails = opening,
                                      );
                                    },
                                    icon: Icon(
                                      _showPlayerDetails
                                          ? Icons.keyboard_arrow_up_rounded
                                          : Icons.tune_rounded,
                                    ),
                                    label: Text(
                                      _showPlayerDetails ? '收起播放信息' : '播放信息与设置',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_showPlayerDetails) ...[
                              const SizedBox(height: 16),
                              _metadata(context),
                              if (widget.isAdmin) ...[
                                const SizedBox(height: 20),
                                _metadataMatchingPanel(context),
                              ],
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _renameFilm() async {
    setState(() => _busy = true);
    try {
      final updated = await widget.onRename(_film);
      if (mounted) setState(() => _film = updated);
    } catch (error) {
      if (mounted) setState(() => _playbackMessage = mediaErrorLabel(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
