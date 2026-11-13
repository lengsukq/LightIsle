import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A single immutable slice rendered by [IsleDonutGauge] and [IsleSegmentedBar].
@immutable
class IsleChartSegment {
  const IsleChartSegment({
    required this.label,
    required this.value,
    required this.color,
    this.detail,
  });

  final String label;
  final double value;
  final Color color;
  final String? detail;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is IsleChartSegment &&
        other.label == label &&
        other.value == value &&
        other.color == color &&
        other.detail == detail;
  }

  @override
  int get hashCode => Object.hash(label, value, color, detail);
}

/// Apple-style native vector ring gauge supporting either a single [fraction]
/// progress ring or multi-[segments] breakdown with crisp rounded caps.
class IsleDonutGauge extends StatelessWidget {
  const IsleDonutGauge({
    super.key,
    this.segments = const [],
    this.fraction,
    this.color,
    this.size = 54,
    this.strokeWidth = 5.5,
    this.trackColor,
    this.centerText,
    this.centerStyle,
    this.center,
    this.gapRadians = 0.06,
    this.startAngle = -math.pi / 2,
    this.semanticsLabel,
  });

  final List<IsleChartSegment> segments;
  final double? fraction;
  final Color? color;
  final double size;
  final double strokeWidth;
  final Color? trackColor;
  final String? centerText;
  final TextStyle? centerStyle;
  final Widget? center;
  final double gapRadians;
  final double startAngle;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final resolvedTrack =
        trackColor ?? colors.onSurface.withValues(alpha: dark ? 0.12 : 0.08);
    final resolvedFraction = fraction?.isFinite == true
        ? fraction!.clamp(0.0, 1.0)
        : null;
    final resolvedColor = color ?? colors.primary;
    final cleanSegments = segments
        .where((s) => s.value.isFinite && s.value > 0)
        .toList(growable: false);

    final semanticText = _buildSemantics(cleanSegments, resolvedFraction);
    final centerChild =
        center ??
        (centerText == null
            ? null
            : Padding(
                padding: EdgeInsets.all(strokeWidth + 3),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    centerText!,
                    maxLines: 1,
                    style:
                        centerStyle ??
                        theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: colors.onSurface,
                        ),
                  ),
                ),
              ));

    return Semantics(
      label: semanticText,
      container: true,
      child: SizedBox(
        width: size,
        height: size,
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _IsleDonutPainter(
              segments: cleanSegments,
              fraction: resolvedFraction,
              singleColor: resolvedColor,
              trackColor: resolvedTrack,
              strokeWidth: strokeWidth,
              gapRadians: gapRadians,
              startAngle: startAngle,
            ),
            child: centerChild == null ? null : Center(child: centerChild),
          ),
        ),
      ),
    );
  }

  String _buildSemantics(
    List<IsleChartSegment> cleanSegments,
    double? resolvedFraction,
  ) {
    if (semanticsLabel != null && semanticsLabel!.trim().isNotEmpty) {
      return semanticsLabel!.trim();
    }
    if (cleanSegments.isNotEmpty) {
      final total = cleanSegments.fold<double>(0, (sum, s) => sum + s.value);
      final parts = cleanSegments
          .map((s) {
            final pct = total > 0 ? (s.value / total * 100).round() : 0;
            return s.detail == null || s.detail!.isEmpty
                ? '${s.label} $pct%'
                : '${s.label} ${s.detail}';
          })
          .join('，');
      return parts;
    }
    if (resolvedFraction != null) {
      final pct = (resolvedFraction * 100).round();
      return centerText == null ? '占比 $pct%' : '$centerText（$pct%）';
    }
    return centerText ?? '环形占比图表';
  }
}

class _IsleDonutPainter extends CustomPainter {
  const _IsleDonutPainter({
    required this.segments,
    required this.fraction,
    required this.singleColor,
    required this.trackColor,
    required this.strokeWidth,
    required this.gapRadians,
    required this.startAngle,
  });

  final List<IsleChartSegment> segments;
  final double? fraction;
  final Color singleColor;
  final Color trackColor;
  final double strokeWidth;
  final double gapRadians;
  final double startAngle;

