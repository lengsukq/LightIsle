import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';

/// A single gesture surface for authenticated NAS thumbnails and local files.
/// The caller owns the image loading/authorization; PhotoView never fetches a
/// URL or receives credentials. It only handles touch, mouse and trackpad input.
class PhotoZoomSurface extends StatefulWidget {
  const PhotoZoomSurface({
    super.key,
    required this.child,
    this.aspectRatio,
    this.onTap,
    this.onZoomChanged,
    this.active = true,
    this.allowHorizontalPageSwipe = false,
    this.onSwipeDown,
    this.onSwipeUp,
  });

  final Widget child;
  final double? aspectRatio;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onZoomChanged;
  final bool active;

  /// Shares horizontal drags with the gallery while preserving pan at zoom.
  final bool allowHorizontalPageSwipe;

  /// Called after a deliberate downward drag at the fitted image scale.
  final VoidCallback? onSwipeDown;

  /// Optional upward gesture for the photo information sheet.
  final VoidCallback? onSwipeUp;

  @override
  State<PhotoZoomSurface> createState() => _PhotoZoomSurfaceState();
}

class _PhotoZoomSurfaceState extends State<PhotoZoomSurface> {
  final PhotoViewController _controller = PhotoViewController();
  StreamSubscription<PhotoViewControllerValue>? _subscription;
  bool _zoomed = false;
  int _pointerCount = 0;
  int? _dragPointer;
  Offset? _dragOrigin;
  Duration? _dragStart;
  bool _verticalDrag = false;
  bool _settling = false;
  double _dragDistance = 0;
  int? _tapPointer;
  Offset? _tapOrigin;
  Duration? _tapStart;
  Duration? _previousTapTime;
  Offset? _previousTapPosition;
  bool _tapMoved = false;

  void _resetDrag({bool animate = true}) {
    _dragPointer = null;
    _dragOrigin = null;
    _dragStart = null;
    _verticalDrag = false;
    if (_dragDistance != 0 && mounted) {
      setState(() {
        _settling = animate;
        _dragDistance = 0;
      });
    }
  }

