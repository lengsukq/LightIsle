import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/isle_theme.dart';

/// Wraps a poster or media card with Android TV / Apple TV D-Pad remote focus
/// highlight ring, subtle spring scale, and Select / Enter / GameButtonA
/// activation while preserving pointer and touch interactions.
class CinemaTvFocusable extends StatefulWidget {
  const CinemaTvFocusable({
    super.key,
    required this.onActivate,
    this.onLongActivate,
    required this.child,
    this.borderRadius = IsleRadius.brControl,
  });

  final VoidCallback onActivate;
  final VoidCallback? onLongActivate;
  final Widget child;
  final BorderRadius borderRadius;

  @override
  State<CinemaTvFocusable> createState() => _CinemaTvFocusableState();
}

class _CinemaTvFocusableState extends State<CinemaTvFocusable> {
  bool _focused = false;

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.space) {
      HapticFeedback.selectionClick();
      widget.onActivate();
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.contextMenu ||
            key == LogicalKeyboardKey.gameButtonX) &&
        widget.onLongActivate != null) {
      HapticFeedback.mediumImpact();
      widget.onLongActivate!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Focus(
      onFocusChange: (hasFocus) {
        if (_focused == hasFocus) return;
        setState(() => _focused = hasFocus);
        if (hasFocus) {
          Scrollable.ensureVisible(
            context,
            alignmentPolicy:
                ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
            duration: IsleMotion.fast,
          );
        }
      },
      onKeyEvent: _handleKeyEvent,
      child: AnimatedScale(
        scale: _focused ? 1.045 : 1.0,
        duration: IsleMotion.fast,
        curve: IsleMotion.spring,
        child: AnimatedContainer(
          duration: IsleMotion.fast,
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: primary.withValues(alpha: 0.42),
                      blurRadius: 16,
                      spreadRadius: 1.5,
                    ),
                  ]
                : const [],
          ),
          foregroundDecoration: _focused
              ? BoxDecoration(
                  borderRadius: widget.borderRadius,
                  border: Border.all(color: primary, width: 2.6),
                )
              : null,
          child: widget.child,
        ),
      ),
    );
  }
}
