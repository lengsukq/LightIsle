import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/isle_theme.dart';
import '../../core/widgets.dart';
import 'about_hero_and_footer.dart';
import 'about_showcase_sections.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key, this.continuousReel});

  static const String repoUrl = 'https://github.com/lengsukq/LightIsle';

  /// Overrides whether the 60fps reel loops indefinitely. Defaults to true on
  /// real devices and single-pass entrance in automated `pumpAndSettle` tests.
  final bool? continuousReel;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _reelController;
  final ScrollController _scrollController = ScrollController();

  double _scrollOffset = 0.0;
  int _activeChapter = 0;
  bool _autoTourActive = false;

  static const List<(String, double)> _chapters = <(String, double)>[
    ('序幕', 0),
    ('01 原生核心', 420),
    ('02 光影图库', 1120),
    ('03 私人影院', 1480),
    ('04 跨端互联', 1840),
  ];

  @override
  void initState() {
    super.initState();
    _reelController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..addListener(_onReelTick);
    _scrollController.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncReelMode();
  }

  bool get _shouldLoopContinuously {
    if (widget.continuousReel != null) return widget.continuousReel!;
    final media = MediaQuery.maybeOf(context);
    if (media?.disableAnimations == true || media?.highContrast == true) {
      return false;
    }
    final bindingName = WidgetsBinding.instance.runtimeType.toString();
    if (bindingName.contains('TestWidgetsFlutterBinding') ||
        bindingName.contains('AutomatedTest')) {
      return false;
    }
    return true;
  }

  void _syncReelMode() {
    final media = MediaQuery.maybeOf(context);
    final disableAnimations =
        media?.disableAnimations == true || media?.highContrast == true;
    if (disableAnimations) {
      _reelController.stop();
      _reelController.value = 0.35;
      return;
    }
    if (_shouldLoopContinuously) {
      if (!_reelController.isAnimating) {
        _reelController.repeat();
      }
    } else if (!_reelController.isAnimating && _reelController.value == 0.0) {
      _reelController.animateTo(
        0.35,
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _onReelTick() {
    if (!_autoTourActive || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (!position.hasContentDimensions) return;
    final maxExtent = position.maxScrollExtent;
    if (maxExtent <= 0) return;
    final nextOffset = _scrollController.offset + 1.5;
    if (nextOffset >= maxExtent) {
      _scrollController.jumpTo(0);
    } else {
      _scrollController.jumpTo(nextOffset);
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final offset = pos.pixels.clamp(0.0, double.infinity);

    var chapter = 0;
    for (var i = _chapters.length - 1; i >= 0; i--) {
      if (offset >= _chapters[i].$2 - 140) {
        chapter = i;
        break;
      }
    }

    if ((offset - _scrollOffset).abs() > 1.0 || chapter != _activeChapter) {
      setState(() {
        _scrollOffset = offset;
        _activeChapter = chapter;
      });
    }
  }

  void _toggleAutoTour() {
    final next = !_autoTourActive;
    setState(() => _autoTourActive = next);
    if (next && !_reelController.isAnimating) {
      _reelController.repeat();
    } else if (!next && !_shouldLoopContinuously) {
      _reelController.stop();
    }
  }

  Future<void> _jumpToChapter(int index) async {
    if (!_scrollController.hasClients) return;
    setState(() {
      _autoTourActive = false;
      _activeChapter = index;
    });
    final maxExtent = _scrollController.position.hasContentDimensions
        ? _scrollController.position.maxScrollExtent
        : 2200.0;
    final target = _chapters[index].$2.clamp(0.0, maxExtent);
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (disableAnimations) {
      _scrollController.jumpTo(target);
    } else {
      await _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 520),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _openRepo(BuildContext context) async {
    final uri = Uri.parse(AboutPage.repoUrl);
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && context.mounted) {
        _copyRepo(context, note: '无法自动唤起浏览器，已将链接复制到剪贴板');
      }
    } catch (_) {
      if (context.mounted) {
        _copyRepo(context, note: '打开失败，已将链接复制到剪贴板');
      }
    }
  }

  void _copyRepo(BuildContext context, {String? note}) {
    Clipboard.setData(const ClipboardData(text: AboutPage.repoUrl));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(note ?? '已复制 GitHub 仓库链接：${AboutPage.repoUrl}'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _reelController.removeListener(_onReelTick);
    _reelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final disableAnimations = MediaQuery.disableAnimationsOf(context);

    return Scaffold(
      appBar: const IsleAppBar(
        title: Text('关于轻屿'),
        bottom: PreferredSize(
          preferredSize: Size.zero,
          child: SizedBox.shrink(),
        ),
      ),
      body: IsleContent(
        maxWidth: 1040,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final inset = IsleLayout.pageInset(constraints.maxWidth);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(inset, 4, inset, 12),
                  child: _WebpageChapterBar(
                    chapters: _chapters,
                    activeIndex: _activeChapter,
                    autoTourActive: _autoTourActive,
                    isDark: isDark,
                    colors: colors,
                    onSelectChapter: _jumpToChapter,
                    onToggleAutoTour: _toggleAutoTour,
                  ),
                ),
                Expanded(
                  child: NotificationListener<UserScrollNotification>(
                    onNotification: (notification) {
                      if (notification.direction != ScrollDirection.idle &&
                          _autoTourActive) {
                        setState(() => _autoTourActive = false);
                      }
                      return false;
                    },
                    child: AnimatedBuilder(
                      animation: _reelController,
                      builder: (context, _) {
                        final phase = _reelController.value;
                        return SingleChildScrollView(
                          key: const Key('aboutShowcaseScrollView'),
                          controller: _scrollController,
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: EdgeInsets.fromLTRB(
                            inset,
                            0,
                            inset,
                            inset + 64,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ScrollShowcaseStage(
                                scrollOffset: _scrollOffset,
                                anchorOffset: 0,
                                disableAnimations: disableAnimations,
                                child: AboutCinemaHeroStage(
                                  phase: phase,
                                  scrollOffset: _scrollOffset,
                                  isDark: isDark,
                                  colors: colors,
                                  theme: theme,
                                ),
                              ),
                              const SizedBox(height: 16),
                              ScrollShowcaseStage(
                                scrollOffset: _scrollOffset,
                                anchorOffset: 240,
                                disableAnimations: disableAnimations,
                                child: AboutOpenSourceShowcaseCard(
                                  isDark: isDark,
                                  colors: colors,
                                  theme: theme,
                                  onOpenRepo: () => _openRepo(context),
                                  onCopyRepo: () => _copyRepo(context),
                                ),
                              ),
                              const SizedBox(height: 18),
                              ScrollShowcaseStage(
                                scrollOffset: _scrollOffset,
                                anchorOffset: 520,
                                disableAnimations: disableAnimations,
                                child: AboutArchitectureShowcase(
                                  phase: phase,
                                  scrollOffset: _scrollOffset,
                                  isDark: isDark,
                                  colors: colors,
                                  theme: theme,
                                ),
                              ),
                              const SizedBox(height: 18),
                              ScrollShowcaseStage(
                                scrollOffset: _scrollOffset,
                                anchorOffset: 1180,
                                disableAnimations: disableAnimations,
                                child: AboutMediaExperienceShowcase(
                                  phase: phase,
                                  scrollOffset: _scrollOffset,
                                  isDark: isDark,
                                  colors: colors,
                                  theme: theme,
                                ),
                              ),
                              const SizedBox(height: 18),
                              ScrollShowcaseStage(
                                scrollOffset: _scrollOffset,
                                anchorOffset: 1820,
                                disableAnimations: disableAnimations,
                                child: AboutCrossPlatformShowcase(
                                  phase: phase,
                                  scrollOffset: _scrollOffset,
                                  isDark: isDark,
                                  colors: colors,
                                  theme: theme,
                                ),
                              ),
                              const SizedBox(height: 26),
                              AboutFooterNotice(colors: colors, theme: theme),
                              const SizedBox(height: 20),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _WebpageChapterBar extends StatefulWidget {
  const _WebpageChapterBar({
    required this.chapters,
    required this.activeIndex,
    required this.autoTourActive,
    required this.isDark,
    required this.colors,
    required this.onSelectChapter,
    required this.onToggleAutoTour,
  });

  final List<(String, double)> chapters;
  final int activeIndex;
  final bool autoTourActive;
  final bool isDark;
  final ColorScheme colors;
  final ValueChanged<int> onSelectChapter;
  final VoidCallback onToggleAutoTour;

  @override
  State<_WebpageChapterBar> createState() => _WebpageChapterBarState();
}

class _WebpageChapterBarState extends State<_WebpageChapterBar> {
  final ScrollController _barScrollController = ScrollController();

  @override
  void didUpdateWidget(covariant _WebpageChapterBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.activeIndex != oldWidget.activeIndex &&
        _barScrollController.hasClients &&
        _barScrollController.position.hasContentDimensions) {
      final maxExtent = _barScrollController.position.maxScrollExtent;
      if (maxExtent > 0 && widget.chapters.length > 1) {
        final fraction = widget.activeIndex / (widget.chapters.length - 1);
        final target = (maxExtent * fraction).clamp(0.0, maxExtent);
        if (MediaQuery.disableAnimationsOf(context)) {
          _barScrollController.jumpTo(target);
        } else {
          _barScrollController.animateTo(
            target,
            duration: IsleMotion.normal,
            curve: Curves.easeOutCubic,
          );
        }
      }
    }
  }

  @override
  void dispose() {
    _barScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final opaque = IsleLayout.opaqueNavigation(context);
    final isDark = widget.isDark;
    final colors = widget.colors;
    final chapters = widget.chapters;

    final barContent = MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: Container(
        height: 44,
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: opaque
              ? colors.surface
              : (isDark
                    ? const Color(0xCC111827)
                    : Colors.white.withValues(alpha: 0.90)),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.12)
                : const Color(0xFF0F172A).withValues(alpha: 0.08),
            width: 0.8,
          ),
          boxShadow: IsleShadows.card(isDark),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 620;

            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: isWide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            for (var i = 0; i < chapters.length; i++) ...[
                              Expanded(
                                child: _ChapterPill(
                                  label: chapters[i].$1,
                                  selected: i == widget.activeIndex,
                                  colors: colors,
                                  isDark: isDark,
                                  expandWidth: true,
                                  onTap: () => widget.onSelectChapter(i),
                                ),
                              ),
                              if (i < chapters.length - 1)
                                const SizedBox(width: 4),
                            ],
                          ],
                        )
                      : SingleChildScrollView(
                          controller: _barScrollController,
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              for (var i = 0; i < chapters.length; i++) ...[
                                _ChapterPill(
                                  label: chapters[i].$1,
                                  selected: i == widget.activeIndex,
                                  colors: colors,
                                  isDark: isDark,
                                  expandWidth: false,
                                  onTap: () => widget.onSelectChapter(i),
                                ),
                                if (i < chapters.length - 1)
                                  const SizedBox(width: 4),
                              ],
                            ],
                          ),
                        ),
                ),
                Container(
                  width: 1,
                  height: 18,
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.12)
                      : const Color(0xFF0F172A).withValues(alpha: 0.08),
                ),
                _AutoTourPill(
                  active: widget.autoTourActive,
                  compact: false,
                  colors: colors,
                  isDark: isDark,
                  onTap: widget.onToggleAutoTour,
                ),
              ],
            );
          },
        ),
      ),
    );

    if (opaque) return barContent;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: barContent,
      ),
    );
  }
}