  @override
  void paint(Canvas canvas, Size size) {
    final diameter = math.min(size.width, size.height);
    if (diameter <= strokeWidth) return;
    final radius = (diameter - strokeWidth) / 2;
    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: radius);

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = trackColor
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    canvas.drawCircle(center, radius, trackPaint);

    if (segments.isEmpty) {
      final f = fraction;
      if (f == null || f <= 0) return;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = singleColor
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true;
      final sweep = (math.pi * 2) * f.clamp(0.0, 1.0);
      canvas.drawArc(rect, startAngle, sweep, false, paint);
      return;
    }

    final total = segments.fold<double>(0, (sum, s) => sum + s.value);
    if (total <= 0) return;

    if (segments.length == 1) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = segments.first.color
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true;
      canvas.drawCircle(center, radius, paint);
      return;
    }

    final capCompensation = radius > 0 ? strokeWidth / radius : 0.0;
    final effectiveGap = math.max(gapRadians, capCompensation * 0.72);
    var cursor = startAngle;
    const fullTurn = math.pi * 2;
    for (final seg in segments) {
      final rawSweep = fullTurn * (seg.value / total);
      final drawSweep = rawSweep - effectiveGap;
      if (drawSweep > 0.02) {
        final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..color = seg.color
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true;
        canvas.drawArc(
          rect,
          cursor + effectiveGap / 2,
          drawSweep,
          false,
          paint,
        );
      }
      cursor += rawSweep;
    }
  }

  @override
  bool shouldRepaint(covariant _IsleDonutPainter old) =>
      !listEquals(old.segments, segments) ||
      old.fraction != fraction ||
      old.singleColor != singleColor ||
      old.trackColor != trackColor ||
      old.strokeWidth != strokeWidth ||
      old.gapRadians != gapRadians ||
      old.startAngle != startAngle;
}

/// Apple Settings -> Storage style multi-segment horizontal pill bar with an
/// adaptive wrapping color-dot legend and full-value semantics.
class IsleSegmentedBar extends StatelessWidget {
  const IsleSegmentedBar({
    super.key,
    required this.segments,
    this.height = 10,
    this.trackColor,
    this.minSegmentWidth = 4,
    this.gapWidth = 1.5,
    this.showLegend = true,
    this.showPercentInLegend = false,
    this.legendSpacing = 12,
    this.legendRunSpacing = 6,
    this.legendGap = 8,
    this.semanticsLabel,
  });

  final List<IsleChartSegment> segments;
  final double height;
  final Color? trackColor;
  final double minSegmentWidth;
  final double gapWidth;
  final bool showLegend;
  final bool showPercentInLegend;
  final double legendSpacing;
  final double legendRunSpacing;
  final double legendGap;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final resolvedTrack =
        trackColor ?? colors.onSurface.withValues(alpha: dark ? 0.10 : 0.07);
    final positive = segments
        .where((s) => s.value.isFinite && s.value > 0)
        .toList(growable: false);
    final total = positive.fold<double>(0, (sum, s) => sum + s.value);

