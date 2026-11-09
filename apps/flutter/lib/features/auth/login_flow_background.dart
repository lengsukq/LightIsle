import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';

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
    final baseTop = dark ? const Color(0xff0b0f19) : const Color(0xfff7f9fc);
    final baseMid = dark ? const Color(0xff101624) : const Color(0xfff2f6fb);
    final baseBottom = dark ? const Color(0xff141c2e) : const Color(0xffedf2f9);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: const [0.0, 0.52, 1.0],
          colors: [baseTop, baseMid, baseBottom],
        ).createShader(rect),
    );

    final angle = motion.value * math.pi * 2;
    final extent = math.max(size.width, size.height);
    final pools = <(Color, double, double, double, double)>[
      (
        dark ? const Color(0xff2563eb) : const Color(0xff93c5fd),
        .08 + .08 * math.cos(angle),
        .10 + .10 * math.sin(angle),
        .68,
        dark ? .14 : .18,
      ),
      (
        dark ? const Color(0xff334155) : const Color(0xffcbd5e1),
        .90 + .08 * math.sin(angle * .72),
        .64 + .10 * math.cos(angle * .82),
        .62,
        dark ? .14 : .22,
      ),
      (
        dark ? const Color(0xff1e3a8a) : const Color(0xffbfdbfe),
        .48 + .14 * math.sin(angle * .61),
        .96 + .08 * math.cos(angle * .68),
        .56,
        dark ? .12 : .16,
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
              color.withValues(alpha: alpha * 0.35),
              color.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.48, 1.0],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }

    // Three broad, slowly drifting translucent liquid-silk ribbons.
    for (var index = 0; index < 3; index++) {
      final drift =
          math.sin(angle + index * math.pi * .68) * size.height * .036;
      final y = size.height * (.26 + index * .24) + drift;
      final ribbon = Path()
        ..moveTo(-size.width * .2, y)
        ..cubicTo(
          size.width * .26,
          y - extent * .15,
          size.width * .64,
          y + extent * .12,
          size.width * 1.2,
          y - extent * .08,
        )
        ..lineTo(size.width * 1.2, y + extent * .12)
        ..cubicTo(
          size.width * .64,
          y + extent * .23,
          size.width * .22,
          y - extent * .03,
          -size.width * .2,
          y + extent * .10,
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
              (dark ? const Color(0xff7dd3fc) : Colors.white).withValues(
                alpha: dark ? .05 : .24,
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

class LoginBrandHeader extends StatelessWidget {
  const LoginBrandHeader({super.key, required this.wide});

  final bool wide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: wide
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        Container(
          padding: EdgeInsets.all(wide ? 12 : 9),
          decoration: ShapeDecoration(
            shape: IsleShapes.squircle(
              wide ? 32 : 24,
              side: BorderSide(
                color: IsleGlass.specularBorder(isDark),
                width: 1.2,
              ),
            ),
            gradient: RadialGradient(
              center: const Alignment(-0.35, -0.45),
              radius: 1.15,
              colors: isDark
                  ? [
                      Colors.white.withValues(alpha: 0.14),
                      colors.primary.withValues(alpha: 0.18),
                    ]
                  : [
                      Colors.white.withValues(alpha: 0.94),
                      colors.primary.withValues(alpha: 0.10),
                    ],
            ),
            shadows: IsleShadows.glow(
              colors.primary,
              opacity: isDark ? 0.28 : 0.16,
            ),
          ),
          child: IsleBrandMark(size: wide ? 88 : 66),
        ),
        SizedBox(height: wide ? 26 : 16),
        Text(
          '轻屿 LightIsle',
          textAlign: wide ? TextAlign.start : TextAlign.center,
          style:
              (wide
                      ? theme.textTheme.displaySmall
                      : theme.textTheme.headlineMedium)
                  ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.7),
        ),
        const SizedBox(height: 10),
        Text(
          '连接你的个人 NAS，随时查看文件、照片与影视。',
          textAlign: wide ? TextAlign.start : TextAlign.center,
          style:
              (wide ? theme.textTheme.titleMedium : theme.textTheme.bodyMedium)
                  ?.copyWith(color: colors.onSurfaceVariant, height: 1.55),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: wide ? WrapAlignment.start : WrapAlignment.center,
          children: [
            _featurePill(context, Icons.bolt_rounded, '本机直连'),
            _featurePill(context, Icons.photo_library_outlined, '原画相册'),
            _featurePill(context, Icons.movie_outlined, '私人影院'),
          ],
        ),
        if (wide) ...[
          const SizedBox(height: 32),
          Text(
            '你自己的空间，始终由你掌控。',
            style: theme.textTheme.titleLarge?.copyWith(
              color: colors.onSurface.withValues(alpha: 0.86),
              fontWeight: FontWeight.w600,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 16),
          _wideFeatureItem(
            context,
            Icons.laptop_mac_rounded,
            'Mac 轻量驻留，零云端中转，局域网毫秒级响应',
          ),
          const SizedBox(height: 10),
          _wideFeatureItem(
            context,
            Icons.verified_user_outlined,
            '支持 HTTPS 自签名证书 SHA-256 指纹固定校验',
          ),
        ],
      ],
    );
  }

  Widget _featurePill(BuildContext context, IconData icon, String label) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: ShapeDecoration(
        shape: const StadiumBorder(),
        color: isDark
            ? Colors.white.withValues(alpha: 0.07)
            : Colors.white.withValues(alpha: 0.72),
        shadows: [
          BoxShadow(
            color: colors.primary.withValues(alpha: isDark ? 0.10 : 0.05),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colors.primary),
          const SizedBox(width: 5),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: colors.onSurface.withValues(alpha: 0.82),
            ),
          ),
        ],
      ),
    );
  }

  Widget _wideFeatureItem(BuildContext context, IconData icon, String text) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: ShapeDecoration(
            shape: IsleShapes.squircle(9),
            color: colors.primary.withValues(alpha: 0.12),
          ),
          child: Icon(icon, size: 15, color: colors.primary),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class LoginSetupHelpCard extends StatelessWidget {
  const LoginSetupHelpCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colors = theme.colorScheme;
    return Container(
      decoration: ShapeDecoration(
        shape: IsleShapes.interactive(
          side: BorderSide(color: IsleGlass.hairlineBorder(isDark)),
        ),
        color: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : colors.primary.withValues(alpha: 0.04),
      ),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: const Key('loginSetupHelp'),
          tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          shape: const Border(),
          collapsedShape: const Border(),
          leading: Icon(
            Icons.help_outline_rounded,
            size: 20,
            color: colors.primary,
          ),
          title: Text(
            '第一次连接？查看 3 步设置',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          children: const [
            ListTile(
              leading: Icon(Icons.laptop_mac_rounded),
              title: Text('1. 在 Mac 上启动 LightIsle'),
              subtitle: Text('首次使用请先完成管理员账号初始化，并保持 NAS 服务运行。'),
            ),
            ListTile(
              leading: Icon(Icons.wifi_rounded),
              title: Text('2. 确认连接方式'),
              subtitle: Text('手机与 Mac 处于同一家庭网络时，可以自动查找 NAS 或输入 Mac 显示的连接地址。'),
            ),
            ListTile(
              leading: Icon(Icons.verified_user_outlined),
              title: Text('3. 登录并核对安全信息'),
              subtitle: Text('使用 Mac 上创建的用户名和密码。若启用自签名 HTTPS，请核对证书 SHA-256 指纹。'),
            ),
          ],
        ),
      ),
    );
  }
}
