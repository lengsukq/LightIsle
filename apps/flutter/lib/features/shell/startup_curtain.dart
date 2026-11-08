import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';

/// Elegant sanctuary opening experience matching the macOS & iOS sanctuary branding,
/// with fluid halo ripples, staggered typography, and a refined shimmer indicator.
class StartupCurtain extends StatefulWidget {
  const StartupCurtain({super.key, this.exiting = false});

  final bool exiting;

  @override
  State<StartupCurtain> createState() => _StartupCurtainState();
}

class _StartupCurtainState extends State<StartupCurtain>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _logoScale;
  late final Animation<double> _logoOpacity;
  late final Animation<double> _ripple1Scale;
  late final Animation<double> _ripple1Opacity;
  late final Animation<double> _ripple2Scale;
  late final Animation<double> _ripple2Opacity;
  late final Animation<double> _titleOpacity;
  late final Animation<Offset> _titleSlide;
  late final Animation<double> _sloganOpacity;
  late final Animation<Offset> _sloganSlide;
  late final Animation<double> _shimmerOpacity;
  late final Animation<double> _shimmerPosition;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    // Brand emblem bloom
    _logoScale = Tween<double>(begin: 0.82, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.58, curve: Curves.easeOutBack),
      ),
    );
    _logoOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.38, curve: Curves.easeOut),
      ),
    );

    // Oceanic ripple wave 1 (outer)
    _ripple1Scale = Tween<double>(begin: 0.70, end: 1.25).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.05, 0.75, curve: Curves.easeOutCubic),
      ),
    );
    _ripple1Opacity =
        TweenSequence<double>([
          TweenSequenceItem(tween: Tween(begin: 0.0, end: 0.40), weight: 35),
          TweenSequenceItem(tween: Tween(begin: 0.40, end: 0.15), weight: 65),
        ]).animate(
          CurvedAnimation(
            parent: _controller,
            curve: const Interval(0.05, 0.75, curve: Curves.easeInOut),
          ),
        );

    // Halo ring 2 (inner)
    _ripple2Scale = Tween<double>(begin: 0.85, end: 1.08).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.12, 0.85, curve: Curves.easeOutCubic),
      ),
    );
    _ripple2Opacity =
        TweenSequence<double>([
          TweenSequenceItem(tween: Tween(begin: 0.0, end: 0.55), weight: 45),
          TweenSequenceItem(tween: Tween(begin: 0.55, end: 0.25), weight: 55),
        ]).animate(
          CurvedAnimation(
            parent: _controller,
            curve: const Interval(0.12, 0.85, curve: Curves.easeInOut),
          ),
        );

    // Title entrance
    _titleOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.20, 0.62, curve: Curves.easeOut),
      ),
    );
    _titleSlide = Tween<Offset>(begin: const Offset(0, 14), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _controller,
            curve: const Interval(0.20, 0.68, curve: Curves.easeOutCubic),
          ),
        );

    // Slogan entrance
    _sloganOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.35, 0.75, curve: Curves.easeOut),
      ),
    );
    _sloganSlide = Tween<Offset>(begin: const Offset(0, 10), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _controller,
            curve: const Interval(0.35, 0.80, curve: Curves.easeOutCubic),
          ),
        );

    // Shimmer bar entrance and sweep
    _shimmerOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.48, 0.78, curve: Curves.easeOut),
      ),
    );
    _shimmerPosition = Tween<double>(begin: -0.4, end: 1.4).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.48, 0.98, curve: Curves.easeInOutCubic),
      ),
    );

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette.of(context);
    final primary = theme.colorScheme.primary;
    final cyan = palette['brandCyan'];
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final highContrast = MediaQuery.highContrastOf(context);

    if (disableAnimations && _controller.value < 1.0) {
      _controller.value = 1.0;
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            palette['canvasTop'],
            Color.lerp(palette['canvasBottom'], primary, isDark ? 0.12 : 0.06)!,
          ],
        ),
      ),
      child: SafeArea(
        child: Center(
          child: AnimatedScale(
            scale: widget.exiting && !disableAnimations ? 1.05 : 1.0,
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOutCubic,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final logoScaleVal = disableAnimations ? 1.0 : _logoScale.value;
                final logoOpacityVal = disableAnimations
                    ? 1.0
                    : _logoOpacity.value;
                final r1ScaleVal = disableAnimations
                    ? 1.0
                    : _ripple1Scale.value;
                final r1OpacityVal = disableAnimations
                    ? 0.18
                    : _ripple1Opacity.value;
                final r2ScaleVal = disableAnimations
                    ? 1.0
                    : _ripple2Scale.value;
                final r2OpacityVal = disableAnimations
                    ? 0.30
                    : _ripple2Opacity.value;
                final titleOpacityVal = disableAnimations
                    ? 1.0
                    : _titleOpacity.value;
                final titleSlideVal = disableAnimations
                    ? Offset.zero
                    : _titleSlide.value;
                final sloganOpacityVal = disableAnimations
                    ? 1.0
                    : _sloganOpacity.value;
                final sloganSlideVal = disableAnimations
                    ? Offset.zero
                    : _sloganSlide.value;
                final shimmerOpacityVal = disableAnimations
                    ? 1.0
                    : _shimmerOpacity.value;
                final shimmerPosVal = disableAnimations
                    ? 0.5
                    : _shimmerPosition.value;

                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 216,
                      height: 216,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // Ripple 1 (Outer soft ocean wave)
                          if (!disableAnimations && r1OpacityVal > 0.001)
                            Transform.scale(
                              scale: r1ScaleVal,
                              child: Container(
                                width: 164,
                                height: 164,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: primary.withValues(
                                      alpha: (r1OpacityVal * 0.55).clamp(
                                        0.0,
                                        1.0,
                                      ),
                                    ),
                                    width: 1.2,
                                  ),
                                  gradient: RadialGradient(
                                    colors: [
                                      primary.withValues(
                                        alpha: (r1OpacityVal * 0.12).clamp(
                                          0.0,
                                          1.0,
                                        ),
                                      ),
                                      Colors.transparent,
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          // Ripple 2 (Inner cyan halo)
                          if (!disableAnimations && r2OpacityVal > 0.001)
                            Transform.scale(
                              scale: r2ScaleVal,
                              child: Container(
                                width: 136,
                                height: 136,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: cyan.withValues(
                                      alpha: (r2OpacityVal * 0.50).clamp(
                                        0.0,
                                        1.0,
                                      ),
                                    ),
                                    width: 1.0,
                                  ),
                                  gradient: RadialGradient(
                                    colors: [
                                      cyan.withValues(
                                        alpha: (r2OpacityVal * 0.15).clamp(
                                          0.0,
                                          1.0,
                                        ),
                                      ),
                                      Colors.transparent,
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          // Brand Vessel with subtle glass rim and soft floating shadow
                          Opacity(
                            opacity: logoOpacityVal.clamp(0.0, 1.0),
                            child: Transform.scale(
                              scale: logoScaleVal,
                              child: Container(
                                width: 116,
                                height: 116,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isDark
                                      ? palette['cardTop'].withValues(
                                          alpha: 0.88,
                                        )
                                      : palette['cardTop'].withValues(
                                          alpha: 0.96,
                                        ),
                                  border: Border.all(
                                    color: highContrast
                                        ? theme.colorScheme.outline
                                        : isDark
                                        ? IsleTokens.nativeDark['rim']!
                                              .withValues(alpha: 0.40)
                                        : IsleTokens.nativeLight['rim']!
                                              .withValues(alpha: 0.65),
                                    width: highContrast ? 1.5 : 1.0,
                                  ),
                                  boxShadow: IsleShadows.floating(isDark),
                                ),
                                child: const Center(
                                  child: IsleBrandMark(size: 76),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    Opacity(
                      opacity: titleOpacityVal.clamp(0.0, 1.0),
                      child: Transform.translate(
                        offset: titleSlideVal,
                        child: Text(
                          '轻屿 LightIsle',
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.6,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Opacity(
                      opacity: sloganOpacityVal.clamp(0.0, 1.0),
                      child: Transform.translate(
                        offset: sloganSlideVal,
                        child: Text(
                          '让每一份珍藏，自在归屿',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 36),
                    Opacity(
                      opacity: shimmerOpacityVal.clamp(0.0, 1.0),
                      child: _SanctuaryShimmerBar(
                        position: shimmerPosVal,
                        primaryColor: primary,
                        highlightColor: cyan,
                        isDark: isDark,
                        disableAnimations: disableAnimations,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _SanctuaryShimmerBar extends StatelessWidget {
  const _SanctuaryShimmerBar({
    required this.position,
    required this.primaryColor,
    required this.highlightColor,
    required this.isDark,
    required this.disableAnimations,
  });

  final double position;
  final Color primaryColor;
  final Color highlightColor;
  final bool isDark;
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) {
    const width = 120.0;
    const height = 3.5;
    const radius = 2.0;

    return Semantics(
      label: '正在连接轻屿',
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: primaryColor.withValues(alpha: isDark ? 0.16 : 0.08),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: disableAnimations
              ? Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(radius),
                    color: primaryColor.withValues(alpha: 0.5),
                  ),
                )
              : CustomPaint(
                  size: const Size(width, height),
                  painter: _ShimmerBeamPainter(
                    position: position,
                    primaryColor: primaryColor,
                    highlightColor: highlightColor,
                  ),
                ),
        ),
      ),
    );
  }
}

class _ShimmerBeamPainter extends CustomPainter {
  _ShimmerBeamPainter({
    required this.position,
    required this.primaryColor,
    required this.highlightColor,
  });

  final double position;
  final Color primaryColor;
  final Color highlightColor;

  @override
  void paint(Canvas canvas, Size size) {
    final beamWidth = size.width * 0.42;
    final startX = (size.width + beamWidth) * position - beamWidth;
    final endX = startX + beamWidth;

    final paint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(startX, 0),
        Offset(endX, 0),
        [
          Colors.transparent,
          primaryColor.withValues(alpha: 0.35),
          highlightColor,
          primaryColor.withValues(alpha: 0.35),
          Colors.transparent,
        ],
        const [0.0, 0.25, 0.50, 0.75, 1.0],
      );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, size.height),
        const Radius.circular(2),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _ShimmerBeamPainter oldDelegate) =>
      oldDelegate.position != position ||
      oldDelegate.primaryColor != primaryColor ||
      oldDelegate.highlightColor != highlightColor;
}
