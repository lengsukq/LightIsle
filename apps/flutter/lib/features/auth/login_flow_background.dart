import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';

/// Adaptive ambient canvas for authentication matching all 5 built-in themes.
/// Keeps the login shell featherlight and satisfies borderless responsive invariants.
class LoginFlowBackground extends StatefulWidget {
  const LoginFlowBackground({super.key});

  @override
  State<LoginFlowBackground> createState() => _LoginFlowBackgroundState();
}

class _LoginFlowBackgroundState extends State<LoginFlowBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 32),
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
  Widget build(BuildContext context) {
    final style = IsleThemeStyle.of(context);
    return RepaintBoundary(
      child: CustomPaint(
        key: const Key('loginFlowCanvas'),
        painter: _LoginFlowPainter(motion: _motion, style: style),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _LoginFlowPainter extends CustomPainter {
  _LoginFlowPainter({required this.motion, required this.style})
    : super(repaint: motion);

  final Animation<double> motion;
  final IsleThemeStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final p = style.palette;
    final dark = style.dark;
    final top = p['canvasTop'];
    final bottom = p['canvasBottom'];
    final mid = Color.lerp(top, bottom, 0.52)!;

    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: const [0.0, 0.54, 1.0],
          colors: [top, mid, bottom],
        ).createShader(rect),
    );

    if (style.highContrast) return;

    final angle = motion.value * math.pi * 2;
    final extent = math.max(size.width, size.height);

    switch (style.preset.canvasBackdrop) {
      case IsleCanvasBackdrop.warmGlow:
        _paintPools(canvas, size, extent, [
          (
            p['accentSecondary'],
            .18 + .04 * math.cos(angle),
            .16 + .05 * math.sin(angle),
            .52,
            dark ? .085 : .105,
          ),
          (
            p['accentPrimary'],
            .84 + .04 * math.sin(angle * .72),
            .76 + .05 * math.cos(angle * .82),
            .50,
            dark ? .075 : .085,
          ),
        ]);
      case IsleCanvasBackdrop.auroraGlow:
        _paintPools(canvas, size, extent, [
          (
            p['accentPrimary'],
            .18 + .06 * math.cos(angle),
            .18 + .05 * math.sin(angle),
            .58,
            dark ? .24 : .16,
          ),
          (
            p['accentSecondary'],
            .82 + .05 * math.sin(angle * .78),
            .24 + .05 * math.cos(angle * .65),
            .52,
            dark ? .20 : .13,
          ),
          (
            p['brandCyan'],
            .50 + .06 * math.sin(angle * .5),
            .88 + .04 * math.cos(angle * .9),
            .54,
            dark ? .16 : .11,
          ),
        ]);
      case IsleCanvasBackdrop.flatRule:
        canvas.drawRect(
          Rect.fromLTWH(0, 0, size.width, 4),
          Paint()..color = p['accentPrimary'],
        );
        final rulePaint = Paint()
          ..color = p['rim'].withValues(alpha: dark ? 0.25 : 0.35)
          ..strokeWidth = 0.8;
        final colStep = math.max(120.0, size.width / 6);
        for (double x = colStep; x < size.width; x += colStep) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), rulePaint);
        }
      case IsleCanvasBackdrop.dotMatrix:
        final dotPaint = Paint()
          ..color = p['rim'].withValues(alpha: dark ? 0.14 : 0.12);
        const step = 24.0;
        for (double y = 12; y < size.height; y += step) {
          for (double x = 12; x < size.width; x += step) {
            canvas.drawCircle(Offset(x, y), 1.25, dotPaint);
          }
        }
        final accentRect = Rect.fromLTWH(size.width - 72, 28, 44, 44);
        canvas.drawRect(
          accentRect.shift(const Offset(4, 4)),
          Paint()..color = p['shadow'],
        );
        canvas.drawRect(accentRect, Paint()..color = p['accentSecondary']);
        canvas.drawRect(
          accentRect,
          Paint()
            ..color = p['rim']
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0,
        );
      case IsleCanvasBackdrop.techGrid:
        final gridPaint = Paint()
          ..color = p['accentPrimary'].withValues(alpha: dark ? 0.09 : 0.075)
          ..strokeWidth = 0.8;
        const step = 32.0;
        for (double x = 0; x < size.width; x += step) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
        }
        for (double y = 0; y < size.height; y += step) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
        }
        _paintPools(canvas, size, extent, [
          (
            p['accentPrimary'],
            .80 + .03 * math.cos(angle),
            .18 + .03 * math.sin(angle),
            .42,
            dark ? .15 : .09,
          ),
        ]);
    }
  }

  void _paintPools(
    Canvas canvas,
    Size size,
    double extent,
    List<(Color, double, double, double, double)> pools,
  ) {
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
              color.withValues(alpha: alpha * 0.28),
              color.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.48, 1.0],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LoginFlowPainter oldDelegate) =>
      oldDelegate.style.presetId != style.presetId ||
      oldDelegate.style.dark != style.dark ||
      oldDelegate.style.highContrast != style.highContrast ||
      oldDelegate.motion != motion;
}

