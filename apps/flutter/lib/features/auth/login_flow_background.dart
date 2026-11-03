import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Low-cost ambient motion for authentication. Only this CustomPaint repaints;
/// text fields, autofill and the rest of the route do not rebuild per frame.
class LoginFlowBackground extends StatefulWidget {
  const LoginFlowBackground({super.key});

  @override
  State<LoginFlowBackground> createState() => _LoginFlowBackgroundState();
}

class _LoginFlowBackgroundState extends State<LoginFlowBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.maybeOf(context);
    final reduceMotion =
        media?.disableAnimations == true || media?.highContrast == true;
    if (reduceMotion) {
      _motion.stop();
      _motion.value = 0;
    } else if (!_motion.isAnimating) {
      _motion.repeat();
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      key: const Key('loginFlowCanvas'),
      painter: _LoginFlowPainter(
        motion: _motion,
        dark: Theme.of(context).brightness == Brightness.dark,
      ),
      child: const SizedBox.expand(),
    ),
  );
}

class _LoginFlowPainter extends CustomPainter {
  _LoginFlowPainter({required this.motion, required this.dark})
    : super(repaint: motion);

  final Animation<double> motion;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final baseTop = dark ? const Color(0xff081527) : const Color(0xfff7faff);
    final baseBottom = dark ? const Color(0xff101e37) : const Color(0xffeaf2fd);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [baseTop, baseBottom],
        ).createShader(rect),
    );

    final angle = motion.value * math.pi * 2;
    final extent = math.max(size.width, size.height);
    final pools = <(Color, double, double, double, double)>[
      (
        dark ? const Color(0xff386df0) : const Color(0xff93c5fd),
        .04 + .10 * math.cos(angle),
        .06 + .13 * math.sin(angle),
        .64,
        dark ? .25 : .43,
      ),
      (
        dark ? const Color(0xff29a7b8) : const Color(0xff85ddd1),
        .93 + .09 * math.sin(angle * .72),
        .68 + .13 * math.cos(angle * .82),
        .61,
        dark ? .16 : .31,
      ),
      (
        dark ? const Color(0xff7253b8) : const Color(0xffc5b2ed),
        .51 + .19 * math.sin(angle * .61),
        1.04 + .11 * math.cos(angle * .68),
        .52,
        dark ? .16 : .30,
      ),
    ];

    for (final (color, fx, fy, scale, alpha) in pools) {
      final radius = extent * scale;
      final center = Offset(size.width * fx, size.height * fy);
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: alpha),
              color.withValues(alpha: 0),
            ],
            stops: const [0, 1],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }

    // Two broad, slowly drifting translucent ribbons. No blur layers,
    // image assets or backdrop filters are required on mobile GPUs.
    for (var index = 0; index < 2; index++) {
      final drift =
          math.sin(angle + index * math.pi * .75) * size.height * .035;
      final y = size.height * (.37 + index * .28) + drift;
      final ribbon = Path()
        ..moveTo(-size.width * .2, y)
        ..cubicTo(
          size.width * .25,
          y - extent * .16,
          size.width * .63,
          y + extent * .13,
          size.width * 1.2,
          y - extent * .09,
        )
        ..lineTo(size.width * 1.2, y + extent * .13)
        ..cubicTo(
          size.width * .64,
          y + extent * .25,
          size.width * .21,
          y - extent * .03,
          -size.width * .2,
          y + extent * .11,
        )
        ..close();
      canvas.drawPath(
        ribbon,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              Colors.transparent,
              (dark ? const Color(0xff6b99d9) : Colors.white).withValues(
                alpha: dark ? .045 : .21,
              ),
              Colors.transparent,
            ],
          ).createShader(rect),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LoginFlowPainter oldDelegate) =>
      oldDelegate.dark != dark || oldDelegate.motion != motion;
}
