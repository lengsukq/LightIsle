import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Master continuous + scroll-reactive painter for the Hero Sanctuary Stage.
class HeroSanctuaryReelPainter extends CustomPainter {
  const HeroSanctuaryReelPainter({
    required this.phase,
    required this.scrollDelta,
    required this.isDark,
  });

  final double phase;
  final double scrollDelta;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final t = (phase + scrollDelta * 0.15) % 1.0;
    final angle = t * math.pi * 2;

    final bgGradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: isDark
          ? const [Color(0xFF07101F), Color(0xFF0D1B35), Color(0xFF091326)]
          : const [Color(0xFF0B192E), Color(0xFF132A4A), Color(0xFF0E213B)],
    );
    canvas.drawRect(rect, Paint()..shader = bgGradient.createShader(rect));

    final pools = <(Color, double, double, double)>[
      (
        const Color(0xFF0071E3),
        0.25 + 0.12 * math.cos(angle),
        0.32 + 0.10 * math.sin(angle),
        0.55,
      ),
      (
        const Color(0xFF06B6D4),
        0.76 + 0.10 * math.sin(angle * 0.8),
        0.65 + 0.12 * math.cos(angle * 0.9),
        0.48,
      ),
      (
        const Color(0xFF6366F1),
        0.52 + 0.14 * math.sin(angle * 1.1),
        0.22 + 0.08 * math.cos(angle * 0.7),
        0.42,
      ),
    ];
    final maxDim = math.max(size.width, size.height);
    for (final (color, fx, fy, radiusFactor) in pools) {
      final c = Offset(size.width * fx, size.height * fy);
      final r = maxDim * radiusFactor;
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: 0.28),
              color.withValues(alpha: 0.0),
            ],
          ).createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }

    for (var w = 0; w < 3; w++) {
      final wavePath = Path();
      final baseY = size.height * (0.60 + w * 0.12);
      final wavePhase = angle * (1.0 + w * 0.25) + w * 1.1;
      wavePath.moveTo(0, baseY);
      for (double x = 0; x <= size.width; x += 16) {
        final nx = x / size.width;
        final dy =
            math.sin(nx * math.pi * 2.5 + wavePhase) * (9.0 + w * 3.5) +
            math.cos(nx * math.pi * 1.3 - wavePhase * 0.7) * 5.0;
        wavePath.lineTo(x, baseY + dy);
      }
      wavePath
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();

      final waveColor = w == 0
          ? const Color(0xFF0071E3)
          : (w == 1 ? const Color(0xFF06B6D4) : const Color(0xFF38BDF8));
      canvas.drawPath(
        wavePath,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              waveColor.withValues(alpha: 0.14 - w * 0.03),
              Colors.transparent,
            ],
          ).createShader(rect),
      );
    }

    final hub = Offset(size.width * 0.72, size.height * 0.44);
    final baseRadius = math.min(size.width, size.height) * 0.28;
    for (var ring = 0; ring < 3; ring++) {
      final r = baseRadius * (0.62 + ring * 0.32);
      final pulse = 1.0 + 0.03 * math.sin(angle * 2 - ring);
      canvas.drawCircle(
        hub,
        r * pulse,
        Paint()
          ..color = const Color(0xFF38BDF8)
              .withValues(alpha: 0.15 - ring * 0.04)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1,
      );
    }

    const nodeColors = <Color>[
      Color(0xFF38BDF8),
      Color(0xFF10B981),
      Color(0xFFF59E0B),
      Color(0xFFA78BFA),
    ];
    for (var i = 0; i < 4; i++) {
      final orbitAngle = angle * (i.isEven ? 1 : -0.8) + i * (math.pi / 2);
      final rx = baseRadius * (0.82 + (i % 2) * 0.32);
      final ry = rx * 0.56;
      final nodePos = Offset(
        hub.dx + math.cos(orbitAngle) * rx,
        hub.dy + math.sin(orbitAngle) * ry,
      );

      final ctrl = Offset(
        (hub.dx + nodePos.dx) * 0.5 - math.sin(orbitAngle) * 20,
        (hub.dy + nodePos.dy) * 0.5 + math.cos(orbitAngle) * 16,
      );
      final path = Path()
        ..moveTo(nodePos.dx, nodePos.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy, hub.dx, hub.dy);

      final color = nodeColors[i];
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: 0.25)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3,
      );

      final pt = (t * 2.5 + i * 0.25) % 1.0;
      final inv = 1.0 - pt;
      final packetPos = Offset(
        inv * inv * nodePos.dx + 2 * inv * pt * ctrl.dx + pt * pt * hub.dx,
        inv * inv * nodePos.dy + 2 * inv * pt * ctrl.dy + pt * pt * hub.dy,
      );
      canvas.drawCircle(
        packetPos,
        5.0,
        Paint()..color = color.withValues(alpha: 0.30),
      );
      canvas.drawCircle(packetPos, 2.4, Paint()..color = Colors.white);
      canvas.drawCircle(nodePos, 3.8, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant HeroSanctuaryReelPainter oldDelegate) =>
      oldDelegate.phase != phase ||
      oldDelegate.scrollDelta != scrollDelta ||
      oldDelegate.isDark != isDark;
}

