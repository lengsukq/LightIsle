part of 'network_diagnostics_page.dart';

class _TestGaugePainter extends CustomPainter {
  const _TestGaugePainter({
    required this.progress,
    required this.pulse,
    required this.animated,
    required this.primary,
    required this.secondary,
    required this.tertiary,
    required this.track,
  });
  final double progress, pulse;
  final bool animated;
  final Color primary, secondary, tertiary, track;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * .38;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final start = math.pi * .75;
    final sweep = math.pi * 1.5;
    final background = Paint()
      ..color = track.withValues(alpha: .63)
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawArc(rect, start, sweep, false, background);
    if (progress > 0) {
      final gradient = SweepGradient(
        startAngle: start,
        endAngle: start + sweep,
        colors: [primary, secondary, tertiary],
      ).createShader(rect);
      canvas.drawArc(
        rect,
        start,
        sweep * progress.clamp(0, 1),
        false,
        Paint()
          ..shader = gradient
          ..strokeWidth = 13
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke,
      );
      final angle = start + sweep * progress.clamp(0, 1);
      canvas.drawCircle(
        Offset(
          center.dx + math.cos(angle) * radius,
          center.dy + math.sin(angle) * radius,
        ),
        4.5,
        Paint()..color = secondary,
      );
    }
    if (animated) {
      canvas.drawCircle(
        center,
        radius + 16 + pulse * 12,
        Paint()
          ..color = secondary.withValues(alpha: .16 * (1 - pulse))
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TestGaugePainter old) =>
      progress != old.progress ||
      pulse != old.pulse ||
      animated != old.animated ||
      primary != old.primary ||
      secondary != old.secondary ||
      tertiary != old.tertiary ||
      track != old.track;
}

class _LatencyLinePainter extends CustomPainter {
  const _LatencyLinePainter(this.points, this.primary, this.failure, this.grid);
  final List<NetworkLatencyPoint> points;
  final Color primary, failure, grid;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final bottom = size.height - 8;
    for (final fraction in [.25, .5, .75]) {
      final y = 8 + (size.height - 16) * fraction;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..color = grid.withValues(alpha: .55)
          ..strokeWidth = 1,
      );
    }
    if (points.isEmpty) return;
    final valid = points
        .where((p) => p.success)
        .map((p) => p.milliseconds!)
        .toList();
    final highest = valid.isEmpty
        ? 10.0
        : math.max(10.0, valid.reduce(math.max) * 1.2);
    Offset point(int i, double value) => Offset(
      points.length == 1
          ? size.width / 2
          : size.width * i / (points.length - 1),
      bottom - value.clamp(0, highest) / highest * (size.height - 16),
    );
    final path = Path();
    var hasSegment = false;
    for (var i = 0; i < points.length; i++) {
      final ms = points[i].milliseconds;
      if (ms == null) {
        hasSegment = false;
        canvas.drawCircle(point(i, 0), 3.5, Paint()..color = failure);
        continue;
      }
      final p = point(i, ms);
      if (!hasSegment) {
        path.moveTo(p.dx, p.dy);
        hasSegment = true;
      } else {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawCircle(p, 2.5, Paint()..color = primary);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = primary
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _LatencyLinePainter old) =>
      !listEquals(points, old.points) ||
      primary != old.primary ||
      failure != old.failure ||
      grid != old.grid;
}