class _ChapterPill extends StatelessWidget {
  const _ChapterPill({
    required this.label,
    required this.selected,
    required this.colors,
    required this.isDark,
    required this.expandWidth,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final ColorScheme colors;
  final bool isDark;
  final bool expandWidth;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: AnimatedContainer(
          duration: IsleMotion.fast,
          height: 34,
          padding: EdgeInsets.symmetric(horizontal: expandWidth ? 8 : 12),
          decoration: BoxDecoration(
            color: selected
                ? colors.primary.withValues(alpha: isDark ? 0.24 : 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            mainAxisSize: expandWidth ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  strutStyle: const StrutStyle(
                    fontSize: 12.5,
                    height: 1.2,
                    forceStrutHeight: true,
                  ),
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.2,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    color: selected ? colors.primary : colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AutoTourPill extends StatelessWidget {
  const _AutoTourPill({
    required this.active,
    required this.compact,
    required this.colors,
    required this.isDark,
    required this.onTap,
  });

  final bool active;
  final bool compact;
  final ColorScheme colors;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: const Key('aboutAutoTourButton'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: AnimatedContainer(
          duration: IsleMotion.fast,
          height: 34,
          padding: EdgeInsets.symmetric(horizontal: compact ? 9 : 12),
          decoration: BoxDecoration(
            color: active
                ? colors.primary.withValues(alpha: isDark ? 0.24 : 0.14)
                : colors.surfaceContainerHighest.withValues(
                    alpha: isDark ? 0.45 : 0.55,
                  ),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                active
                    ? Icons.pause_circle_filled_rounded
                    : Icons.play_circle_fill_rounded,
                size: 15,
                color: active ? colors.primary : colors.onSurface,
              ),
              const SizedBox(width: 4),
              Text(
                active ? (compact ? '暂停' : '暂停巡礼') : (compact ? '巡礼' : '自动巡礼'),
                strutStyle: const StrutStyle(
                  fontSize: 12.5,
                  height: 1.2,
                  forceStrutHeight: true,
                ),
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  color: active ? colors.primary : colors.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
