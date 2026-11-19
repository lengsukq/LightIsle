import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';

/// Warm Editorial Gallery opening curtain with terracotta & mineral celadon
/// concentric halos, sculpted emblem vessel, and warm shimmer bar.
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
      duration: const Duration(milliseconds: 960),
    );

    _logoScale = Tween<double>(begin: 0.88, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.62, curve: IsleMotion.gentleSpring),
      ),
    );
    _logoOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.36, curve: Curves.easeOut),
      ),
    );

    _ripple1Scale = Tween<double>(begin: 0.74, end: 1.20).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.05, 0.75, curve: Curves.easeOutCubic),
      ),
    );
    _ripple1Opacity =
        TweenSequence<double>([
          TweenSequenceItem(tween: Tween(begin: 0.0, end: 0.32), weight: 35),
          TweenSequenceItem(tween: Tween(begin: 0.32, end: 0.10), weight: 65),
        ]).animate(
          CurvedAnimation(
            parent: _controller,
            curve: const Interval(0.05, 0.75, curve: Curves.easeInOut),
          ),
        );

    _ripple2Scale = Tween<double>(begin: 0.86, end: 1.06).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.12, 0.85, curve: Curves.easeOutCubic),
      ),
    );
    _ripple2Opacity =
        TweenSequence<double>([
          TweenSequenceItem(tween: Tween(begin: 0.0, end: 0.44), weight: 45),
          TweenSequenceItem(tween: Tween(begin: 0.44, end: 0.18), weight: 55),
        ]).animate(
          CurvedAnimation(
            parent: _controller,
            curve: const Interval(0.12, 0.85, curve: Curves.easeInOut),
          ),
        );

    _titleOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.20, 0.62, curve: Curves.easeOut),
      ),
    );
    _titleSlide = Tween<Offset>(begin: const Offset(0, 10), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _controller,
            curve: const Interval(0.20, 0.70, curve: IsleMotion.gentleSpring),
          ),
        );

    _sloganOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.35, 0.75, curve: Curves.easeOut),
      ),
    );
    _sloganSlide = Tween<Offset>(begin: const Offset(0, 8), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _controller,
            curve: const Interval(0.35, 0.82, curve: IsleMotion.gentleSpring),
          ),
        );

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

  List<Widget> _buildAmbientGlows({
    required Color terracotta,
    required Color mineral,
    required bool isDark,
  }) => [
    Positioned(
      top: -80,
      left: -60,
      width: 320,
      height: 320,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                terracotta.withValues(alpha: isDark ? 0.11 : 0.09),
                terracotta.withValues(alpha: 0.0),
              ],
            ),
          ),
        ),
      ),
    ),
    Positioned(
      bottom: -90,
      right: -60,
      width: 340,
      height: 340,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                mineral.withValues(alpha: isDark ? 0.10 : 0.07),
                mineral.withValues(alpha: 0.0),
              ],
            ),
          ),
        ),
      ),
    ),
  ];

  Widget _buildAnimatedVesselStack({
    required ThemeData theme,
    required IslePalette palette,
    required Color primary,
    required Color terracotta,
    required bool isDark,
    required bool highContrast,
    required bool disableAnimations,
  }) {
    final logoScaleVal = disableAnimations ? 1.0 : _logoScale.value;
    final logoOpacityVal = disableAnimations ? 1.0 : _logoOpacity.value;
    final r1ScaleVal = disableAnimations ? 1.0 : _ripple1Scale.value;
    final r1OpacityVal = disableAnimations ? 0.14 : _ripple1Opacity.value;
    final r2ScaleVal = disableAnimations ? 1.0 : _ripple2Scale.value;
    final r2OpacityVal = disableAnimations ? 0.22 : _ripple2Opacity.value;

    return SizedBox(
      width: 176,
      height: 176,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (!disableAnimations && r1OpacityVal > 0.001)
            Transform.scale(
              scale: r1ScaleVal,
              child: Container(
                width: 142,
                height: 142,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: terracotta.withValues(
                      alpha: (r1OpacityVal * 0.46).clamp(0.0, 1.0),
                    ),
                    width: 1.0,
                  ),
                ),
              ),
            ),
          if (!disableAnimations && r2OpacityVal > 0.001)
            Transform.scale(
              scale: r2ScaleVal,
              child: Container(
                width: 118,
                height: 118,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: primary.withValues(
                      alpha: (r2OpacityVal * 0.42).clamp(0.0, 1.0),
                    ),
                    width: 1.0,
                  ),
                ),
              ),
            ),
          Opacity(
            opacity: logoOpacityVal.clamp(0.0, 1.0),
            child: Transform.scale(
              scale: logoScaleVal,
              child: Container(
                width: 98,
                height: 98,
                decoration: ShapeDecoration(
                  shape: IsleThemeStyle.of(context).shapeFor(
                    28,
                    side: BorderSide(
                      color: highContrast
                          ? theme.colorScheme.outline
                          : IsleThemeStyle.of(context).rimBorderColor(),
                      width: highContrast
                          ? 1.5
                          : IsleThemeStyle.of(context).effectiveBorderWidth(),
                    ),
                  ),
                  color: palette['cardTop'].withValues(
                    alpha: isDark ? 0.95 : 0.99,
                  ),
                  shadows: IsleThemeStyle.of(context).cardShadows(hovered: true),
                ),
                child: const Center(child: IsleBrandMark(size: 62)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurtainContent({
    required ThemeData theme,
    required IslePalette palette,
    required Color primary,
    required Color terracotta,
    required bool isDark,
    required bool highContrast,
    required bool disableAnimations,
  }) {
    final titleOpacityVal = disableAnimations ? 1.0 : _titleOpacity.value;
    final titleSlideVal = disableAnimations ? Offset.zero : _titleSlide.value;
    final sloganOpacityVal = disableAnimations ? 1.0 : _sloganOpacity.value;
    final sloganSlideVal = disableAnimations ? Offset.zero : _sloganSlide.value;
    final shimmerOpacityVal = disableAnimations ? 1.0 : _shimmerOpacity.value;
    final shimmerPosVal = disableAnimations ? 0.5 : _shimmerPosition.value;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildAnimatedVesselStack(
          theme: theme,
          palette: palette,
          primary: primary,
          terracotta: terracotta,
          isDark: isDark,
          highContrast: highContrast,
          disableAnimations: disableAnimations,
        ),
        const SizedBox(height: 16),
        Opacity(
          opacity: titleOpacityVal.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: titleSlideVal,
            child: Text(
              '轻屿 LightIsle',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: -0.65,
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Opacity(
          opacity: sloganOpacityVal.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: sloganSlideVal,
            child: Text(
              '让每一份珍藏，自在归屿',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 0.4,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        Opacity(
          opacity: shimmerOpacityVal.clamp(0.0, 1.0),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
            decoration: BoxDecoration(
              color: palette['cardTop'].withValues(alpha: isDark ? 0.80 : 0.92),
              borderRadius: IsleRadius.brPill,
              border: Border.all(
                color: IsleGlass.rimBorderColor(isDark),
                width: 1.0,
              ),
            ),
            child: _SanctuaryShimmerBar(
              position: shimmerPosVal,
              primaryColor: primary,
              highlightColor: terracotta,
              isDark: isDark,
              disableAnimations: disableAnimations,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette.of(context);
    final primary = theme.colorScheme.primary;
    final terracotta = palette['brandTerracotta'];
    final disableAnimations = IsleMotion.reducedMotion(context);
    final highContrast = MediaQuery.highContrastOf(context);

    if (disableAnimations && _controller.value < 1.0) {
      _controller.value = 1.0;
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [palette['canvasTop'], palette['canvasBottom']],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!highContrast)
            ..._buildAmbientGlows(
              terracotta: terracotta,
              mineral: primary,
              isDark: isDark,
            ),
          SafeArea(
            child: Center(
              child: AnimatedSlide(
                offset: widget.exiting && !disableAnimations
                    ? const Offset(0, -0.016)
                    : Offset.zero,
                duration: const Duration(milliseconds: 440),
                curve: IsleMotion.silk,
                child: AnimatedScale(
                  scale: widget.exiting && !disableAnimations ? 1.024 : 1.0,
                  duration: const Duration(milliseconds: 440),
                  curve: IsleMotion.silk,
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) => _buildCurtainContent(
                      theme: theme,
                      palette: palette,
                      primary: primary,
                      terracotta: terracotta,
                      isDark: isDark,
                      highContrast: highContrast,
                      disableAnimations: disableAnimations,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
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
    const width = 108.0;
    const height = 3.0;
    const radius = 2.0;

    return Semantics(
      label: '正在连接轻屿',
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: primaryColor.withValues(alpha: isDark ? 0.18 : 0.12),
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
