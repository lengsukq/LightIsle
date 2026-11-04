part of 'widgets.dart';

enum IsleSectionTheme {
  overview(
    label: '概览',
    icon: Icons.space_dashboard_rounded,
    color: Color(0xff0071e3),
    gradient: [Color(0xff2589ff), Color(0xff0066cc)],
  ),
  files(
    label: '文件',
    icon: Icons.folder_rounded,
    color: Color(0xff0ea5e9),
    gradient: [Color(0xff38bdf8), Color(0xff0284c7)],
  ),
  photos(
    label: '图库',
    icon: Icons.photo_library_rounded,
    color: Color(0xffec4899),
    gradient: [Color(0xfff472b6), Color(0xffdb2777)],
  ),
  cinema(
    label: '影视',
    icon: Icons.movie_rounded,
    color: Color(0xfff97316),
    gradient: [Color(0xfffb923c), Color(0xffea580c)],
  ),
  settings(
    label: '设置',
    icon: Icons.settings_rounded,
    color: Color(0xff8b5cf6),
    gradient: [Color(0xffa78bfa), Color(0xff7c3aed)],
  );

  const IsleSectionTheme({
    required this.label,
    required this.icon,
    required this.color,
    required this.gradient,
  });

  final String label;
  final IconData icon;
  final Color color;
  final List<Color> gradient;
}

/// Bento Vitality Gauge card matching macOS LiquidHealthGauge and Web Bento.
class IsleBentoStatCard extends StatelessWidget {
  const IsleBentoStatCard({
    super.key,
    required this.title,
    required this.value,
    required this.detail,
    required this.icon,
    required this.color,
    this.gradient,
    this.progress,
    this.onTap,
  });

  final String title;
  final String value;
  final String detail;
  final IconData icon;
  final Color color;
  final List<Color>? gradient;
  final double? progress;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return IsleSurface(
      onTap: onTap,
      radius: 16,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IsleSquircleBadge(
                icon: icon,
                color: color,
                gradient: gradient,
                shadow: true,
                size: 28,
                iconSize: 16,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (progress != null)
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            detail,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant.withValues(alpha: 0.85),
              fontSize: 12,
              height: 1.25,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          // Reserve an identical footer slot for all four metric cards.
          // Network speed has no meaningful percentage, so a fake gauge
          // would mislead users; an empty baseline keeps its height aligned.
          const SizedBox(height: 8),
          if (progress == null)
            const SizedBox(height: 4)
          else
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: Stack(
                children: [
                  Container(
                    height: 4,
                    color: colors.surfaceContainerHighest.withValues(
                      alpha: 0.4,
                    ),
                  ),
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(
                      begin: 0.0,
                      end: progress!.clamp(0.0, 1.0),
                    ),
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOutCubic,
                    builder: (context, animatedProgress, _) =>
                        FractionallySizedBox(
                          widthFactor: animatedProgress,
                          child: Container(
                            height: 4,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(999),
                              color: color,
                            ),
                          ),
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

/// Clean Inset Section Header for Grouped Lists and Settings.
class IsleSectionHeader extends StatelessWidget {
  const IsleSectionHeader({
    super.key,
    required this.title,
    this.action,
    this.padding = const EdgeInsets.fromLTRB(4, 24, 4, 10),
  });

  final String title;
  final Widget? action;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.35,
              color: Theme.of(context).colorScheme.onSurfaceVariant
                  .withValues(alpha: 0.85),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// Fluid staggered entrance wrapper with smooth opacity and slide reveal.
class IsleAnimatedEntrance extends StatefulWidget {
  const IsleAnimatedEntrance({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.offset = const Offset(0, 18),
  });

  final Widget child;
  final Duration delay;
  final Offset offset;

  @override
  State<IsleAnimatedEntrance> createState() => _IsleAnimatedEntranceState();
}

class _IsleAnimatedEntranceState extends State<IsleAnimatedEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnimation;
  late final Animation<Offset> _slideAnimation;
  Timer? _delayTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: IsleMotion.reveal);
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.85, curve: Curves.easeOut),
    );
    _slideAnimation = Tween<Offset>(
      begin: widget.offset,
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: IsleMotion.spring));

    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      _delayTimer = Timer(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return widget.child;
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Opacity(
        opacity: _fadeAnimation.value,
        child: Transform.translate(offset: _slideAnimation.value, child: child),
      ),
      child: widget.child,
    );
  }
}

/// Fluid, continuous tab switcher that blends smooth cross-fades and subtle spring scale
/// while preserving the full state of all child views.
class IsleFluidTabSwitcher extends StatefulWidget {
  const IsleFluidTabSwitcher({
    super.key,
    required this.index,
    required this.children,
    this.duration = const Duration(milliseconds: 260),
  });

  final int index;
  final List<Widget> children;
  final Duration duration;

  @override
  State<IsleFluidTabSwitcher> createState() => _IsleFluidTabSwitcherState();
}

class _IsleFluidTabSwitcherState extends State<IsleFluidTabSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late int _currentIndex;
  int? _previousIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.index;
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: 1.0,
    );
  }

  @override
  void didUpdateWidget(IsleFluidTabSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index != _currentIndex) {
      _previousIndex = _currentIndex;
      _currentIndex = widget.index;
      _controller.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (disableAnimations) {
      return IndexedStack(index: _currentIndex, children: widget.children);
    }

    final curved = CurvedAnimation(
      parent: _controller,
      curve: IsleMotion.spring,
    );

    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: List.generate(widget.children.length, (i) {
          final isCurrent = i == _currentIndex;
          final isPrevious = i == _previousIndex;

          if (!isCurrent && !isPrevious) {
            return Offstage(
              offstage: true,
              child: TickerMode(enabled: false, child: widget.children[i]),
            );
          }

          final direction =
              (_previousIndex == null || _currentIndex >= _previousIndex!)
              ? 1.0
              : -1.0;

          if (isCurrent) {
            return FadeTransition(
              opacity: curved,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: Offset(0.035 * direction, 0),
                  end: Offset.zero,
                ).animate(curved),
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.99, end: 1.0).animate(curved),
                  child: TickerMode(enabled: true, child: widget.children[i]),
                ),
              ),
            );
          }

          // isPrevious
          return FadeTransition(
            opacity: Tween<double>(begin: 1.0, end: 0.0).animate(curved),
            child: SlideTransition(
              position: Tween<Offset>(
                begin: Offset.zero,
                end: Offset(-0.035 * direction, 0),
              ).animate(curved),
              child: ScaleTransition(
                scale: Tween<double>(begin: 1.0, end: 0.99).animate(curved),
                child: TickerMode(enabled: false, child: widget.children[i]),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// Floating vertical dock container for desktop/tablet NavigationRail
