import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import 'about_showcase_painters.dart';

/// Hero Sanctuary Stage (Continuous Video-Like Canvas + Editorial Header).
/// Adapts across Mobile (stacked compact), iPad & PC (2-column with live HUD).
class AboutCinemaHeroStage extends StatelessWidget {
  const AboutCinemaHeroStage({
    super.key,
    required this.phase,
    required this.scrollOffset,
    required this.isDark,
  });

  final double phase;
  final double scrollOffset;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final floatY = math.sin(phase * math.pi * 2) * 4.0;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: const Color(0xFFF5F2EB).withValues(alpha: 0.16),
          width: 1.0,
        ),
        boxShadow: IsleShadows.raised(isDark),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(23),
        child: Stack(
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                key: const Key('aboutHeroReelCanvas'),
                child: CustomPaint(
                  painter: HeroSanctuaryReelPainter(
                    phase: phase,
                    scrollDelta: scrollOffset * 0.002,
                    isDark: isDark,
                  ),
                ),
              ),
            ),
            LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth >= 660;
                final isCompact = constraints.maxWidth < 420;
                final pad = isCompact
                    ? const EdgeInsets.fromLTRB(16, 16, 16, 18)
                    : (isWide
                          ? const EdgeInsets.fromLTRB(24, 20, 24, 22)
                          : const EdgeInsets.fromLTRB(20, 18, 20, 20));

                final mainEditorial = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF4AC28E)
                                .withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: const Color(0xFF4AC28E)
                                  .withValues(alpha: 0.42),
                            ),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.fiber_manual_record_rounded,
                                size: 9,
                                color: Color(0xFF67C99E),
                              ),
                              SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  'Mac 服务运行中 · LIVE REEL',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF67C99E),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF5F2EB)
                                .withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Text(
                            'v0.1.0 · Preview',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFFF5F2EC),
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: isCompact ? 14 : 16),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Transform.translate(
                          offset: Offset(0, floatY),
                          child: Container(
                            width: isCompact ? 54 : 62,
                            height: isCompact ? 54 : 62,
                            padding: EdgeInsets.all(isCompact ? 9 : 10),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF5F2EB)
                                  .withValues(alpha: 0.11),
                              borderRadius: BorderRadius.circular(
                                isCompact ? 16 : 18,
                              ),
                              border: Border.all(
                                color: const Color(0xFFF5F2EB)
                                    .withValues(alpha: 0.24),
                              ),
                            ),
                            child: IsleBrandMark(size: isCompact ? 36 : 42),
                          ),
                        ),
                        SizedBox(width: isCompact ? 12 : 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '轻屿 LightIsle',
                                style: TextStyle(
                                  fontSize: isWide ? 27 : (isCompact ? 22 : 25),
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.6,
                                  color: const Color(0xFFF7F4EE),
                                ),
                              ),
                              const SizedBox(height: 3),
                              const Text(
                                '让每一份珍藏，自在归屿 · 个人与家庭 Mac 轻量私有云',
                                style: TextStyle(
                                  fontSize: 13.5,
                                  height: 1.4,
                                  color: Color(0xFFD6D0C6),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: isCompact ? 14 : 16),
                    const Wrap(
                      spacing: 8,
                      runSpacing: 7,
                      children: [
                        _HeroFeatureBadge(
                          icon: Icons.laptop_mac_rounded,
                          label: 'Mac 原生后台',
                          accent: Color(0xFF72BCCB),
                        ),
                        _HeroFeatureBadge(
                          icon: Icons.shield_rounded,
                          label: 'Time Machine 保护',
                          accent: Color(0xFF67C99E),
                        ),
                        _HeroFeatureBadge(
                          icon: Icons.code_rounded,
                          label: '源码公开 · 非商业许可',
                          accent: Color(0xFFEAB057),
                        ),
                      ],
                    ),
                  ],
                );

                if (!isWide) {
                  return Padding(padding: pad, child: mainEditorial);
                }

                return Padding(
                  padding: pad,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(flex: 6, child: mainEditorial),
                      const SizedBox(width: 18),
                      Expanded(flex: 4, child: _HeroTelemetryHud(phase: phase)),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroTelemetryHud extends StatelessWidget {
  const _HeroTelemetryHud({required this.phase});

  final double phase;

  @override
  Widget build(BuildContext context) {
    const items = <(IconData, String, String, Color)>[
      (Icons.memory_rounded, '原生核心守护', 'lightisled · 静默低功耗', Color(0xFF72BCCB)),
      (
        Icons.storage_rounded,
        '多盘物理主权',
        'device+inode · 独立配额',
        Color(0xFF67C99E),
      ),
      (
        Icons.movie_filter_rounded,
        '巨幕智能刮削',
        'TMDB · 豆瓣 · NFO 4K',
        Color(0xFFE58B68),
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF12110F).withValues(alpha: 0.56),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFF5F2EB).withValues(alpha: 0.14),
          width: 0.9,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: items[i].$4.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(items[i].$1, size: 14, color: items[i].$4),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        items[i].$2,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFF5F2EC),
                        ),
                      ),
                      Text(
                        items[i].$3,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: Color(0xFFA8A198),
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: items[i].$4.withValues(
                      alpha:
                          0.45 +
                          0.55 *
                              (0.5 +
                                  0.5 *
                                      math.sin(phase * math.pi * 2 + i * 1.1)),
                    ),
                  ),
                ),
              ],
            ),
            if (i < items.length - 1) ...[
              const SizedBox(height: 6),
              Divider(
                height: 1,
                color: const Color(0xFFF5F2EB).withValues(alpha: 0.08),
              ),
              const SizedBox(height: 6),
            ],
          ],
        ],
      ),
    );
  }
}

