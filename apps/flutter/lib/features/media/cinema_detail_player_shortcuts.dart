part of 'cinema_detail_dialog.dart';

double? _sessionCinemaVolume;
double? _sessionCinemaSpeed;

extension _CinemaDetailPlayerShortcuts on _CinemaDetailDialogState {
  String _formatSpeedBadge(double speed) {
    final text = speed
        .toStringAsFixed(2)
        .replaceAll(RegExp(r'0+$'), '')
        .replaceAll(RegExp(r'\.$'), '');
    return '${text}x';
  }

  void _showShortcutHud(
    IconData icon,
    String label, {
    bool persistent = false,
  }) {
    _hud.hideTimer?.cancel();
    _updateState(() {
      _hud.icon = icon;
      _hud.label = label;
    });
    if (persistent) return;
    _hud.hideTimer = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      _updateState(() {
        _hud.icon = null;
        _hud.label = null;
      });
    });
  }

  Future<void> _restorePlaybackVolume() async {
    final cached = _sessionCinemaVolume;
    if (cached != null) {
      _playback.volume = cached;
      if (cached > 0) _playback.lastNonZeroVolume = cached;
      await _playback.controller?.setVolume(cached);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble('lightisle_cinema_volume');
      if (!mounted || saved == null || !saved.isFinite) return;
      final clamped = saved.clamp(0.0, 1.0).toDouble();
      _sessionCinemaVolume = clamped;
      _updateState(() {
        _playback.volume = clamped;
        if (clamped > 0) _playback.lastNonZeroVolume = clamped;
      });
      await _playback.controller?.setVolume(clamped);
    } catch (_) {
      /* Missing test/desktop prefs must never block playback. */
    }
  }

  Future<void> _setPlayerVolume(double value, {bool showHud = false}) async {
    final clamped = value.clamp(0.0, 1.0).toDouble();
    _sessionCinemaVolume = clamped;
    _updateState(() {
      _playback.volume = clamped;
      if (clamped > 0) _playback.lastNonZeroVolume = clamped;
    });
    await _playback.controller?.setVolume(clamped);
    if (showHud) {
      final pct = (clamped * 100).round();
      _showShortcutHud(
        clamped == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
        clamped == 0 ? '已静音' : '音量 $pct%',
      );
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('lightisle_cinema_volume', clamped);
    } catch (_) {}
  }

  Future<void> _toggleMuteShortcut() async {
    final controller = _playback.controller;
    final current = controller?.value.volume ?? _playback.volume;
    if (current > 0.001) {
      _playback.lastNonZeroVolume = current;
      await _setPlayerVolume(0, showHud: true);
    } else {
      final restore = _playback.lastNonZeroVolume > 0.01
          ? _playback.lastNonZeroVolume
          : 1.0;
      await _setPlayerVolume(restore, showHud: true);
    }
  }

  void _enterHold2xFastForward() {
    final controller = _playback.controller;
    if (!_hud.rightKeyDown ||
        _hud.rightHold2xActive ||
        controller == null ||
        !controller.value.isInitialized) {
      return;
    }
    _hud.speedBeforeHold = _playback.playbackSpeed;
    _hud.rightHold2xActive = true;
    unawaited(controller.setPlaybackSpeed(2.0));
    _showShortcutHud(
      Icons.fast_forward_rounded,
      '2.0x 倍速播放中',
      persistent: true,
    );
  }

  void _finishRightArrowHoldOrSeek() {
    _hud.rightHoldTimer?.cancel();
    _hud.rightHoldTimer = null;
    final wasHold = _hud.rightHold2xActive;
    _hud.rightKeyDown = false;
    _hud.rightHold2xActive = false;
    final controller = _playback.controller;
    if (wasHold) {
      if (controller != null && controller.value.isInitialized) {
        unawaited(controller.setPlaybackSpeed(_hud.speedBeforeHold));
      }
      _showShortcutHud(
        Icons.speed_rounded,
        '已恢复 ${_formatSpeedBadge(_hud.speedBeforeHold)}',
      );
      return;
    }
    _revealChrome();
    unawaited(_seekRelative(10));
    _showShortcutHud(Icons.forward_10_rounded, '快进 10 秒');
  }

  KeyEventResult _onPlayerKey(FocusNode node, KeyEvent event) {
    if (_playback.closing || !widget.playerOnly) {
      return KeyEventResult.ignored;
    }
    if (ModalRoute.of(context)?.isCurrent == false) {
      return KeyEventResult.ignored;
    }
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.escape) {
      if (event is! KeyDownEvent) return KeyEventResult.handled;
      if (_chrome.showPlaylistSheet) {
        _updateState(() => _chrome.showPlaylistSheet = false);
        return KeyEventResult.handled;
      }
      if (_chrome.showPlayerDetails) {
        _updateState(() => _chrome.showPlayerDetails = false);
        return KeyEventResult.handled;
      }
      if (_chrome.windowFullscreen) {
        unawaited(_toggleFullscreen());
        return KeyEventResult.handled;
      }
      unawaited(_close());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      if (event is KeyDownEvent) unawaited(_toggleFullscreen());
      return KeyEventResult.handled;
    }

    final controller = _playback.controller;
    if (controller == null || !controller.value.isInitialized) {
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.space) {
      // Absorb Down/Repeat/Up unconditionally so a focused transport button
      // never double-triggers Play/Pause or triggers the wrong button.
      if (event is KeyDownEvent) {
        if (controller.value.isPlaying) {
          unawaited(controller.pause());
          unawaited(_queueProgressSave(force: true));
          _showShortcutHud(Icons.pause_rounded, '已暂停');
        } else {
          unawaited(controller.play());
          _showShortcutHud(Icons.play_arrow_rounded, '正在播放');
        }
        _revealChrome();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowRight) {
      if (event is KeyDownEvent) {
        _hud.rightKeyDown = true;
        _hud.rightHold2xActive = false;
        _hud.rightHoldTimer?.cancel();
        _hud.rightHoldTimer = Timer(
          const Duration(milliseconds: 280),
          _enterHold2xFastForward,
        );
      } else if (event is KeyUpEvent && _hud.rightKeyDown) {
        _finishRightArrowHoldOrSeek();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft) {
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        _revealChrome();
        unawaited(_seekRelative(-10));
        _showShortcutHud(Icons.replay_10_rounded, '后退 10 秒');
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        final next = ((controller.value.volume) + 0.05).clamp(0.0, 1.0);
        unawaited(_setPlayerVolume(next, showHud: true));
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowDown) {
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        final next = ((controller.value.volume) - 0.05).clamp(0.0, 1.0);
        unawaited(_setPlayerVolume(next, showHud: true));
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyM) {
      if (event is KeyDownEvent) unawaited(_toggleMuteShortcut());
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  Widget _buildPlayerShortcutHud() {
    final label = _hud.label;
    if (label == null || label.isEmpty) return const SizedBox.shrink();
    return Positioned(
      top: 72,
      left: 16,
      right: 16,
      child: IgnorePointer(
        child: Center(
          child: ClipRRect(
            key: const ValueKey('cinemaShortcutHudPill'),
            borderRadius: BorderRadius.circular(999),
            child: IsleGlassBackdrop(
              blur: 18,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xBD0D1017),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: const Color(0x33FFFFFF),
                    width: 0.8,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_hud.icon != null) ...[
                      Icon(_hud.icon, size: 17, color: Colors.white),
                      const SizedBox(width: 7),
                    ],
                    Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