    final bar = RepaintBoundary(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _IsleSegmentedBarPainter(
            segments: positive,
            trackColor: resolvedTrack,
            minSegmentWidth: minSegmentWidth,
            gapWidth: gapWidth,
          ),
        ),
      ),
    );

    final effectiveSemantics = _buildSemantics(total);

    if (!showLegend || segments.isEmpty) {
      return Semantics(label: effectiveSemantics, container: true, child: bar);
    }

    return Semantics(
      label: effectiveSemantics,
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          bar,
          SizedBox(height: legendGap),
          LayoutBuilder(
            builder: (context, constraints) {
              final maxItemWidth = constraints.maxWidth.isFinite
                  ? constraints.maxWidth
                  : 400.0;
              return Wrap(
                spacing: legendSpacing,
                runSpacing: legendRunSpacing,
                children: [
                  for (final seg in segments)
                    _buildLegendItem(
                      context,
                      seg,
                      total: total,
                      maxWidth: maxItemWidth,
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLegendItem(
    BuildContext context,
    IsleChartSegment seg, {
    required double total,
    required double maxWidth,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final detailParts = <String>[];
    if (seg.detail != null && seg.detail!.trim().isNotEmpty) {
      detailParts.add(seg.detail!.trim());
    }
    if (showPercentInLegend && total > 0 && seg.value > 0) {
      final pct = (seg.value / total * 100);
      final pctLabel = pct > 0 && pct < 1
          ? '<1%'
          : '${pct.toStringAsFixed(0)}%';
      detailParts.add(pctLabel);
    }
    final detailText = detailParts.join(' · ');

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: seg.color,
              borderRadius: BorderRadius.circular(2.5),
            ),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text.rich(
              TextSpan(
                text: seg.label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
                children: detailText.isEmpty
                    ? null
                    : [
                        TextSpan(
                          text: ' $detailText',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colors.onSurface,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  String _buildSemantics(double total) {
    if (semanticsLabel != null && semanticsLabel!.trim().isNotEmpty) {
      return semanticsLabel!.trim();
    }
    return segments
        .map((s) {
          final pct = total > 0 && s.value > 0
              ? ' ${(s.value / total * 100).round()}%'
              : '';
          final detail = s.detail?.trim() ?? '';
          return detail.isEmpty
              ? '${s.label}$pct'
              : '${s.label} $detail$pct'.trim();
        })
        .join('，');
  }
}

class _IsleSegmentedBarPainter extends CustomPainter {
  const _IsleSegmentedBarPainter({
    required this.segments,
    required this.trackColor,
    required this.minSegmentWidth,
    required this.gapWidth,
  });

  final List<IsleChartSegment> segments;
  final Color trackColor;
  final double minSegmentWidth;
  final double gapWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(size.height / 2),
    );

    canvas.save();
    canvas.clipRRect(rrect);

    final trackPaint = Paint()..color = trackColor;
    canvas.drawRect(rect, trackPaint);

    if (segments.isEmpty) {
      canvas.restore();
      return;
    }

    final total = segments.fold<double>(0, (sum, s) => sum + s.value);
    if (total <= 0) {
      canvas.restore();
      return;
    }

    final effectiveGap = segments.length > 1
        ? math.min(gapWidth, size.width * 0.03)
        : 0.0;
    final totalGap = effectiveGap * (segments.length - 1);
    final usableWidth = math.max(0.0, size.width - totalGap);
    if (usableWidth <= 0) {
      canvas.restore();
      return;
    }

    final widths = _allocateWidths(segments, total, usableWidth);
    var x = 0.0;
    for (var i = 0; i < segments.length; i++) {
      final w = widths[i];
      if (w > 0) {
        final paint = Paint()..color = segments[i].color;
        canvas.drawRect(Rect.fromLTWH(x, 0, w, size.height), paint);
      }
      x += w + effectiveGap;
    }

    canvas.restore();
  }

  List<double> _allocateWidths(
    List<IsleChartSegment> items,
    double total,
    double usableWidth,
  ) {
    final floor = math.min(minSegmentWidth, usableWidth / items.length);
    final widths = List<double>.filled(items.length, 0);
    var lockedWidth = 0.0;
    var unlockedValue = 0.0;

    for (var i = 0; i < items.length; i++) {
      final proportional = usableWidth * (items[i].value / total);
      if (proportional < floor) {
        widths[i] = floor;
        lockedWidth += floor;
      } else {
        unlockedValue += items[i].value;
      }
    }

    final remainingWidth = math.max(0.0, usableWidth - lockedWidth);
    if (unlockedValue > 0) {
      for (var i = 0; i < items.length; i++) {
        if (widths[i] == 0) {
          widths[i] = remainingWidth * (items[i].value / unlockedValue);
        }
      }
    }
    return widths;
  }

  @override
  bool shouldRepaint(covariant _IsleSegmentedBarPainter old) =>
      !listEquals(old.segments, segments) ||
      old.trackColor != trackColor ||
      old.minSegmentWidth != minSegmentWidth ||
      old.gapWidth != gapWidth;
}

/// Compact native vector sparkline with smooth Bezier interpolation and vertical
/// gradient area fill. Never allocates animation controllers or runs idle tickers.
class IsleSparkline extends StatelessWidget {
  const IsleSparkline({
    super.key,
    required this.values,
    required this.color,
    this.height = 30,
    this.strokeWidth = 2.0,
    this.minValue,
    this.maxValue,
    this.showGradient = true,
    this.showLatestDot = true,
    this.semanticsLabel,
  });

  final List<double> values;
  final Color color;
  final double height;
  final double strokeWidth;
  final double? minValue;
  final double? maxValue;
  final bool showGradient;
  final bool showLatestDot;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final clean = values.where((v) => v.isFinite).toList(growable: false);
    final surface = Theme.of(context).colorScheme.surface;
    final label =
        semanticsLabel ??
        (clean.isEmpty
            ? '暂无趋势采样'
            : '趋势采样 ${clean.length} 点，最新值 ${clean.last.toStringAsFixed(1)}');

    return Semantics(
      label: label,
      container: true,
      child: RepaintBoundary(
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: _IsleSparklinePainter(
              values: clean,
              color: color,
              dotCenterColor: surface,
              strokeWidth: strokeWidth,
              minValue: minValue,
              maxValue: maxValue,
              showGradient: showGradient,
              showLatestDot: showLatestDot,
            ),
          ),
        ),
      ),
    );
  }
}

class _IsleSparklinePainter extends CustomPainter {
  const _IsleSparklinePainter({
    required this.values,
    required this.color,
    required this.dotCenterColor,
    required this.strokeWidth,
    required this.minValue,
    required this.maxValue,
    required this.showGradient,
    required this.showLatestDot,
  });

  final List<double> values;
  final Color color;
  final Color dotCenterColor;
  final double strokeWidth;
  final double? minValue;
  final double? maxValue;
  final bool showGradient;
  final bool showLatestDot;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 4 || size.height <= 4 || values.isEmpty) return;

    const padX = 3.0;
    const padY = 4.0;
    final plotWidth = size.width - padX * 2;
    final plotHeight = size.height - padY * 2;
    if (plotWidth <= 0 || plotHeight <= 0) return;

    var low = minValue ?? values.reduce(math.min);
    var high = maxValue ?? values.reduce(math.max);
    if ((high - low).abs() < 1e-6) {
      low -= 1;
      high += 1;
    }

    double yFor(double v) {
      final norm = ((v - low) / (high - low)).clamp(0.0, 1.0);
      return padY + plotHeight * (1 - norm);
    }

    final points = <Offset>[];
    if (values.length == 1) {
      final y = yFor(values.first);
      points.add(Offset(padX, y));
      points.add(Offset(padX + plotWidth, y));
    } else {
      final step = plotWidth / (values.length - 1);
      for (var i = 0; i < values.length; i++) {
        points.add(Offset(padX + step * i, yFor(values[i])));
      }
    }

    final strokePath = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final ctrlX = (p0.dx + p1.dx) / 2;
      strokePath.cubicTo(
        ctrlX,
        p0.dy.clamp(padY, padY + plotHeight),
        ctrlX,
        p1.dy.clamp(padY, padY + plotHeight),
        p1.dx,
        p1.dy,
      );
    }

    if (showGradient) {
      final fillPath = Path.from(strokePath)
        ..lineTo(points.last.dx, size.height)
        ..lineTo(points.first.dx, size.height)
        ..close();
      final fillPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.24), color.withValues(alpha: 0.0)],
        ).createShader(Offset.zero & size);
      canvas.drawPath(fillPath, fillPaint);
    }

    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color
      ..isAntiAlias = true;
    canvas.drawPath(strokePath, linePaint);

    if (showLatestDot) {
      final last = points.last;
      canvas.drawCircle(
        last,
        strokeWidth + 1.6,
        Paint()..color = dotCenterColor,
      );
      canvas.drawCircle(last, strokeWidth + 0.6, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _IsleSparklinePainter old) =>
      !listEquals(old.values, values) ||
      old.color != color ||
      old.dotCenterColor != dotCenterColor ||
      old.strokeWidth != strokeWidth ||
      old.minValue != minValue ||
      old.maxValue != maxValue ||
      old.showGradient != showGradient ||
      old.showLatestDot != showLatestDot;
}
