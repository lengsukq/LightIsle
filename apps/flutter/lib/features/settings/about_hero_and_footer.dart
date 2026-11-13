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
    final floatY = math.sin(phase * math.pi * 2) * 5.0;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.14)
              : const Color(0xFF0071E3).withValues(alpha: 0.18),
          width: 1.0,
        ),
        boxShadow: IsleShadows.raised(isDark),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(25),
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
                    ? const EdgeInsets.fromLTRB(16, 18, 16, 20)
                    : (isWide
                          ? const EdgeInsets.fromLTRB(28, 26, 28, 28)
                          : const EdgeInsets.fromLTRB(22, 22, 22, 24));

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
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF10B981)
                                .withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: const Color(0xFF10B981)
                                  .withValues(alpha: 0.45),
                            ),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.fiber_manual_record_rounded,
                                size: 10,
                                color: Color(0xFF34D399),
                              ),
                              SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  'Mac 服务运行中 · LIVE REEL',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF34D399),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Text(
                            'v0.1.0 · Preview',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: isCompact ? 16 : 22),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Transform.translate(
                          offset: Offset(0, floatY),
                          child: Container(
                            width: isCompact ? 60 : 72,
                            height: isCompact ? 60 : 72,
                            padding: EdgeInsets.all(isCompact ? 10 : 12),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(
                                isCompact ? 18 : 22,
                              ),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.28),
                              ),
                            ),
                            child: IsleBrandMark(size: isCompact ? 40 : 48),
                          ),
                        ),
                        SizedBox(width: isCompact ? 12 : 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '轻屿 LightIsle',
                                style: TextStyle(
                                  fontSize: isWide ? 31 : (isCompact ? 24 : 28),
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.8,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                '让每一份珍藏，自在归屿 · 个人与家庭 Mac 轻量私有云',
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.4,
                                  color: Color(0xFFCBD5E1),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: isCompact ? 16 : 22),
                    const Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _HeroFeatureBadge(
                          icon: Icons.laptop_mac_rounded,
                          label: 'Mac 原生后台',
                          accent: Color(0xFF38BDF8),
                        ),
                        _HeroFeatureBadge(
                          icon: Icons.shield_rounded,
                          label: 'Time Machine 保护',
                          accent: Color(0xFF34D399),
                        ),
                        _HeroFeatureBadge(
                          icon: Icons.code_rounded,
                          label: '源码公开 · 非商业许可',
                          accent: Color(0xFFC4B5FD),
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
                      const SizedBox(width: 20),
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
      (Icons.memory_rounded, '原生核心守护', 'lightisled · 静默低功耗', Color(0xFF38BDF8)),
      (
        Icons.storage_rounded,
        '多盘物理主权',
        'device+inode · 独立配额',
        Color(0xFF34D399),
      ),
      (
        Icons.movie_filter_rounded,
        '巨幕智能刮削',
        'TMDB · 豆瓣 · NFO 4K',
        Color(0xFFF43F5E),
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.16),
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
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: items[i].$4.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(items[i].$1, size: 15, color: items[i].$4),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        items[i].$2,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      Text(
                        items[i].$3,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: Color(0xFF94A3B8),
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
              const SizedBox(height: 8),
              Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
              const SizedBox(height: 8),
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
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.40), width: 0.9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: accent),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
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
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF101827) : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.10)
              : const Color(0xFF0F172A).withValues(alpha: 0.08),
          width: 0.9,
        ),
        boxShadow: IsleShadows.card(isDark),
      ),
      padding: const EdgeInsets.all(18),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 640;

          final headerAndBody = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 10,
                runSpacing: 6,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.code_rounded, size: 20, color: colors.primary),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'GitHub 源码仓库',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: colors.primary.withValues(
                        alpha: isDark ? 0.18 : 0.08,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'lengsukq/LightIsle',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: colors.primary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '轻屿遵循 PolyForm 非商业许可公开全部源码，致力于打造纯净省心的个人与家庭 Mac 私有云。欢迎访问仓库点亮 Star 关注最新演进。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontSize: 13.5,
                  height: 1.45,
                ),
              ),
            ],
          );

          final actions = Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: onOpenRepo,
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
                label: const Text('访问代码仓库'),
              ),
              OutlinedButton.icon(
                onPressed: onCopyRepo,
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('复制链接'),
              ),
            ],
          );

          if (isWide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: headerAndBody),
                const SizedBox(width: 20),
                actions,
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [headerAndBody, const SizedBox(height: 14), actions],
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
        fontSize: 11.5,
        height: 1.55,
      ),
    );
  }
}