  void _handleTap(PointerEvent event) {
    if (event.pointer != _tapPointer) return;
    final firstPosition = _tapOrigin;
    final start = _tapStart;
    _tapPointer = null;
    if (_tapMoved ||
        firstPosition == null ||
        start == null ||
        (event.timeStamp - start).inMilliseconds > 250 ||
        (event.localPosition - firstPosition).distance > 14) {
      _previousTapTime = null;
      return;
    }
    final previous = _previousTapTime;
    final previousPosition = _previousTapPosition;
    if (previous != null &&
        previousPosition != null &&
        (event.timeStamp - previous).inMilliseconds < 330 &&
        (event.localPosition - previousPosition).distance < 48) {
      _previousTapTime = null;
      final viewport = context.size;
      if (viewport == null) return;
      // PhotoView's default double-tap uses 'covering', which may equal 1x
      // for a fitted custom child. Drive a predictable 2.5x transform around
      // the tap location instead, without exposing the authenticated image.
      final scale = _zoomed ? 1.0 : 2.5;
      final target = _zoomed
          ? Offset.zero
          : Offset(
              (viewport.width / 2 - event.localPosition.dx) * (scale - 1),
              (viewport.height / 2 - event.localPosition.dy) * (scale - 1),
            );
      _controller.updateMultiple(scale: scale, position: target);
      return;
    }
    _previousTapTime = event.timeStamp;
    _previousTapPosition = event.localPosition;
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointerCount++;
    if (_pointerCount == 1 && widget.active) {
      _tapPointer = event.pointer;
      _tapOrigin = event.localPosition;
      _tapStart = event.timeStamp;
      _tapMoved = false;
    } else {
      _tapPointer = null;
      _previousTapTime = null;
    }
    if (_pointerCount != 1 ||
        !widget.active ||
        _zoomed ||
        (widget.onSwipeDown == null && widget.onSwipeUp == null)) {
      _resetDrag();
      return;
    }
    _dragPointer = event.pointer;
    _dragOrigin = event.localPosition;
    _dragStart = event.timeStamp;
    _verticalDrag = false;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer == _tapPointer &&
        _tapOrigin != null &&
        (event.localPosition - _tapOrigin!).distance > 12) {
      _tapMoved = true;
    }
    if (_pointerCount != 1 ||
        event.pointer != _dragPointer ||
        _dragOrigin == null ||
        _zoomed) {
      return;
    }
    final distance = event.localPosition - _dragOrigin!;
    if (!_verticalDrag) {
      if (distance.dy.abs() < 18 ||
          distance.dy.abs() < distance.dx.abs() * 1.35 ||
          (distance.dy > 0 ? widget.onSwipeDown : widget.onSwipeUp) == null) {
        return;
      }
      _verticalDrag = true;
    }
    if (distance.dy.sign != _dragDistance.sign && _dragDistance != 0) {
      _resetDrag();
      return;
    }
    setState(() {
      _settling = false;
      _dragDistance = distance.dy;
    });
  }

  void _onPointerEnd(PointerEvent event) {
    _pointerCount = math.max(0, _pointerCount - 1);
    _handleTap(event);
    if (event.pointer != _dragPointer) return;
    final distance = _dragDistance;
    final elapsed = event.timeStamp - (_dragStart ?? event.timeStamp);
    final speed = elapsed.inMilliseconds > 0
        ? distance.abs() * 1000 / elapsed.inMilliseconds
        : 0.0;
    final viewport = context.size?.height ?? 600;
    final threshold = math.min(140.0, math.max(85.0, viewport * 0.18));
    final complete =
        _verticalDrag &&
        (distance.abs() >= threshold || (distance.abs() >= 60 && speed >= 950));
    _resetDrag();
    if (complete && mounted) {
      if (distance > 0) {
        widget.onSwipeDown?.call();
      } else {
        widget.onSwipeUp?.call();
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _subscription = _controller.outputStateStream.listen((value) {
      if (!mounted || !widget.active) return;
      // The image is fitted inside the viewport before PhotoView transforms
      // it, so 1.0 represents the normal, unzoomed view.
      final zoomed = (value.scale ?? 1) > 1.01;
      if (zoomed != _zoomed) {
        _zoomed = zoomed;
        if (zoomed) _resetDrag();
        widget.onZoomChanged?.call(zoomed);
      }
    });
  }

  @override
  void didUpdateWidget(covariant PhotoZoomSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) {
      _zoomed = false;
      _resetDrag();
      _controller.reset();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        if (!viewport.width.isFinite ||
            !viewport.height.isFinite ||
            viewport.isEmpty) {
          return widget.child;
        }
        final ratio = widget.aspectRatio;
        var size = viewport;
        if (ratio != null && ratio.isFinite && ratio > 0) {
          final width = math.min(viewport.width, viewport.height * ratio);
          size = Size(width, width / ratio);
        }
        final viewer = PhotoView.customChild(
          controller: _controller,
          childSize: size,
          backgroundDecoration: const BoxDecoration(color: Colors.transparent),
          initialScale: PhotoViewComputedScale.contained,
          minScale: PhotoViewComputedScale.contained,
          maxScale: PhotoViewComputedScale.contained * 5,
          enableRotation: false,
          // The built-in 'covering' double-tap often stays at 1x for our
          // pre-fitted custom child; the pointer listener handles it above.
          scaleStateCycle: (current) => current,
          onTapUp: (context, details, controllerValue) => widget.onTap?.call(),
          child: SizedBox.fromSize(size: size, child: widget.child),
        );
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerEnd,
          onPointerCancel: (event) {
            _pointerCount = math.max(0, _pointerCount - 1);
            _tapPointer = null;
            _previousTapTime = null;
            _resetDrag();
          },
          child: AnimatedSlide(
            duration: _settling
                ? const Duration(milliseconds: 180)
                : Duration.zero,
            curve: Curves.easeOutCubic,
            offset: Offset(0, _dragDistance / viewport.height),
            child: AnimatedScale(
              duration: _settling
                  ? const Duration(milliseconds: 180)
                  : Duration.zero,
              curve: Curves.easeOutCubic,
              scale:
                  1 - math.min(.14, _dragDistance.abs() / viewport.height * .4),
              child: widget.allowHorizontalPageSwipe
                  ? PhotoViewGestureDetectorScope(
                      axis: Axis.horizontal,
                      child: viewer,
                    )
                  : viewer,
            ),
          ),
        );
      },
    ),
  );
}