/// Stage 1 Painter:Mac Native Core daemon + Multi-disk APFS storage pool.
class MacStorageStagePainter extends CustomPainter {
  const MacStorageStagePainter({
    required this.phase,
    required this.isDark,
    this.verticalFlow = false,
  });

  final double phase;
  final bool isDark;
  final bool verticalFlow;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final angle = phase * math.pi * 2;

    final bg = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: isDark
          ? const [Color(0xFF0A1424), Color(0xFF0E1E36)]
          : const [Color(0xFFF0F7FF), Color(0xFFE0EFFE)],
    );
    canvas.drawRect(rect, Paint()..shader = bg.createShader(rect));

    final lineColor = isDark
        ? Colors.white.withValues(alpha: 0.045)
        : const Color(0xFF0071E3).withValues(alpha: 0.055);
    final gridPaint = Paint()
      ..color = lineColor
      ..strokeWidth = 1;
    for (double x = 24; x < size.width; x += 28) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = 24; y < size.height; y += 28) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (!verticalFlow) {
      final leftCenter = Offset(size.width * 0.25, size.height * 0.48);
      final diskTop = Offset(size.width * 0.75, size.height * 0.30);
      final diskBottom = Offset(size.width * 0.75, size.height * 0.68);

      final targets = <(Offset, Color)>[
        (diskTop, const Color(0xFF0071E3)),
        (diskBottom, const Color(0xFF10B981)),
      ];

      for (var i = 0; i < targets.length; i++) {
        final (target, color) = targets[i];
        final midX = (leftCenter.dx + target.dx) * 0.5;
        final path = Path()
          ..moveTo(leftCenter.dx, leftCenter.dy)
          ..cubicTo(midX, leftCenter.dy, midX, target.dy, target.dx, target.dy);

        canvas.drawPath(
          path,
          Paint()
            ..color = color.withValues(alpha: isDark ? 0.35 : 0.28)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2,
        );

        for (var p = 0; p < 3; p++) {
          final t = (phase * 1.8 + p * 0.33 + i * 0.17) % 1.0;
          final pos = _cubicPoint(
            leftCenter,
            Offset(midX, leftCenter.dy),
            Offset(midX, target.dy),
            target,
            t,
          );
          canvas.drawCircle(
            pos,
            6,
            Paint()..color = color.withValues(alpha: 0.28),
          );
          canvas.drawCircle(pos, 2.8, Paint()..color = color);
        }
      }
    }

    // Telemetry sine wave at bottom of stage
    final wavePath = Path();
    final waveBaseY = size.height - 14;
    wavePath.moveTo(16, waveBaseY);
    for (double x = 16; x <= size.width - 16; x += 8) {
      final nx = (x - 16) / math.max(1.0, size.width - 32);
      final y =
          waveBaseY +
          math.sin(nx * math.pi * 6 - angle * 3) * 3.5 * math.sin(nx * math.pi);
      wavePath.lineTo(x, y);
    }
    canvas.drawPath(
      wavePath,
      Paint()
        ..color = const Color(0xFF10B981).withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  Offset _cubicPoint(Offset p0, Offset p1, Offset p2, Offset p3, double t) {
    final u = 1 - t;
    final tt = t * t;
    final uu = u * u;
    final uuu = uu * u;
    final ttt = tt * t;
    return Offset(
      uuu * p0.dx + 3 * uu * t * p1.dx + 3 * u * tt * p2.dx + ttt * p3.dx,
      uuu * p0.dy + 3 * uu * t * p1.dy + 3 * u * tt * p2.dy + ttt * p3.dy,
    );
  }

  @override
  bool shouldRepaint(covariant MacStorageStagePainter oldDelegate) =>
      oldDelegate.phase != phase ||
      oldDelegate.isDark != isDark ||
      oldDelegate.verticalFlow != verticalFlow;
}

/// Stage 2 Painter: Dedicated GPS Footprint Radar in its own container box.
class PhotoRadarPainter extends CustomPainter {
  const PhotoRadarPainter({required this.phase, required this.isDark});

  final double phase;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final angle = phase * math.pi * 2;
    final radarCenter = Offset(size.width * 0.5, size.height * 0.5);
    final radarRadius = math.min(size.width, size.height) * 0.42;

