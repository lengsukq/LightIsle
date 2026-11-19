import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';

class AboutChapterContainer extends StatelessWidget {
  const AboutChapterContainer({
    super.key,
    required this.isDark,
    required this.chapterNumber,
    required this.eyebrow,
    required this.accent,
    required this.title,
    required this.subtitle,
    required this.stageCanvas,
    this.bottomContent,
  });

  final bool isDark;
  final String chapterNumber;
  final String eyebrow;
  final Color accent;
  final String title;
  final String subtitle;
  final Widget stageCanvas;
  final Widget? bottomContent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = IslePalette(isDark);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 480;
        final pad = compact ? 15.0 : 20.0;

        return Container(
          decoration: BoxDecoration(
            color: palette['cardTop'],
            borderRadius: IsleRadius.brHero,
            border: Border.all(
              color: IsleGlass.rimBorderColor(isDark),
              width: 1.0,
            ),
            boxShadow: IsleShadows.card(isDark),
          ),
          padding: EdgeInsets.all(pad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: isDark ? 0.20 : 0.10),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      chapterNumber,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: accent,
                      ),
                    ),
                  ),
                  Text(
                    eyebrow,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                      color: accent,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                title,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  fontSize: compact ? 19.5 : 21.5,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontSize: compact ? 13.5 : 14.0,
                  height: 1.48,
                ),
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: accent.withValues(alpha: isDark ? 0.28 : 0.18),
                      width: 0.9,
                    ),
                  ),
                  child: MediaQuery.withClampedTextScaling(
                    maxScaleFactor: 1.15,
                    child: stageCanvas,
                  ),
                ),
              ),
              if (bottomContent != null) ...[
                const SizedBox(height: 14),
                bottomContent!,
              ],
            ],
          ),
        );
      },
    );
  }
}

