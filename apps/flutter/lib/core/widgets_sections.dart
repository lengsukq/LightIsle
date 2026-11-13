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
    this.trailingChart,
    this.footer,
    this.onTap,
  });

  final String title;
  final String value;
  final String detail;
  final IconData icon;
  final Color color;
  final List<Color>? gradient;
  final double? progress;
  final Widget? trailingChart;
  final Widget? footer;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return IsleSurface(
      onTap: onTap,
      radius: IsleRadius.item,
      padding: IsleSpace.cardPaddingCompact,
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IsleSquircleBadge(
                icon: icon,
                color: color,
                size: 28,
                iconSize: 15.5,
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
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
                  ],
                ),
              ),
              if (trailingChart != null) ...[
                const SizedBox(width: 8),
                trailingChart!,
              ],
            ],
          ),
          const SizedBox(height: 8),
          if (footer != null)
            footer!
          else if (progress == null)
            const SizedBox(height: 4)
          else
            ClipRRect(
              borderRadius: IsleRadius.brPill,
              child: Stack(
                children: [
                  Container(
                    height: 4,
                    color: colors.surfaceContainerHighest.withValues(
                      alpha: isDark ? 0.40 : 0.55,
                    ),
                  ),
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(
                      begin: 0.0,
                      end: progress!.clamp(0.0, 1.0),
                    ),
                    duration: IsleMotion.reveal,
                    curve: IsleMotion.curve,
                    builder: (context, animatedProgress, _) =>
                        FractionallySizedBox(
                          widthFactor: animatedProgress,
                          child: Container(
                            height: 4,
                            decoration: BoxDecoration(
                              borderRadius: IsleRadius.brPill,
                              gradient:
                                  gradient != null && gradient!.length >= 2
                                  ? LinearGradient(colors: gradient!)
                                  : null,
                              color: gradient == null || gradient!.length < 2
                                  ? color.withValues(
                                      alpha: isDark ? 0.88 : 0.82,
                                    )
                                  : null,
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
    this.padding,
  });

  final String title;
  final Widget? action;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final compact =
        MediaQuery.sizeOf(context).width < IsleLayout.compactPageWidth;
    final effectivePadding =
        padding ??
        (compact
            ? const EdgeInsets.fromLTRB(2, 12, 2, 6)
            : const EdgeInsets.fromLTRB(4, 16, 4, 8));
    return Padding(
      padding: effectivePadding,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.25,
                color: Theme.of(context).colorScheme.onSurfaceVariant
                    .withValues(alpha: 0.85),
              ),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// Gentle staggered entrance wrapper with subtle opacity and vertical settle.
class IsleAnimatedEntrance extends StatefulWidget {
  const IsleAnimatedEntrance({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.offset = const Offset(0, 8),
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
    _controller = AnimationController(vsync: this, duration: IsleMotion.normal);
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
    if (IsleMotion.reducedMotion(context)) {
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

/// Spring-damped reveal & collapse wrapper for search bars, selection toolbars,
/// and disclosure blocks. Smoothly interpolates both height and opacity on
/// open and close, unmounting the child once collapse completes.
class IsleAnimatedExpand extends StatelessWidget {
  const IsleAnimatedExpand({
    super.key,
    required this.expanded,
    required this.child,
    this.duration = IsleMotion.normal,
    this.alignment = Alignment.topCenter,
  });

  final bool expanded;
  final Widget child;
  final Duration duration;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    if (IsleMotion.reducedMotion(context)) {
      return expanded ? child : const SizedBox.shrink();
    }
    return AnimatedSwitcher(
      duration: duration,
      reverseDuration: const Duration(milliseconds: 180),
      switchInCurve: IsleMotion.spring,
      switchOutCurve: Curves.easeOutCubic,
      layoutBuilder: (currentChild, previousChildren) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[...previousChildren, ?currentChild],
      ),
      transitionBuilder: (inner, animation) => ClipRect(
        child: SizeTransition(
          sizeFactor: animation,
          alignment: Alignment.topCenter,
          child: FadeTransition(opacity: animation, child: inner),
        ),
      ),
      child: expanded
          ? KeyedSubtree(key: const ValueKey<bool>(true), child: child)
          : const SizedBox.shrink(key: ValueKey<bool>(false)),
    );
  }
}

/// Non-overlapping sub-view switcher for in-page mode transitions (e.g.,
/// Dashboard <-> Files, Grid <-> List, Cinema/Photos sub-channels).
class IsleModeSwitcher extends StatelessWidget {
  const IsleModeSwitcher({
    super.key,
    required this.modeKey,
    required this.child,
    this.duration = IsleMotion.tabSwitch,
    this.alignment = Alignment.topCenter,
  });

  final Object modeKey;
  final Widget child;
  final Duration duration;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    if (IsleMotion.reducedMotion(context)) {
      return KeyedSubtree(key: ValueKey(modeKey), child: child);
    }
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: IsleMotion.tabEnterInterval,
      switchOutCurve: IsleMotion.tabExitInterval,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: alignment,
        children: <Widget>[...previousChildren, ?currentChild],
      ),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(
            begin: IsleMotion.tabScaleBegin,
            end: 1.0,
          ).animate(animation),
          child: child,
        ),
      ),
      child: KeyedSubtree(key: ValueKey(modeKey), child: child),
    );
  }
}

/// Zero-overlap, two-stage fluid tab switcher:
/// Outgoing tab fades out rapidly in [IsleMotion.tabExitInterval] (0..32%)
/// while incoming tab glides in with [IsleMotion.tabEnterInterval] (16..100%),
/// preventing double-text ghosting and rapid-tap opacity jumps.
class IsleFluidTabSwitcher extends StatefulWidget {
  const IsleFluidTabSwitcher({
    super.key,
    required this.index,
    required this.children,
    this.duration = IsleMotion.tabSwitch,
    this.onSettled,
  });

  final int index;
  final List<Widget> children;
  final Duration duration;
  final VoidCallback? onSettled;

  @override
  State<IsleFluidTabSwitcher> createState() => _IsleFluidTabSwitcherState();
}

class _IsleFluidTabSwitcherState extends State<IsleFluidTabSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _enterAnim;
  late final CurvedAnimation _exitAnim;
  late int _currentIndex;
  int? _previousIndex;
  double _outgoingStartOpacity = 1.0;
  bool _awaitingSettle = false;

  void _notifySettledPostFrame(int targetIndex) {
    final callback = widget.onSettled;
    if (callback == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _currentIndex == targetIndex && _previousIndex == null) {
        callback();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.index;
    _controller =
        AnimationController(vsync: this, duration: widget.duration, value: 1.0)
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed && mounted) {
              if (_previousIndex != null || _outgoingStartOpacity != 1.0) {
                setState(() {
                  _previousIndex = null;
                  _outgoingStartOpacity = 1.0;
                });
              }
              if (_awaitingSettle) {
                _awaitingSettle = false;
                widget.onSettled?.call();
              }
            }
          });
    _enterAnim = CurvedAnimation(
      parent: _controller,
      curve: IsleMotion.tabEnterInterval,
    );
    _exitAnim = CurvedAnimation(
      parent: _controller,
      curve: IsleMotion.tabExitInterval,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (IsleMotion.reducedMotion(context) &&
        (_controller.isAnimating ||
            _controller.value < 1.0 ||
            _previousIndex != null)) {
      _awaitingSettle = false;
      _controller.value = 1.0;
      _previousIndex = null;
      _outgoingStartOpacity = 1.0;
      _notifySettledPostFrame(_currentIndex);
    }
  }

  @override
  void didUpdateWidget(IsleFluidTabSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.duration != oldWidget.duration) {
      _controller.duration = widget.duration;
    }
    if (widget.index != _currentIndex) {
      if (IsleMotion.reducedMotion(context)) {
        _awaitingSettle = false;
        _previousIndex = null;
        _outgoingStartOpacity = 1.0;
        _currentIndex = widget.index;
        if (_controller.isAnimating || _controller.value != 1.0) {
          _controller.value = 1.0;
        }
        _notifySettledPostFrame(_currentIndex);
        return;
      }
      final activeOpacity = _enterAnim.value.clamp(0.0, 1.0);
      // If a rapid switch occurs before the active tab is visually settled
      // (< 25% entered), avoid snapping a dimly-faded outgoing tab back to 1.0.
      _awaitingSettle = true;
      if (_controller.isAnimating && activeOpacity < 0.25) {
        _previousIndex = null;
        _outgoingStartOpacity = 1.0;
        _currentIndex = widget.index;
        _controller.forward(from: 0.16);
      } else {
        _outgoingStartOpacity = _controller.isAnimating ? activeOpacity : 1.0;
        _previousIndex = _currentIndex;
        _currentIndex = widget.index;
        _controller.forward(from: 0.0);
      }
    }
  }

  @override
  void dispose() {
    _enterAnim.dispose();
    _exitAnim.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations = IsleMotion.reducedMotion(context);
    final settled =
        disableAnimations ||
        (!_controller.isAnimating &&
            _controller.value == 1.0 &&
            _previousIndex == null);
    final direction =
        (_previousIndex == null || _currentIndex >= _previousIndex!)
        ? 1.0
        : -1.0;

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: List.generate(widget.children.length, (i) {
          final isCurrent = i == _currentIndex;
          final isPrevious = !disableAnimations && i == _previousIndex;
          final isVisible = isCurrent || isPrevious;
          final opacityAnim = settled && isCurrent
              ? const AlwaysStoppedAnimation<double>(1.0)
              : isCurrent
              ? _enterAnim
              : isPrevious
              ? Tween<double>(
                  begin: _outgoingStartOpacity,
                  end: 0.0,
                ).animate(_exitAnim)
              : const AlwaysStoppedAnimation<double>(0.0);
          final slideAnim = (settled || !isCurrent)
              ? const AlwaysStoppedAnimation<Offset>(Offset.zero)
              : Tween<Offset>(
                  begin: Offset(IsleMotion.tabSlideDistance * direction, 0),
                  end: Offset.zero,
                ).animate(_enterAnim);
          final scaleAnim = settled
              ? const AlwaysStoppedAnimation<double>(1.0)
              : isCurrent
              ? Tween<double>(
                  begin: IsleMotion.tabScaleBegin,
                  end: 1.0,
                ).animate(_enterAnim)
              : isPrevious
              ? Tween<double>(
                  begin: 1.0,
                  end: IsleMotion.tabScaleBegin,
                ).animate(_exitAnim)
              : const AlwaysStoppedAnimation<double>(1.0);

          return Offstage(
            key: ValueKey<int>(i),
            offstage: !isVisible,
            child: IgnorePointer(
              ignoring: !isCurrent,
              child: FadeTransition(
                opacity: opacityAnim,
                child: SlideTransition(
                  position: slideAnim,
                  child: ScaleTransition(
                    scale: scaleAnim,
                    child: TickerMode(
                      enabled: isCurrent,
                      child: RepaintBoundary(child: widget.children[i]),
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