/// Adaptive brand emblem & title across Phone, Tablet, and Desktop.
class LoginBrandHeader extends StatelessWidget {
  const LoginBrandHeader({super.key, required this.wide, this.medium = false});

  final bool wide;
  final bool medium;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final style = IsleThemeStyle.of(context);
    final isDark = style.dark;
    final palette = style.palette;
    final isBrutal = style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal;

    final emblem = Container(
      padding: EdgeInsets.all(wide ? 13 : 10),
      decoration: ShapeDecoration(
        shape: style.shapeFor(
          wide ? 24 : 20,
          side: BorderSide(
            color: style.rimBorderColor(),
            width: style.effectiveBorderWidth(),
          ),
        ),
        color: isBrutal ? palette['cardTop'] : null,
        gradient: isBrutal
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  palette['cardTop'].withValues(alpha: isDark ? 0.96 : 0.99),
                  palette['cardBottom'].withValues(alpha: isDark ? 0.90 : 0.95),
                ],
              ),
        shadows: style.cardShadows(),
      ),
      child: IsleBrandMark(size: wide ? 60 : (medium ? 48 : 44)),
    );

    if (wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          emblem,
          const SizedBox(height: 24),
          Text(
            '轻屿 LightIsle',
            style: theme.textTheme.headlineLarge?.copyWith(
              fontWeight: FontWeight.w800,
              height: 1.12,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '运行于个人 Mac 的家庭私密画廊，原片、文件与私人影院静候归来。',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colors.onSurfaceVariant,
              height: 1.55,
            ),
          ),
          const SizedBox(height: 22),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _quietFeatureTag(
                context,
                Icons.bolt_rounded,
                '局域网直连',
                palette['brandAmber'],
              ),
              _quietFeatureTag(
                context,
                Icons.photo_library_outlined,
                '原画时光相册',
                palette['brandRose'],
              ),
              _quietFeatureTag(
                context,
                Icons.movie_outlined,
                '私人影院',
                palette['brandTerracotta'],
              ),
            ],
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        emblem,
        const SizedBox(height: 12),
        Text(
          '轻屿 LightIsle',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '个人 Mac 上的家庭私密空间',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 13,
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _quietFeatureTag(
    BuildContext context,
    IconData icon,
    String label,
    Color accent,
  ) {
    final theme = Theme.of(context);
    final style = IsleThemeStyle.of(context);
    final isDark = style.dark;
    final palette = style.palette;
    final isSharp = style.preset.cornerStyle == IsleCornerStyle.sharp;
    final isBrutal = style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5.5),
      decoration: ShapeDecoration(
        shape: isSharp
            ? style.shapeFor(
                IsleRadius.sm,
                side: BorderSide(
                  color: style.rimBorderColor(),
                  width: style.effectiveBorderWidth(),
                ),
              )
            : StadiumBorder(
                side: BorderSide(
                  color: style.rimBorderColor(),
                  width: isBrutal ? 1.5 : 0.9,
                ),
              ),
        color: isBrutal
            ? palette['cardTop']
            : palette['cardTop'].withValues(alpha: isDark ? 0.72 : 0.88),
        shadows: isBrutal ? style.subtleShadows() : const [],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13.5, color: accent),
          const SizedBox(width: 5.5),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.88),
            ),
          ),
        ],
      ),
    );
  }
}

/// Optional modal setup guide opened on demand via a subtle help icon so the
/// login form stays calm and uncluttered.
Future<void> showLoginSetupGuideDialog(BuildContext context) {
  final theme = Theme.of(context);
  final colors = theme.colorScheme;
  return showIsleDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('首次连接指引'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _guideStep(
              theme,
              colors,
              '1. 启动 Mac 端 LightIsle',
              '首次使用请先在 Mac 原生管理端创建管理员账号并保持服务运行。',
            ),
            const SizedBox(height: 10),
            _guideStep(
              theme,
              colors,
              '2. 填入或自动发现地址',
              '同一家庭局域网下可点选「自动查找我的 NAS」，或直接输入连接地址。',
            ),
            const SizedBox(height: 10),
            _guideStep(
              theme,
              colors,
              '3. 登录账号',
              '使用 Mac 端创建的账号登录；若开启自签名 HTTPS，可展开安全设置核对指纹。',
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

Widget _guideStep(
  ThemeData theme,
  ColorScheme colors,
  String title,
  String body,
) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
          fontSize: 13.5,
        ),
      ),
      const SizedBox(height: 2),
      Text(
        body,
        style: theme.textTheme.bodySmall?.copyWith(
          color: colors.onSurfaceVariant,
          height: 1.42,
        ),
      ),
    ],
  );
}
