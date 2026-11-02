import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import 'media_models.dart';
import 'subtitle_import.dart';
import 'media_ui.dart';
import 'android_pip_session.dart';
import 'offline_video_store.dart';
import 'dlna_cast.dart';
import '../files/file_export_service.dart';
import '../files/file_share_dialog.dart';

class CinemaDetailDialog extends StatefulWidget {
  const CinemaDetailDialog({
    required this.api,
    required this.film,
    required this.isAdmin,
    this.accountName = '',
    required this.onRename,
    required this.onProgressUpdated,
    super.key,
  });

  final LightIsleApi api;
  final CinemaFilm film;
  final bool isAdmin;
  final String accountName;
  final Future<CinemaFilm> Function(CinemaFilm film) onRename;
  final ValueChanged<CinemaFilm> onProgressUpdated;

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
  bool _mediaActionBusy = false;
  double? _offlineProgress;
  DlnaCastSession? _castSession;
  String? _playbackMessage;
  String? _progressSaveMessage;
  String? _subtitleMessage;
  String _captionLanguage = 'off';
  List<SubtitleCue> _cues = const [];
  int _subtitleGeneration = 0;
  DateTime _lastSaved = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _saveQueue = Future<void>.value();
  bool _hasQueuedFinalSave = false;
  bool _metadataBusy = false;
  bool _tmdbSearching = false;
  bool _tmdbMatching = false;
  int _metadataGeneration = 0;
  List<TMDBCandidate> _tmdbCandidates = const [];
  String? _metadataMessage;
  String? _tmdbMessage;
  bool _metadataIsError = false;
  // Transcode (HLS) playback state. The muxer writes segments starting at
  // [CinemaHlsSession.start], so the player timeline begins at zero and every
  // persisted position is offset by that value before being saved.
  CinemaHlsSession? _hlsSession;
  CinemaTrackInfo? _tracks;
  bool _transcodeStarting = false;
  double _playbackSpeed = 1.0;
  double _subtitleFontSize = 17.0;
  double? _seekDraft;

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
        if (WidgetsBinding.instance.lifecycleState !=
            AppLifecycleState.resumed) {
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
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed) {
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

  Future<void> _stopDlna() async {
    final session = _castSession;
    if (session == null) return;
    try {
      await session.stop();
      _castSession = null;
      if (mounted) setState(() => _playbackMessage = '已停止投屏并撤销临时链接。');
    } catch (error) {
      if (session.revoked) _castSession = null;
      if (mounted) {
        setState(
          () => _playbackMessage = session.revoked
              ? '临时链接已撤销。电视停止指令未得到确认，请在电视上手动停止播放。'
              : '未能撤销公开链接。请保持此页面并重试“停止投屏”；链接最多 1 小时失效：${mediaErrorLabel(error)}',
        );
      }
    }
  }

  Future<void> _castToDlna() async {
    if (_castSession != null) throw StateError('请先停止当前投屏。');
    if (!RegExp(r'\.(mp4|m4v)$', caseSensitive: false).hasMatch(_film.path)) {
      throw StateError('DLNA 目前仅支持 MP4/M4V 原始文件。');
    }
    final cast = DlnaCast();
    String? shareId;
    var retained = false;
    try {
      if (mounted) setState(() => _playbackMessage = '正在发现局域网 DLNA 电视…');
      final devices = await cast.discover();
      if (!mounted) return;
      if (devices.isEmpty) {
        setState(() => _playbackMessage = '未发现支持 DLNA 的设备，请检查电视与本机是否位于同一局域网。');
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
      if (renderer == null || !mounted) return;
      final approved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('确认通过临时链接投屏？'),
          content: Text(
            '将为“${_film.title}”创建有效期 1 小时、无需登录的公开下载链接，'
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
      if (approved != true || !mounted) return;
      final share = await widget.api.send(
        'POST',
        '/api/v2/file-shares',
        body: {'path': _film.path, 'hours': 1},
      );
      final token = share['token']?.toString() ?? '';
      final shareData = share['share'];
      shareId = shareData is Map ? shareData['id']?.toString() : null;
      if (token.isEmpty || shareId == null || shareId.isEmpty) {
        throw const FormatException('服务器未返回可撤销的分享链接');
      }
      final url = widget.api.publicFileShareUri(token);
      if (url.host == '127.0.0.1' ||
          url.host == 'localhost' ||
          url.host == '::1') {
        throw StateError('需要使用电视能够访问的 NAS 局域网地址登录。');
      }
      await cast.play(renderer, url);
      _castSession = DlnaCastSession(
        api: widget.api,
        cast: cast,
        renderer: renderer,
        shareId: shareId,
      );
      retained = true;
      await _controller?.pause();
      if (mounted) {
        setState(() => _playbackMessage = '已投屏到 ${renderer.name}。停止投屏将撤销链接。');
      }
    } finally {
      if (!retained) {
        if (shareId != null) {
          try {
            await widget.api.send(
              'DELETE',
              '/api/v2/file-shares/${Uri.encodeComponent(shareId)}',
            );
          } on Object {
            // Expiring share remains valid for at most one hour.
          }
        }
        cast.close();
      }
    }
  }

  Future<void> _mediaAction(String action) async {
    if (_mediaActionBusy || _closing) return;
    setState(() => _mediaActionBusy = true);
    try {
      final fileName = _film.path.split('/').last;
      if (action == 'cast') {
        await _castToDlna();
      } else if (action == 'stopCast') {
        await _stopDlna();
      } else if (action == 'share') {
        await openMediaFileShare(
          context,
          api: widget.api,
          path: _film.path,
          name: fileName,
        );
      } else if (action == 'export') {
        final result = await exportMediaFile(
          widget.api,
          path: _film.path,
          name: fileName,
        );
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)
              ?.showSnackBar(SnackBar(content: Text(result)));
        }
      } else if (action == 'offline') {
        final approved = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('保存到离线库？'),
            content: Text(
              '会将“${_film.title}”的原始视频保存到本设备的应用私有空间，'
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
        if (approved != true || !mounted) return;
        final store = OfflineVideoStore(
          api: widget.api,
          accountName: widget.accountName,
        );
        await store.save(
          _film,
          onProgress: (received, total) {
            if (mounted && total > 0) {
              setState(() => _offlineProgress = received / total);
            }
          },
        );
        if (mounted) {
          setState(() => _playbackMessage = '已保存到本设备离线影片库，可在断网时播放。');
        }
      }
    } catch (error) {
      if (mounted) setState(() => _playbackMessage = mediaErrorLabel(error));
    } finally {
      if (mounted) {
        setState(() {
          _mediaActionBusy = false;
          _offlineProgress = null;
        });
      }
    }
  }

  Future<void> _enterPiP() async {
    if (_controller?.value.isInitialized == true) await _pip.enter();
  }

  Future<void> _restoreAutoplayNext() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        setState(
          () => _autoPlayNext =
              prefs.getBool('lightisle_cinema_autoplay_next') ?? false,
        );
      }
    } catch (_) {
      /* Opt-in defaults to off when preferences cannot load. */
    }
  }

  Future<void> _setAutoplayNext(bool value) async {
    setState(() => _autoPlayNext = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('lightisle_cinema_autoplay_next', value);
    } catch (_) {
      /* Session selection still works. */
    }
  }

  Future<CinemaFilm?> _findNextEpisode() async {
    final current = _film;
    if (!current.isSeries || current.series.isEmpty) return null;
    final response = await widget.api.get(
      '/api/v2/series',
      query: {'limit': '60'},
    );
    final matches = <int>[];
    for (final item in (response['series'] as List? ?? const [])) {
      if (item is Map && item['name'] == current.series && item['id'] is num) {
        matches.add((item['id'] as num).toInt());
      }
    }
    // Ambiguous shows should not accidentally play an unrelated episode.
    if (matches.length != 1 || matches.single <= 0) return null;
    final detail = await widget.api.get('/api/v2/series/${matches.single}');
    final episodes = <CinemaFilm>[];
    for (final item in (detail['films'] as List? ?? const [])) {
      if (item is Map) {
        try {
          episodes.add(CinemaFilm.fromJson(Map<String, dynamic>.from(item)));
        } on FormatException {
          /* Ignore malformed records. */
        }
      }
    }
    episodes.sort((a, b) {
      final season = a.season.compareTo(b.season);
      if (season != 0) return season;
      final episode = a.episode.compareTo(b.episode);
      return episode != 0 ? episode : a.id.compareTo(b.id);
    });
    final index = episodes.indexWhere((item) => item.id == current.id);
    return index < 0 || index + 1 >= episodes.length
        ? null
        : episodes[index + 1];
  }

  Future<void> _goToNextEpisode({bool alreadySaved = false}) async {
    if (_closing || _nextEpisodeBusy || !mounted || !_film.isSeries) return;
    final currentID = _film.id;
    setState(() => _nextEpisodeBusy = true);
    try {
      final next = await _findNextEpisode();
      if (!mounted || _closing || _film.id != currentID) return;
      if (next == null) {
        setState(() => _playbackMessage = '本季已播完，或者还没有扫描到下一集。可从剧集库选择。');
        return;
      }
      await _controller?.pause();
      if (!alreadySaved && !await _queueProgressSave(force: true)) return;
      if (!mounted || _closing || _film.id != currentID) return;
      _hasQueuedFinalSave = true;
      Navigator.pop(context, next);
    } catch (error) {
      if (mounted) {
        setState(() => _playbackMessage = '无法读取下一集：${mediaErrorLabel(error)}');
      }
    } finally {
      if (mounted) {
        setState(() => _nextEpisodeBusy = false);
      }
    }
  }

  Future<void> _restorePlaybackSpeed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final speed = prefs.getDouble('lightisle_cinema_playback_speed');
      if (!mounted ||
          speed == null ||
          !const [0.75, 1.0, 1.25, 1.5, 2.0].contains(speed)) {
        return;
      }
      setState(() => _playbackSpeed = speed);
      await _controller?.setPlaybackSpeed(speed);
    } catch (_) {
      // Disabled preferences or a missing test platform never blocks playback.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Entering native PiP must not pause the underlying video. An exit event
    // restores the ordinary background pause / save-progress behavior.
    if (_pip.requested || _pip.active) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_queueProgressSave(force: true));
      final controller = _controller;
      if (controller?.value.isPlaying == true) unawaited(controller!.pause());
    }
  }

  Future<void> _loadDetailAndPlayer({double? seekTo}) async {
    try {
      final response = await widget.api.get('/api/v2/cinema/${_film.id}');
      final detail = CinemaFilm.fromJson(response);
      if (!mounted) return;
      setState(() => _film = detail);
    } catch (_) {
      // Keep list metadata and progress if the detail refresh is unavailable.
    }
    if (!mounted) return;
    if (!_film.canAttemptPlayback) {
      setState(() {
        _loading = false;
        _playbackMessage = _unsupportedMessage;
      });
      // The browser-grade player cannot decode this container/codec. The
      // server-side HLS session (remux or VideoToolbox transcode) is the
      // remaining playback path; it degrades honestly when FFmpeg is absent.
      // Starting the session at the resume point keeps the muxer from
      // producing minutes of segments nobody is watching yet.
      await _startTranscode(start: _film.canResume ? _film.position : 0);
      return;
    }
    try {
      final source = await widget.api.mediaUri(
        '/api/v2/cinema/${_film.id}/stream',
      );
      if (!mounted) return;
      final controller = VideoPlayerController.networkUrl(
        source,
        httpHeaders: widget.api.nativeMediaHeaders,
      );
      _controller = controller;
      await controller.initialize();
      if (!mounted || _controller != controller) return;
      final savedPosition = seekTo != null && seekTo > 1
          ? Duration(milliseconds: (seekTo * 1000).round())
          : Duration(milliseconds: (_film.position * 1000).round());
      if (savedPosition > Duration.zero &&
          savedPosition <
              controller.value.duration - const Duration(seconds: 5)) {
        await controller.seekTo(savedPosition);
      }
      if (_playbackSpeed != 1.0) {
        await controller.setPlaybackSpeed(_playbackSpeed);
      }
      if (!mounted || _controller != controller) return;
      controller.addListener(_onVideoChanged);
      setState(() {
        _loading = false;
        _playbackMessage = _film.browserPlayback == 'unverified-direct'
            ? '此格式尚未验证；如果当前设备无法解码，播放会失败。原片未做转换。'
            : null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _playbackMessage = '无法在当前设备播放此视频：${mediaErrorLabel(error)}';
      });
    }
  }

  String get _unsupportedMessage {
    switch (_film.probeStatus) {
      case 'pending':
        return '格式仍在识别中，当前无法直接播放。请稍后重新打开。';
      case 'unavailable':
        return '格式检查器不可用，暂时无法确认此视频是否能播放。';
      case 'failed':
        return '视频格式识别失败，当前无法直接播放。';
      case 'unsupported':
        return '当前设备的播放器不支持此视频格式。原始文件未做转换。';
      default:
        return '此视频无法通过当前播放器播放。原始文件未做转换。';
    }
  }

  String _transcodeErrorLabel(Object error) {
    if (error is LightIsleApiException) {
      switch (error.code) {
        case 'transcode_unavailable':
          return '未安装 FFmpeg，仅支持下载后播放；管理员可在服务器执行 brew install ffmpeg 启用转码。';
        case 'transcode_busy':
          return '转码通道被占用，请稍后重试。';
        case 'transcode_failed':
          return '转码失败：该影片可能包含不兼容的编码，请下载后用本地播放器打开。';
        case 'transcode_insufficient_space':
          return '服务器空间不足，无法创建转码缓存，请清理后重试。';
        case 'transcode_start_timeout':
          return '转码启动超时，请稍后重试。';
      }
    }
    return mediaErrorLabel(error);
  }

  Future<void> _startTranscode({
    double? start,
    int audio = 0,
    String quality = 'source',
  }) async {
    if (!mounted || _transcodeStarting) return;
    final filmId = _film.id;
    setState(() {
      _transcodeStarting = true;
      _playbackMessage = '正在启动转码…';
    });
    try {
      final session = CinemaHlsSession.fromJson(
        await widget.api.get(
          '/api/v2/cinema/$filmId/hls/session',
          query: <String, String>{
            'start': ((start ?? 0).clamp(
              0,
              double.infinity,
            )).toStringAsFixed(3),
            'audio': '$audio',
            if (quality != 'source') 'quality': quality,
          },
        ),
      );
      // The muxer writes the playlist after its first segment; poll until it
      // exists so the native player never initializes against a 404.
      Uri? playlist;
      for (var attempt = 0; attempt < 60; attempt++) {
        if (!mounted || _film.id != filmId) return;
        try {
          await widget.api.bytes(
            '/api/v2/cinema/$filmId/hls/${session.sessionId}/index.m3u8',
            maxBytes: 1 << 20,
          );
          playlist = await widget.api.mediaHlsUri(
            '/api/v2/cinema/$filmId/hls/${session.sessionId}/',
          );
          break;
        } on LightIsleApiException catch (error) {
          if (error.statusCode == 502) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
      // Resolving the authenticated HLS relay can outlive the dialog. Never
      // create a native player after dispose has released the current one.
      if (!mounted || _film.id != filmId) return;
      if (playlist == null) {
        throw const LightIsleApiException(
          code: 'transcode_start_timeout',
          message: '转码启动超时。',
        );
      }
      final controller = VideoPlayerController.networkUrl(
        playlist,
        httpHeaders: widget.api.nativeMediaHeaders,
      );
      final previous = _controller;
      _controller = controller;
      if (previous != null && previous != controller) {
        previous.removeListener(_onVideoChanged);
        await previous.dispose();
      }
      if (!mounted || _controller != controller) return;
      await controller.initialize();
      if (!mounted || _controller != controller) return;
      final target =
          (start ?? (_film.canResume ? _film.position : 0)) - session.start;
      final savedPosition = Duration(
        milliseconds: (target > 1 ? target * 1000 : 0).round(),
      );
      if (savedPosition > Duration.zero &&
          savedPosition <
              controller.value.duration - const Duration(seconds: 5)) {
        await controller.seekTo(savedPosition);
      }
      if (_playbackSpeed != 1.0) {
        await controller.setPlaybackSpeed(_playbackSpeed);
      }
      if (!mounted || _controller != controller) return;
      controller.addListener(_onVideoChanged);
      try {
        _tracks = CinemaTrackInfo.fromJson(
          await widget.api.get('/api/v2/cinema/$filmId/tracks'),
        );
      } catch (_) {
        // Track listing is optional; playback continues without selectors.
      }
      if (!mounted) return;
      setState(() {
        _hlsSession = session;
        _transcodeStarting = false;
        _playbackMessage = session.profile == 'remux'
            ? '转封装播放（无画质损失），原片未修改。'
            : '转码播放中（服务器实时转码），原片未修改。';
      });
    } catch (error) {
      if (!mounted || _film.id != filmId) return;
      setState(() {
        _transcodeStarting = false;
        _playbackMessage = _transcodeErrorLabel(error);
      });
    }
  }

  Future<void> _switchAudio(int audioIndex) async {
    final controller = _controller;
    final session = _hlsSession;
    if (controller == null ||
        session == null ||
        session.audioTrack == audioIndex) {
      return;
    }
    final realPosition =
        controller.value.position.inMilliseconds / 1000.0 + session.start;
    await controller.pause();
    await _startTranscode(
      start: realPosition,
      audio: audioIndex,
      quality: session.quality,
    );
  }

  /// Switches the quality tier. Lower tiers force a transcode session even
  /// for directly playable sources; 原画 tears a session down when the film
  /// can play directly, keeping the resume point.
  static const _qualityTiers = <(String, String, int)>[
    ('1080', '1080P', 1080),
    ('720', '720P', 720),
    ('480', '480P', 480),
  ];

  /// 原画 plus every tier below the source height (no upscaling options).
  List<(String, String)> _qualityOptions() {
    final options = <(String, String)>[('source', '原画')];
    final sourceHeight = _film.height;
    for (final (value, label, height) in _qualityTiers) {
      if (sourceHeight > 0 && sourceHeight <= height) break;
      options.add((value, label));
    }
    return options;
  }

  Future<void> _switchQuality(String quality) async {
    if (_transcodeStarting) return;
    final controller = _controller;
    final session = _hlsSession;
    if (session == null) {
      if (quality == 'source') return;
      final realPosition = controller != null
          ? controller.value.position.inMilliseconds / 1000.0
          : (_film.canResume ? _film.position : 0.0);
      await controller?.pause();
      await _startTranscode(start: realPosition, quality: quality);
      return;
    }
    if (session.quality == quality) return;
    final realPosition =
        controller!.value.position.inMilliseconds / 1000.0 + session.start;
    await controller.pause();
    if (quality == 'source' && _film.canAttemptPlayback) {
      // Back to the plain stream: dispose the session controller first.
      controller.removeListener(_onVideoChanged);
      await controller.dispose();
      _hlsSession = null;
      _controller = null;
      if (!mounted) return;
      setState(() {
        _loading = true;
        _playbackMessage = null;
      });
      await _loadDetailAndPlayer(seekTo: realPosition);
      return;
    }
    await _startTranscode(
      start: realPosition,
      audio: session.audioTrack,
      quality: quality,
    );
  }

  Future<void> _setPlaybackSpeed(double speed) async {
    if (!const [0.75, 1.0, 1.25, 1.5, 2.0].contains(speed)) return;
    _playbackSpeed = speed;
    await _controller?.setPlaybackSpeed(speed);
    if (mounted) {
      setState(() {});
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('lightisle_cinema_playback_speed', speed);
    } catch (_) {
      /* Persist when possible, playback still works without it. */
    }
  }

  double get _originalPlaybackSeconds {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return 0;
    return controller.value.position.inMilliseconds / 1000.0 +
        (_hlsSession?.start ?? 0);
  }

  double get _originalPlaybackDuration {
    final controller = _controller;
    final sessionStart = _hlsSession?.start ?? 0;
    final observed = controller == null || !controller.value.isInitialized
        ? 0.0
        : controller.value.duration.inMilliseconds / 1000.0 + sessionStart;
    return _film.durationSeconds > 0
        ? (_film.durationSeconds > observed ? _film.durationSeconds : observed)
        : observed;
  }

  Future<void> _seekAbsolute(double absoluteSeconds) async {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        _transcodeStarting) {
      return;
    }
    final max = _originalPlaybackDuration;
    final target = absoluteSeconds
        .clamp(0.0, max > 0 ? max - .25 : 0.0)
        .toDouble();
    final session = _hlsSession;
    if (session != null) {
      // The playlist's first frame is at session.start; rebuild the session
      // for absolute seeks outside its guaranteed live media window.
      unawaited(_queueProgressSave(force: true));
      await _startTranscode(
        start: target,
        audio: session.audioTrack,
        quality: session.quality,
      );
    } else {
      await controller.seekTo(Duration(milliseconds: (target * 1000).round()));
      unawaited(_queueProgressSave(force: true));
    }
    if (mounted) setState(() => _seekDraft = null);
  }

  Future<void> _seekRelative(double deltaSeconds) async {
    await _seekAbsolute(_originalPlaybackSeconds + deltaSeconds);
  }

  Future<void> _showFullscreenPlayer() async {
    if (_controller?.value.isInitialized != true) return;
    double? draggedPosition;
    await showDialog<void>(
      context: context,
      useSafeArea: false,
      barrierColor: Colors.black,
      builder: (context) => StatefulBuilder(
        builder: (dialogContext, updateOverlay) => Dialog.fullscreen(
          backgroundColor: Colors.black,
          child: SafeArea(
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: '退出全屏',
                      color: Colors.white,
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.fullscreen_exit),
                    ),
                    if (_pip.supported)
                      IconButton(
                        tooltip: '画中画',
                        color: Colors.white,
                        onPressed: _enterPiP,
                        icon: const Icon(Icons.picture_in_picture_alt_rounded),
                      ),
                    Expanded(
                      child: Text(
                        _film.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
                Expanded(
                  child: Center(
                    child:
                        _controller == null || !_controller!.value.isInitialized
                        ? const CircularProgressIndicator()
                        : AspectRatio(
                            aspectRatio: _controller!.value.aspectRatio > 0
                                ? _controller!.value.aspectRatio
                                : 16 / 9,
                            child: GestureDetector(
                              onDoubleTapDown: (details) async {
                                final width = MediaQuery.sizeOf(dialogContext)
                                    .width;
                                final direction =
                                    details.localPosition.dx < width * .4
                                    ? -10.0
                                    : details.localPosition.dx > width * .6
                                    ? 10.0
                                    : 0.0;
                                if (direction != 0) {
                                  await _seekRelative(direction);
                                  if (dialogContext.mounted) {
                                    updateOverlay(() {});
                                  }
                                } else if (_controller?.value.isPlaying ==
                                    true) {
                                  await _controller?.pause();
                                } else {
                                  await _controller?.play();
                                }
                              },
                              child: VideoPlayer(_controller!),
                            ),
                          ),
                  ),
                ),
                AnimatedBuilder(
                  animation: _controller!,
                  builder: (context, _) {
                    final total = _originalPlaybackDuration;
                    final current = _originalPlaybackSeconds;
                    if (total <= 0) return const SizedBox(height: 20);
                    return Column(
                      children: [
                        Slider(
                          value: (draggedPosition ?? current).clamp(0.0, total),
                          max: total,
                          onChanged: _transcodeStarting
                              ? null
                              : (value) => updateOverlay(
                                  () => draggedPosition = value,
                                ),
                          onChangeEnd: (value) async {
                            await _seekAbsolute(value);
                            if (dialogContext.mounted) {
                              updateOverlay(() => draggedPosition = null);
                            }
                          },
                        ),
                        Text(
                          '${_timeLabel(Duration(milliseconds: (current * 1000).round()))} / ${_timeLabel(Duration(milliseconds: (total * 1000).round()))}',
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ],
                    );
                  },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: '快退10秒',
                      color: Colors.white,
                      onPressed: () async {
                        await _seekRelative(-10);
                        if (dialogContext.mounted) updateOverlay(() {});
                      },
                      icon: const Icon(Icons.replay_10),
                    ),
                    IconButton(
                      tooltip: _controller?.value.isPlaying == true
                          ? '暂停'
                          : '播放',
                      color: Colors.white,
                      onPressed: () {
                        final controller = _controller;
                        if (controller == null) return;
                        if (controller.value.isPlaying) {
                          unawaited(controller.pause());
                        } else {
                          unawaited(controller.play());
                        }
                        updateOverlay(() {});
                      },
                      icon: Icon(
                        _controller?.value.isPlaying == true
                            ? Icons.pause
                            : Icons.play_arrow,
                      ),
                    ),
                    IconButton(
                      tooltip: '快进10秒',
                      color: Colors.white,
                      onPressed: () async {
                        await _seekRelative(10);
                        if (dialogContext.mounted) updateOverlay(() {});
                      },
                      icon: const Icon(Icons.forward_10),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _markWatched({required bool completed}) async {
    final filmId = _film.id;
    try {
      final updated = CinemaFilm.fromJson(
        await widget.api.send(
          'POST',
          '/api/v2/cinema/$filmId/watched',
          body: <String, Object>{'completed': completed},
        ),
      );
      if (!mounted || _film.id != filmId) return;
      setState(() => _film = updated);
      widget.onProgressUpdated(updated);
    } catch (error) {
      if (mounted) {
        setState(() => _metadataMessage = mediaErrorLabel(error));
      }
    }
  }

  Future<void> _restartFromBeginning() async {
    final controller = _controller;
    final session = _hlsSession;
    if (session != null) {
      await _startTranscode(
        start: 0,
        audio: session.audioTrack,
        quality: session.quality,
      );
      return;
    }
    if (controller != null) {
      await controller.seekTo(Duration.zero);
      await controller.play();
    }
  }

  void _onVideoChanged() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.hasError) {
      final message =
          '视频播放中断：${controller.value.errorDescription ?? '当前设备无法解码此格式。'}';
      if (mounted && _playbackMessage != message) {
        setState(() => _playbackMessage = message);
      }
      return;
    }
    if (mounted) {
      setState(() {});
    }
    final now = DateTime.now();
    final ended = controller.value.isCompleted;
    if (ended && !_completionSaved) {
      _completionSaved = true;
      final value = controller.value;
      final sessionStart = _hlsSession?.start ?? 0;
      final clock = cinemaPlaybackClock(
        value.position.inMilliseconds / 1000.0,
        value.duration.inMilliseconds / 1000.0,
        sessionStart: sessionStart,
        originalDuration: _film.durationSeconds,
      );
      // A still-growing HLS playlist can reach its temporary end well before
      // the real film. Do not mark watched or play the next episode then.
      unawaited(_onPlaybackCompleted(nearRealEnd: clock.nearEnd));
    } else if (now.difference(_lastSaved) >= const Duration(seconds: 10)) {
      unawaited(_queueProgressSave(force: true));
    }
  }

  Future<void> _onPlaybackCompleted({required bool nearRealEnd}) async {
    final completedID = _film.id;
    final saved = await _queueProgressSave(force: true, completed: nearRealEnd);
    if (!nearRealEnd && mounted && !_closing) {
      setState(
        () => _playbackMessage = '当前转码片段已播放至末尾，但整部影片尚未结束。可等待转码继续，或调整播放进度。',
      );
    }
    if (nearRealEnd &&
        saved &&
        mounted &&
        !_closing &&
        _autoPlayNext &&
        _film.id == completedID) {
      await _goToNextEpisode(alreadySaved: true);
    }
  }

  Future<bool> _queueProgressSave({
    bool force = false,
    bool completed = false,
  }) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return Future<bool>.value(true);
    }
    final value = controller.value;
    final offset = _hlsSession?.start ?? 0;
    final localSeconds = value.position.inMilliseconds / 1000.0;
    final playlistSeconds = value.duration.inMilliseconds / 1000.0;
    if (offset + playlistSeconds <= 0 ||
        !localSeconds.isFinite ||
        !playlistSeconds.isFinite) {
      return Future<bool>.value(true);
    }
    final clock = cinemaPlaybackClock(
      localSeconds,
      playlistSeconds,
      sessionStart: offset,
      originalDuration: _film.durationSeconds,
    );
    final now = DateTime.now();
    if (!force && now.difference(_lastSaved) < const Duration(seconds: 10)) {
      return Future<bool>.value(true);
    }
    _lastSaved = now;
    final isCompleted = completed || clock.nearEnd;
    final filmId = _film.id;
    final result = Completer<bool>();
    _saveQueue = _saveQueue.then((_) async {
      try {
        await widget.api.send(
          'PUT',
          '/api/v2/cinema/$filmId/progress',
          body: <String, Object>{
            'position': clock.position,
            'duration': clock.duration,
            'completed': isCompleted,
          },
        );
        if (mounted && _film.id == filmId) {
          final updated = _film.withProgress(
            newPosition: clock.position,
            newDuration: clock.duration,
            isCompleted: isCompleted,
          );
          setState(() {
            _film = updated;
            _progressSaveMessage = null;
          });
          widget.onProgressUpdated(updated);
        }
        result.complete(true);
      } catch (_) {
        if (mounted && _film.id == filmId) {
          setState(() {
            _progressSaveMessage = '播放进度暂时未能保存，请检查连接后重试。';
          });
        }
        result.complete(false);
      }
    });
    return result.future;
  }

  Future<void> _loadSubtitles(String language) async {
    final generation = ++_subtitleGeneration;
    setState(() {
      _captionLanguage = language;
      _subtitleMessage = null;
      _cues = const [];
    });
    if (language == 'off') return;
    try {
      final embedded = language.startsWith('emb:');
      final query = embedded
          ? <String, String>{'track': language.substring(4)}
          : language == 'auto'
          ? null
          : <String, String>{'lang': language};
      final bytes = await widget.api.bytes(
        embedded
            ? '/api/v2/cinema/${_film.id}/embedded-subtitles'
            : '/api/v2/cinema/${_film.id}/subtitles',
        query: query,
        maxBytes: 1 << 20,
      );
      final cues = parseWebVtt(utf8.decode(bytes, allowMalformed: true));
      if (!mounted || generation != _subtitleGeneration) return;
      setState(() {
        _cues = cues;
        _subtitleMessage = cues.isEmpty ? '字幕文件没有可显示的内容。' : null;
      });
    } catch (error) {
      if (!mounted || generation != _subtitleGeneration) return;
      setState(() {
        _subtitleMessage =
            error is LightIsleApiException && error.code == 'film_not_found'
            ? '未找到匹配字幕，或此影片已被移除。'
            : mediaErrorLabel(error);
      });
    }
  }

  /// An optional, one-session subtitle source from this device.
  Future<void> _importLocalSubtitles() async {
    try {
      final selected = await pickLocalSubtitle();
      if (!mounted || selected == null) return;
      final cues = parseWebVtt(selected.contents);
      if (cues.isEmpty) throw const FormatException('没有找到有效的字幕时间轴');
      ++_subtitleGeneration;
      setState(() {
        _captionLanguage = 'local';
        _cues = cues;
        _subtitleMessage = '已加载：${selected.name}（仅本次播放）';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _subtitleMessage = '无法加载字幕：${mediaErrorLabel(error)}');
      }
    }
  }

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

  Future<void> _importLocalNfo() async {
    if (!widget.isAdmin || _metadataBusy || _tmdbSearching || _tmdbMatching) {
      return;
    }
    final generation = ++_metadataGeneration;
    final filmId = _film.id;
    setState(() {
      _metadataBusy = true;
      _metadataMessage = null;
      _metadataIsError = false;
    });
    try {
      await widget.api.send('POST', '/api/v2/cinema/$filmId/metadata/nfo');
      final response = await widget.api.get('/api/v2/cinema/$filmId');
      final updated = CinemaFilm.fromJson(response);
      if (!mounted || generation != _metadataGeneration) return;
      setState(() {
        _film = updated;
        _metadataMessage = '已导入本地 NFO 资料，原视频和观看进度未修改。';
      });
      widget.onProgressUpdated(updated);
    } catch (error) {
      if (!mounted || generation != _metadataGeneration) return;
      setState(() {
        _metadataMessage = mediaErrorLabel(error);
        _metadataIsError = true;
      });
    } finally {
      if (mounted && generation == _metadataGeneration) {
        setState(() => _metadataBusy = false);
      }
    }
  }

  Future<void> _searchTmdb() async {
    if (!widget.isAdmin || _metadataBusy || _tmdbSearching || _tmdbMatching) {
      return;
    }
    final token = _tmdbTokenController.text.trim();
    final query = _tmdbQueryController.text.trim();
    if (token.isEmpty || query.isEmpty) {
      setState(() {
        _tmdbMessage = '请输入自己的 TMDB API Read Access Token 和搜索关键词。';
      });
      return;
    }
    final generation = ++_metadataGeneration;
    final filmId = _film.id;
    setState(() {
      _tmdbSearching = true;
      _tmdbCandidates = const [];
      _tmdbMessage = null;
    });
    try {
      final response = await widget.api.send(
        'POST',
        '/api/v2/cinema/$filmId/metadata/tmdb/search',
        body: <String, String>{'accessToken': token, 'query': query},
      );
      final raw = response['results'];
      final candidates = <TMDBCandidate>[];
      if (raw is List) {
        for (final item in raw) {
          if (item is! Map) continue;
          try {
            candidates.add(
              TMDBCandidate.fromJson(Map<String, dynamic>.from(item)),
            );
          } on FormatException {
            // Skip incomplete upstream rows while retaining usable matches.
          }
        }
      }
      if (!mounted || generation != _metadataGeneration) return;
      setState(() {
        _tmdbCandidates = candidates;
        if (candidates.isEmpty) {
          _tmdbMessage = '没有找到相关影视资料，可以调整关键词后再搜索。';
        }
      });
    } catch (error) {
      if (!mounted || generation != _metadataGeneration) return;
      setState(() => _tmdbMessage = '搜索失败：${mediaErrorLabel(error)}');
    } finally {
      if (mounted && generation == _metadataGeneration) {
        setState(() => _tmdbSearching = false);
      }
    }
  }

  Future<void> _matchTmdb(TMDBCandidate candidate) async {
    if (!widget.isAdmin || _metadataBusy || _tmdbSearching || _tmdbMatching) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认匹配影视资料？'),
        content: Text(
          '将“${candidate.title}”的 TMDB 简介、评分和海报资料匹配到“${_film.title}”。手动设置的影片名称会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认匹配'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final token = _tmdbTokenController.text.trim();
    if (token.isEmpty) {
      setState(() => _tmdbMessage = '令牌已清除，请重新输入后搜索并匹配。');
      return;
    }
    final generation = ++_metadataGeneration;
    final filmId = _film.id;
    setState(() {
      _tmdbMatching = true;
      _tmdbMessage = null;
    });
    try {
      await widget.api.send(
        'POST',
        '/api/v2/cinema/$filmId/metadata/tmdb/match',
        body: <String, Object>{'accessToken': token, 'tmdbId': candidate.id},
      );
      final response = await widget.api.get('/api/v2/cinema/$filmId');
      final updated = CinemaFilm.fromJson(response);
      if (!mounted || generation != _metadataGeneration) return;
      setState(() {
        _film = updated;
        _tmdbCandidates = const [];
        _tmdbTokenController.clear();
        _metadataMessage = '已匹配 TMDB 资料；API 凭据已从页面内存清除。';
        _metadataIsError = false;
      });
      widget.onProgressUpdated(updated);
    } catch (error) {
      if (!mounted || generation != _metadataGeneration) return;
      setState(() => _tmdbMessage = '匹配失败：${mediaErrorLabel(error)}');
    } finally {
      if (mounted && generation == _metadataGeneration) {
        setState(() => _tmdbMatching = false);
      }
    }
  }

  Widget _metadataMatchingPanel(BuildContext context) {
    if (!widget.isAdmin) return const SizedBox.shrink();
    final busy = _metadataBusy || _tmdbSearching || _tmdbMatching;
    final theme = Theme.of(context);
    return IsleSurface(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('影视资料', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            '资料来源可在本地 NFO 和 TMDB 之间手动选择。不会自动联网查询。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          const SizedBox(height: 10),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: () =>
                      unawaited(_markWatched(completed: !_film.completed)),
                  icon: Icon(
                    _film.completed
                        ? Icons.visibility_off_outlined
                        : Icons.check_circle_outline,
                  ),
                  label: Text(_film.completed ? '标记未看' : '标记已看'),
                ),
                if (_film.position > 5 && !_film.completed)
                  OutlinedButton.icon(
                    onPressed: () => unawaited(_restartFromBeginning()),
                    icon: const Icon(Icons.replay_rounded),
                    label: const Text('从头播放'),
                  ),
                if (_film.isSeries)
                  OutlinedButton.icon(
                    onPressed: _closing || _nextEpisodeBusy
                        ? null
                        : () => unawaited(_goToNextEpisode()),
                    icon: const Icon(Icons.skip_next_rounded),
                    label: Text(_nextEpisodeBusy ? '查找下一集…' : '下一集'),
                  ),
              ],
            ),
          ),
          if (_film.isSeries)
            SwitchListTile.adaptive(
              title: const Text('播完自动下一集'),
              subtitle: const Text('默认关闭；先保存本集进度，再开始下一集。'),
              value: _autoPlayNext,
              onChanged: _setAutoplayNext,
              contentPadding: EdgeInsets.zero,
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              onPressed: busy ? null : _importLocalNfo,
              icon: _metadataBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.description_outlined),
              label: const Text('导入本地 NFO 资料'),
            ),
          ),
          if (_metadataMessage != null) ...[
            const SizedBox(height: 8),
            MediaStatusBanner(
              message: _metadataMessage!,
              icon: _metadataIsError
                  ? Icons.error_outline
                  : Icons.check_circle_outline,
              isError: _metadataIsError,
            ),
          ],
          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 14),
          Text('TMDB 在线匹配（自愿联网）', style: theme.textTheme.titleSmall),
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
            controller: _tmdbTokenController,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            enabled: !busy,
            decoration: const InputDecoration(
              labelText: 'TMDB API Read Access Token',
              hintText: '仅为本次手动匹配提供',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.key_outlined),
            ),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final field = TextField(
                controller: _tmdbQueryController,
                maxLength: 120,
                enabled: !busy,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => unawaited(_searchTmdb()),
                decoration: const InputDecoration(
                  labelText: '影视名称',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.search),
                  counterText: '',
                ),
              );
              final button = FilledButton.icon(
                onPressed: busy ? null : _searchTmdb,
                icon: _tmdbSearching
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.travel_explore_outlined),
                label: Text(_tmdbSearching ? '搜索中…' : '搜索 TMDB'),
              );
              if (constraints.maxWidth < 460) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [field, const SizedBox(height: 8), button],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: field),
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: button,
                  ),
                ],
              );
            },
          ),
          if (_tmdbMessage != null) ...[
            const SizedBox(height: 8),
            MediaStatusBanner(
              message: _tmdbMessage!,
              icon: Icons.info_outline,
              isError:
                  _tmdbCandidates.isEmpty &&
                  !_tmdbSearching &&
                  _tmdbMessage!.startsWith('搜索失败'),
            ),
          ],
          if (_tmdbCandidates.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final candidate in _tmdbCandidates)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _tmdbCandidateCard(candidate, busy),
              ),
          ],
        ],
      ),
    );
  }

  Widget _tmdbCandidateCard(TMDBCandidate candidate, bool busy) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final title = Text(
            '${candidate.title}${candidate.year.isEmpty ? '' : ' (${candidate.year})'}',
            style: theme.textTheme.titleSmall,
          );
          final description = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              title,
              const SizedBox(height: 4),
              Text(
                '${candidate.kind == 'tv' || candidate.kind == 'series' ? '剧集' : '电影'} · 评分 ${candidate.rating.toStringAsFixed(1)} / 10',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (candidate.overview.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  candidate.overview,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          );
          final matchButton = OutlinedButton.icon(
            onPressed: busy ? null : () => _matchTmdb(candidate),
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('选择匹配'),
          );
          if (constraints.maxWidth < 440) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [description, const SizedBox(height: 8), matchButton],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: description),
              const SizedBox(width: 8),
              matchButton,
            ],
          );
        },
      ),
    );
  }

  String _timeLabel(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  SubtitleCue? get _activeCue {
    final position = _controller?.value.position;
    if (position == null) return null;
    for (final cue in _cues) {
      if (cue.contains(position)) return cue;
    }
    return null;
  }

  Widget _player(BuildContext context) {
    final controller = _controller;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (controller == null || !controller.value.isInitialized) {
      final canTranscode =
          !_film.canAttemptPlayback && _film.probeStatus != 'pending';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_transcodeStarting)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  ),
                )
              else
                Icon(
                  Icons.video_file_outlined,
                  size: 44,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              const SizedBox(height: 12),
              Text(_playbackMessage ?? '此视频无法播放。', textAlign: TextAlign.center),
              if (canTranscode && !_transcodeStarting) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => unawaited(
                    _startTranscode(
                      start: _film.canResume ? _film.position : 0,
                    ),
                  ),
                  icon: const Icon(Icons.auto_awesome, size: 17),
                  label: const Text('重试在线转码播放'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    final aspectRatio = controller.value.aspectRatio > 0
        ? controller.value.aspectRatio
        : 16 / 9;
    final compactControls =
        MediaQuery.sizeOf(context).width < 480 ||
        MediaQuery.textScalerOf(context).scale(14) > 20;
    final controlTextStyle = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: Colors.white);
    final playButton = IconButton(
      tooltip: controller.value.isPlaying ? '暂停' : '播放',
      color: Colors.white,
      onPressed: () async {
        if (controller.value.isPlaying) {
          await controller.pause();
          unawaited(_queueProgressSave(force: true));
        } else {
          await controller.play();
        }
        if (mounted) {
          setState(() {});
        }
      },
      icon: Icon(controller.value.isPlaying ? Icons.pause : Icons.play_arrow),
    );
    final positionLabel = Text(
      _timeLabel(
        Duration(milliseconds: (_originalPlaybackSeconds * 1000).round()),
      ),
      style: controlTextStyle,
    );
    final durationLabel = Text(
      _timeLabel(
        Duration(milliseconds: (_originalPlaybackDuration * 1000).round()),
      ),
      style: controlTextStyle,
    );
    Widget seekBar = VideoProgressIndicator(
      controller,
      allowScrubbing: true,
      padding: const EdgeInsets.symmetric(vertical: 9),
      colors: VideoProgressColors(
        playedColor: Theme.of(context).colorScheme.primary,
        bufferedColor: Colors.white54,
        backgroundColor: Colors.white24,
      ),
    );
    if (_hlsSession != null && _originalPlaybackDuration > 0) {
      final total = _originalPlaybackDuration;
      seekBar = Semantics(
        label: '原片完整进度',
        child: Slider(
          value: (_seekDraft ?? _originalPlaybackSeconds).clamp(0.0, total),
          min: 0,
          max: total,
          onChanged: _transcodeStarting
              ? null
              : (value) => setState(() => _seekDraft = value),
          onChangeEnd: (value) => unawaited(_seekAbsolute(value)),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final videoHeight = (constraints.maxWidth / aspectRatio)
            .clamp(0.0, 400.0)
            .toDouble();
        final videoWidth = videoHeight * aspectRatio;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: constraints.maxWidth,
              height: videoHeight,
              child: Center(
                child: SizedBox(
                  width: videoWidth,
                  height: videoHeight,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onDoubleTapDown: (details) {
                          final x = details.localPosition.dx;
                          if (x < videoWidth * .4) {
                            unawaited(_seekRelative(-10));
                          } else if (x > videoWidth * .6) {
                            unawaited(_seekRelative(10));
                          } else if (controller.value.isPlaying) {
                            unawaited(controller.pause());
                          } else {
                            unawaited(controller.play());
                          }
                        },
                        child: VideoPlayer(controller),
                      ),
                      if (_activeCue case final cue?)
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: Container(
                            margin: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: .78),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              cue.text,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: _subtitleFontSize,
                                height: 1.25,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 5, 10, 0),
              child: compactControls
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            playButton,
                            Expanded(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    positionLabel,
                                    const SizedBox(width: 12),
                                    durationLabel,
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: seekBar,
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        playButton,
                        positionLabel,
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: seekBar,
                          ),
                        ),
                        durationLabel,
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Wrap(
                spacing: 12,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  IconButton(
                    tooltip: '全屏播放',
                    color: Colors.white,
                    onPressed: _transcodeStarting
                        ? null
                        : () => unawaited(_showFullscreenPlayer()),
                    icon: const Icon(Icons.fullscreen),
                  ),
                  IconButton(
                    tooltip: '快退 10 秒',
                    color: Colors.white,
                    onPressed: _transcodeStarting
                        ? null
                        : () => unawaited(_seekRelative(-10)),
                    icon: const Icon(Icons.replay_10),
                  ),
                  IconButton(
                    tooltip: '快进 10 秒',
                    color: Colors.white,
                    onPressed: _transcodeStarting
                        ? null
                        : () => unawaited(_seekRelative(10)),
                    icon: const Icon(Icons.forward_10),
                  ),
                  Icon(
                    controller.value.volume == 0
                        ? Icons.volume_off
                        : Icons.volume_up,
                    size: 19,
                    color: Colors.white,
                  ),
                  Semantics(
                    label: '音量',
                    child: SizedBox(
                      width: 110,
                      child: Slider(
                        value: controller.value.volume
                            .clamp(0.0, 1.0)
                            .toDouble(),
                        onChanged: (value) => controller.setVolume(value),
                        activeColor: Theme.of(context).colorScheme.primary,
                        inactiveColor: Colors.white38,
                        semanticFormatterCallback: (value) =>
                            '音量 ${(value * 100).round()}%',
                      ),
                    ),
                  ),
                  DropdownButton<String>(
                    value: _captionLanguage,
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(color: Colors.white),
                    dropdownColor: const Color(0xFF202124),
                    iconEnabledColor: Colors.white,
                    iconDisabledColor: Colors.white54,
                    underline: const SizedBox.shrink(),
                    hint: const Text(
                      '字幕',
                      style: TextStyle(color: Colors.white70),
                    ),
                    onChanged: (value) {
                      if (value == 'import') {
                        unawaited(_importLocalSubtitles());
                      } else if (value != null && value != 'local') {
                        unawaited(_loadSubtitles(value));
                      }
                    },
                    items: <DropdownMenuItem<String>>[
                      const DropdownMenuItem(
                        value: 'off',
                        child: Text(
                          '关闭字幕',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      const DropdownMenuItem(
                        value: 'auto',
                        child: Text(
                          '同名字幕',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      const DropdownMenuItem(
                        value: 'zh',
                        child: Text(
                          '中文字幕',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      const DropdownMenuItem(
                        value: 'en',
                        child: Text(
                          '英文字幕',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      if (_captionLanguage == 'local')
                        const DropdownMenuItem(
                          value: 'local',
                          child: Text(
                            '本机字幕',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      const DropdownMenuItem(
                        value: 'import',
                        child: Text(
                          '导入字幕',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      for (final track
                          in _tracks?.subtitles ??
                              const <CinemaSubtitleTrack>[])
                        if (track.extractable)
                          DropdownMenuItem(
                            value: 'emb:${track.streamIndex}',
                            child: Text(
                              track.label,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                    ],
                  ),
                  if (_captionLanguage != 'off')
                    DropdownButton<double>(
                      value: _subtitleFontSize,
                      dropdownColor: const Color(0xFF202124),
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: Colors.white),
                      onChanged: (size) {
                        if (size != null) {
                          setState(() => _subtitleFontSize = size);
                        }
                      },
                      items: const [
                        DropdownMenuItem(value: 15.0, child: Text('字幕 小')),
                        DropdownMenuItem(value: 17.0, child: Text('字幕 标准')),
                        DropdownMenuItem(value: 21.0, child: Text('字幕 大')),
                        DropdownMenuItem(value: 25.0, child: Text('字幕 特大')),
                      ],
                    ),
                  DropdownButton<String>(
                    value: _hlsSession?.quality ?? 'source',
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(color: Colors.white),
                    dropdownColor: const Color(0xFF202124),
                    iconEnabledColor: Colors.white,
                    iconDisabledColor: Colors.white54,
                    underline: const SizedBox.shrink(),
                    hint: const Text(
                      '清晰度',
                      style: TextStyle(color: Colors.white70),
                    ),
                    onChanged: (value) {
                      if (value != null) unawaited(_switchQuality(value));
                    },
                    items: <DropdownMenuItem<String>>[
                      for (final option in _qualityOptions())
                        DropdownMenuItem(
                          value: option.$1,
                          child: Text(
                            option.$2,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                    ],
                  ),
                  MediaPlaybackSpeedPicker(
                    value: _playbackSpeed,
                    onChanged: (speed) => unawaited(_setPlaybackSpeed(speed)),
                  ),
                  if ((_tracks?.audio.length ?? 0) > 1 && _hlsSession != null)
                    DropdownButton<int>(
                      value: _hlsSession!.audioTrack,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: Colors.white),
                      dropdownColor: const Color(0xFF202124),
                      iconEnabledColor: Colors.white,
                      iconDisabledColor: Colors.white54,
                      underline: const SizedBox.shrink(),
                      hint: const Text(
                        '音轨',
                        style: TextStyle(color: Colors.white70),
                      ),
                      onChanged: (value) {
                        if (value != null) unawaited(_switchAudio(value));
                      },
                      items: <DropdownMenuItem<int>>[
                        for (final track
                            in _tracks?.audio ?? const <CinemaAudioTrack>[])
                          DropdownMenuItem(
                            value: track.audioIndex,
                            child: Text(
                              track.label,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _metadata(BuildContext context) {
    final format = <String>[
      _film.container.toUpperCase(),
      _film.videoCodec.toUpperCase(),
      _film.audioCodec.toUpperCase(),
    ].where((value) => value.isNotEmpty).join(' · ');
    final rows = <(IconData, String, String)>[
      (
        Icons.video_library_outlined,
        '类型',
        _film.isSeries
            ? '剧集 · 第 ${_film.season} 季 · 第 ${_film.episode} 集'
            : _film.year > 0
            ? '电影 · ${_film.year}'
            : '电影',
      ),
      (Icons.storage_outlined, '文件大小', formatMediaSize(_film.size)),
      (
        Icons.schedule_outlined,
        '时长',
        formatMediaSeconds(
          _film.durationSeconds > 0 ? _film.durationSeconds : _film.duration,
        ),
      ),
      if (_film.width > 0 && _film.height > 0)
        (
          Icons.aspect_ratio_outlined,
          '画面尺寸',
          '${_film.width} × ${_film.height}',
        ),
      if (format.isNotEmpty) (Icons.movie_outlined, '编码格式', format),
      if (_film.mime.isNotEmpty)
        (Icons.insert_drive_file_outlined, '媒体类型', _film.mime),
    ];
    return Wrap(
      spacing: 16,
      runSpacing: 12,
      children: [
        for (final row in rows)
          SizedBox(
            width: 230,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  row.$1,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.$2,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(row.$3),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
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
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 12, 10),
                    child: Row(
                      children: [
                        Hero(
                          tag: 'cinema_poster_${_film.id}',
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(
                              width: 38,
                              height: 54,
                              child: AuthenticatedMediaImage(
                                api: widget.api,
                                path: '/api/v2/cinema/${_film.id}/poster',
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
                                _film.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleLarge
                                    ?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -0.3,
                                    ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _film.isSeries
                                    ? '第 ${_film.season} 季 · 第 ${_film.episode} 集'
                                    : '电影详情',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        if (widget.isAdmin)
                          IconButton.filledTonal(
                            tooltip: '修改展示名称',
                            onPressed: _busy
                                ? null
                                : () async {
                                    setState(() => _busy = true);
                                    try {
                                      final updated = await widget.onRename(
                                        _film,
                                      );
                                      if (mounted) {
                                        setState(() => _film = updated);
                                      }
                                    } catch (error) {
                                      if (mounted) {
                                        setState(
                                          () => _playbackMessage =
                                              mediaErrorLabel(error),
                                        );
                                      }
                                    } finally {
                                      if (mounted) {
                                        setState(() => _busy = false);
                                      }
                                    }
                                  },
                            icon: const Icon(Icons.edit_outlined),
                          ),
                        PopupMenuButton<String>(
                          tooltip: '分享或保存影片',
                          enabled: !_mediaActionBusy && !_closing,
                          onSelected: (value) => unawaited(_mediaAction(value)),
                          itemBuilder: (context) => [
                            const PopupMenuItem(
                              value: 'share',
                              child: Text('分享影片（限时链接）'),
                            ),
                            const PopupMenuItem(
                              value: 'export',
                              child: Text('保存原始视频'),
                            ),
                            if (widget.accountName.isNotEmpty)
                              const PopupMenuItem(
                                value: 'offline',
                                child: Text('保存到离线库'),
                              ),
                            if (_castSession == null)
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
                          onPressed: _closing ? null : _close,
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
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
}