class _HeroFeatureBadge extends StatelessWidget {
  const _HeroFeatureBadge({
    required this.icon,
    required this.label,
    required this.accent,
  });

  final IconData icon;
  final String label;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF12110F).withValues(alpha: 0.36),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: accent.withValues(alpha: 0.40), width: 0.9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: accent),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AboutOpenSourceShowcaseCard extends StatelessWidget {
  const AboutOpenSourceShowcaseCard({
    super.key,
    required this.isDark,
    required this.colors,
    required this.theme,
    required this.onOpenRepo,
    required this.onCopyRepo,
  });

  final bool isDark;
  final ColorScheme colors;
  final ThemeData theme;
  final VoidCallback onOpenRepo;
  final VoidCallback onCopyRepo;

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette(isDark);
    return Container(
      decoration: BoxDecoration(
        color: palette['cardTop'],
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: IsleGlass.rimBorderColor(isDark),
          width: 1.0,
        ),
        boxShadow: IsleShadows.card(isDark),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 640;

          final headerAndBody = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.code_rounded, size: 18, color: colors.primary),
                      const SizedBox(width: 7),
                      Flexible(
                        child: Text(
                          'GitHub 源码仓库',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: colors.primary.withValues(
                        alpha: isDark ? 0.18 : 0.08,
                      ),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      'lengsukq/LightIsle',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: colors.primary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '轻屿遵循 PolyForm 非商业许可公开全部源码，致力于打造纯净省心的个人与家庭 Mac 私有云。欢迎访问仓库点亮 Star 关注最新演进。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontSize: 12.5,
                  height: 1.45,
                ),
              ),
            ],
          );

          final actions = Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: onOpenRepo,
                icon: const Icon(Icons.open_in_new_rounded, size: 15),
                label: const Text('访问代码仓库'),
              ),
              OutlinedButton.icon(
                onPressed: onCopyRepo,
                icon: const Icon(Icons.copy_rounded, size: 15),
                label: const Text('复制链接'),
              ),
            ],
          );

          if (isWide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: headerAndBody),
                const SizedBox(width: 18),
                actions,
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [headerAndBody, const SizedBox(height: 12), actions],
          );
        },
      ),
    );
  }
}

class AboutFooterNotice extends StatelessWidget {
  const AboutFooterNotice({
    super.key,
    required this.colors,
    required this.theme,
  });

  final ColorScheme colors;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Text(
      '轻屿 LightIsle · 探索更自由的个人与家庭云\n'
      'PolyForm Noncommercial 1.0.0 · 商业使用需单独授权\n'
      'https://polyformproject.org/licenses/noncommercial/1.0.0\n'
      'Required Notice: Copyright (c) 2026 lengsukq (https://github.com/lengsukq)\n'
      'GitHub @lengsukq/LightIsle',
      textAlign: TextAlign.center,
      style: theme.textTheme.bodySmall?.copyWith(
        fontFamily: 'monospace',
        color: colors.onSurfaceVariant.withValues(alpha: 0.72),
        fontSize: 11,
        height: 1.5,
      ),
    );
  }
}