class AboutStageFloatingNode extends StatelessWidget {
  const AboutStageFloatingNode({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.isDark,
    required this.pulse,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
  final bool isDark;
  final double pulse;

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette(isDark);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: palette['cardTop'].withValues(alpha: isDark ? 0.92 : 0.96),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: accent.withValues(alpha: 0.30 + pulse * 0.35),
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.12 + pulse * 0.14),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: isDark ? 0.20 : 0.12),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 17, color: accent),
          ),
          const SizedBox(width: 9),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: palette['textPrimary'],
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: palette['secondaryText'],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AboutDriftingMemoryPill extends StatelessWidget {
  const AboutDriftingMemoryPill({
    super.key,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.icon,
    required this.offsetPhase,
    required this.isDark,
  });

  final String title;
  final String subtitle;
  final Color color;
  final IconData icon;
  final double offsetPhase;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette(isDark);
    final dy = math.sin(offsetPhase * math.pi * 2) * 2.5;
    return Transform.translate(
      offset: Offset(0, dy),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(
          color: palette['cardTop'].withValues(alpha: isDark ? 0.90 : 0.95),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.32), width: 0.8),
        ),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: color.withValues(alpha: isDark ? 0.22 : 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 15, color: color),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: palette['textPrimary'],
                    ),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: palette['secondaryText'],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AboutMiniCinemaPosterCard extends StatelessWidget {
  const AboutMiniCinemaPosterCard({
    super.key,
    required this.rank,
    required this.title,
    required this.tag,
    required this.rating,
    required this.accent,
    required this.progress,
  });

  final int rank;
  final String title;
  final String tag;
  final String rating;
  final Color accent;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: 0.28),
            const Color(0xFF1F1D19).withValues(alpha: 0.95),
            const Color(0xFF131210).withValues(alpha: 0.98),
          ],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.14),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFC25934),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  '#$rank',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10.5,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                  ),
                ),
              ),
              Text(
                '★ $rating',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFEAB057),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: Color(0xFFF5F2EC),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            tag,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Color(0xFFA8A198),
            ),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: (0.25 + progress * 0.65).clamp(0.0, 1.0),
              minHeight: 3.5,
              backgroundColor: Colors.white.withValues(alpha: 0.16),
              valueColor: const AlwaysStoppedAnimation<Color>(
                Color(0xFFE07A5F),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AboutDeviceCornerChip extends StatelessWidget {
  const AboutDeviceCornerChip({
    super.key,
    required this.icon,
    required this.label,
    required this.subtitle,
  });

  final IconData icon;
  final String label;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = IslePalette(isDark);
    final cyan = palette['brandCyan'];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: palette['cardTop'].withValues(alpha: isDark ? 0.90 : 0.95),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: cyan.withValues(alpha: 0.34),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: cyan),
          const SizedBox(width: 7),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: palette['textPrimary'],
                  ),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: palette['secondaryText'],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AboutAnimatedFeatureSpecCard extends StatelessWidget {
  const AboutAnimatedFeatureSpecCard({
    super.key,
    required this.isDark,
    required this.theme,
    required this.colors,
    required this.highlighted,
    required this.badgeLabel,
    required this.badgeColor,
    required this.icon,
    required this.iconGradient,
    required this.title,
    required this.subtitle,
    required this.tags,
  });

  final bool isDark;
  final ThemeData theme;
  final ColorScheme colors;
  final bool highlighted;
  final String badgeLabel;
  final Color badgeColor;
  final IconData icon;
  final List<Color> iconGradient;
  final String title;
  final String subtitle;
  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette(isDark);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: highlighted
            ? palette['cardItemTop']
            : palette['cardTop'].withValues(alpha: isDark ? 0.85 : 1.0),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: highlighted
              ? badgeColor.withValues(alpha: isDark ? 0.52 : 0.38)
              : IsleGlass.rimBorderColor(isDark),
          width: highlighted ? 1.2 : 0.85,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(11),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: iconGradient,
                  ),
                ),
                child: Icon(icon, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2.5,
                          ),
                          decoration: BoxDecoration(
                            color: badgeColor.withValues(
                              alpha: isDark ? 0.18 : 0.10,
                            ),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            badgeLabel,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: badgeColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontSize: 13.5,
                        height: 1.42,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 5,
            children: [
              for (final tag in tags)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: palette['cardItemBottom'],
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    tag,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: colors.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class AboutCinemaAudioSpectrumPill extends StatelessWidget {
  const AboutCinemaAudioSpectrumPill({super.key, required this.phase});

  final double phase;

  @override
  Widget build(BuildContext context) {
    final angle = phase * math.pi * 2;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 6; i++) ...[
            Container(
              width: 2.5,
              height:
                  5.0 +
                  8.0 *
                      (0.5 + 0.5 * math.sin(angle * 3.0 + i * 0.7)).clamp(
                        0.0,
                        1.0,
                      ),
              decoration: BoxDecoration(
                color: i.isEven
                    ? const Color(0xFFE07A5F)
                    : Colors.white.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (i < 5) const SizedBox(width: 2.5),
          ],
          const SizedBox(width: 6),
          const Text(
            'DOLBY AUDIO',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: Color(0xFFD6D0C6),
            ),
          ),
        ],
      ),
    );
  }
}

class AboutCinemaPlayerScrubberBar extends StatelessWidget {
  const AboutCinemaPlayerScrubberBar({super.key, required this.phase});

  final double phase;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showFormatTag = constraints.maxWidth >= 230;
          return Row(
            children: [
              const Icon(
                Icons.play_arrow_rounded,
                size: 16,
                color: Color(0xFFE07A5F),
              ),
              const SizedBox(width: 5),
              const Text(
                '原片直放',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFF5F2EC),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (0.18 + phase * 0.72).clamp(0.0, 1.0),
                    minHeight: 4.5,
                    backgroundColor: Colors.white.withValues(alpha: 0.16),
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(0xFFE07A5F),
                    ),
                  ),
                ),
              ),
              if (showFormatTag) ...[
                const SizedBox(width: 8),
                const Text(
                  '4K · HDR10',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFD6D0C6),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