    for (var r = 1; r <= 3; r++) {
      canvas.drawCircle(
        radarCenter,
        radarRadius * (r / 3),
        Paint()
          ..color = const Color(0xFF8B5CF6).withValues(alpha: 0.20)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
    }

    final sweepRect = Rect.fromCircle(center: radarCenter, radius: radarRadius);
    canvas.drawArc(
      sweepRect,
      angle,
      math.pi * 0.48,
      true,
      Paint()
        ..shader = SweepGradient(
          startAngle: angle,
          endAngle: angle + math.pi * 0.48,
          colors: [
            const Color(0xFF8B5CF6).withValues(alpha: 0.0),
            const Color(0xFF8B5CF6).withValues(alpha: 0.30),
          ],
          transform: GradientRotation(angle),
        ).createShader(sweepRect),
    );

    const pins = <(double, double, Color)>[
      (-0.35, -0.28, Color(0xFFEC4899)),
      (0.32, -0.30, Color(0xFF8B5CF6)),
      (-0.22, 0.34, Color(0xFF06B6D4)),
      (0.34, 0.26, Color(0xFF10B981)),
    ];
    for (var i = 0; i < pins.length; i++) {
      final (dx, dy, color) = pins[i];
      final pinPos = Offset(
        radarCenter.dx + dx * radarRadius,
        radarCenter.dy + dy * radarRadius,
      );
      final pulse = 0.5 + 0.5 * math.sin(angle * 2 + i * 1.4);
      canvas.drawCircle(
        pinPos,
        4 + pulse * 5,
        Paint()..color = color.withValues(alpha: 0.26 * (1 - pulse * 0.5)),
      );
      canvas.drawCircle(pinPos, 3.5, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant PhotoRadarPainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.isDark != isDark;
}

/// Stage 3 Painter: Widescreen Cinema Billboard backdrop with sweeping spotlight
/// (no overlapping equalizer bars behind poster cards).
class CinemaBillboardStagePainter extends CustomPainter {
  const CinemaBillboardStagePainter({required this.phase});

  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final angle = phase * math.pi * 2;

    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF16080D), Color(0xFF0B0D17), Color(0xFF090A10)],
        ).createShader(rect),
    );

    final spotX = size.width * (0.45 + 0.20 * math.sin(angle));
    final spotCenter = Offset(spotX, size.height * 0.22);
    final spotRadius = math.max(size.width * 0.55, 160.0);
    canvas.drawCircle(
      spotCenter,
      spotRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFFE50914).withValues(alpha: 0.28),
            const Color(0xFFF59E0B).withValues(alpha: 0.08),
            Colors.transparent,
          ],
          stops: const [0.0, 0.48, 1.0],
        ).createShader(Rect.fromCircle(center: spotCenter, radius: spotRadius)),
    );
  }

  @override
  bool shouldRepaint(covariant CinemaBillboardStagePainter oldDelegate) =>
      oldDelegate.phase != phase;
}

/// Stage 4 Painter: Cross-platform constellation & encrypted Keychain conduits.
class CrossPlatformStagePainter extends CustomPainter {
  const CrossPlatformStagePainter({required this.phase, required this.isDark});

  final double phase;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final angle = phase * math.pi * 2;

    final bg = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: isDark
          ? const [Color(0xFF091926), Color(0xFF0D2338)]
          : const [Color(0xFFECFEFF), Color(0xFFE0F2FE)],
    );
    canvas.drawRect(rect, Paint()..shader = bg.createShader(rect));

    final center = Offset(size.width * 0.5, size.height * 0.5);
    final rx = size.width * 0.32;
    final ry = size.height * 0.28;

    final endpoints = <Offset>[
      Offset(center.dx - rx, center.dy - ry),
      Offset(center.dx + rx, center.dy - ry),
      Offset(center.dx - rx, center.dy + ry),
      Offset(center.dx + rx, center.dy + ry),
    ];

    for (var i = 0; i < endpoints.length; i++) {
      final ep = endpoints[i];
      canvas.drawLine(
        center,
        ep,
        Paint()
          ..color = const Color(0xFF06B6D4).withValues(alpha: 0.24)
          ..strokeWidth = 1.5,
      );

      final t = (phase * 2.0 + i * 0.25) % 1.0;
      final packet = ui.Offset.lerp(center, ep, t)!;
      canvas.drawCircle(
        packet,
        5,
        Paint()..color = const Color(0xFF06B6D4).withValues(alpha: 0.28),
      );
      canvas.drawCircle(packet, 2.5, Paint()..color = const Color(0xFF06B6D4));
    }

    final shieldRadius = 22.0 + 16.0 * (0.5 + 0.5 * math.sin(angle * 1.5));
    canvas.drawCircle(
      center,
      shieldRadius,
      Paint()
        ..color = const Color(0xFF10B981).withValues(alpha: 0.22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
  }

  @override
  bool shouldRepaint(covariant CrossPlatformStagePainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.isDark != isDark;
}
