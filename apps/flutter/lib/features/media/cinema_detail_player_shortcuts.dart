import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/widgets.dart';
import 'cinema_detail_controller.dart';
import 'cinema_detail_state_models.dart';

/// Handles desktop/hardware keyboard shortcuts for the media-first cinema
/// player route.
abstract final class CinemaPlayerShortcuts {
  static KeyEventResult handleKeyEvent({
    required BuildContext context,
    required CinemaDetailController controller,
    required FocusNode node,
    required KeyEvent event,
    required VoidCallback onClose,
  }) {
    if (controller.playback.closing || !controller.playerOnly) {
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
      if (controller.chrome.showPlaylistSheet) {
        controller.setShowPlaylistSheet(false);
        return KeyEventResult.handled;
      }
      if (controller.chrome.showPlayerDetails) {
        controller.setShowPlayerDetails(false);
        return KeyEventResult.handled;
      }
      if (controller.chrome.windowFullscreen) {
        unawaited(controller.toggleFullscreen());
        return KeyEventResult.handled;
      }
      onClose();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      if (event is KeyDownEvent) unawaited(controller.toggleFullscreen());
      return KeyEventResult.handled;
    }

    final video = controller.playback.controller;
    if (video == null || !video.value.isInitialized) {
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.space) {
      // Absorb Down/Repeat/Up unconditionally so a focused transport button
      // never double-triggers Play/Pause or triggers the wrong button.
      if (event is KeyDownEvent) {
        if (video.value.isPlaying) {
          unawaited(video.pause());
          unawaited(controller.queueProgressSave(force: true));
          controller.showShortcutHud(Icons.pause_rounded, '已暂停');
        } else {
          unawaited(video.play());
          controller.showShortcutHud(Icons.play_arrow_rounded, '正在播放');
        }
        controller.revealChrome();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowRight) {
      if (event is KeyDownEvent) {
        controller.startRightArrowHold();
      } else if (event is KeyUpEvent && controller.hud.rightKeyDown) {
        controller.finishRightArrowHoldOrSeek();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft) {
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        controller.revealChrome();
        unawaited(controller.seekRelative(-10));
        controller.showShortcutHud(Icons.replay_10_rounded, '后退 10 秒');
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        final next = (video.value.volume + 0.05).clamp(0.0, 1.0);
        unawaited(controller.setPlayerVolume(next, showHud: true));
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowDown) {
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        final next = (video.value.volume - 0.05).clamp(0.0, 1.0);
        unawaited(controller.setPlayerVolume(next, showHud: true));
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyM) {
      if (event is KeyDownEvent) unawaited(controller.toggleMuteShortcut());
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }
}

/// Floating pill overlay displaying transient keyboard shortcut feedback
/// (volume, mute, seek, 2.0x hold speed).
class CinemaPlayerShortcutHud extends StatelessWidget {
  const CinemaPlayerShortcutHud({super.key, required this.hud});

  final CinemaShortcutHudState hud;

  @override
  Widget build(BuildContext context) {
    final label = hud.label;
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
                    if (hud.icon != null) ...[
                      Icon(hud.icon, size: 17, color: Colors.white),
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
