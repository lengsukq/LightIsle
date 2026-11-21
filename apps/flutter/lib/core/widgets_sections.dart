part of 'widgets.dart';

enum IsleSectionTheme {
  overview(
    label: '仪表盘',
    icon: Icons.space_dashboard_rounded,
    color: Color(0xff0e6b74), // Modern Deep Aegean Teal
    gradient: [Color(0xff14818b), Color(0xff0a5259)],
  ),
  files(
    label: '文件',
    icon: Icons.folder_rounded,
    color: Color(0xffc7781a), // Refined Ochre Amber
    gradient: [Color(0xffdf8c28), Color(0xffa66111)],
  ),
  photos(
    label: '图库',
    icon: Icons.photo_library_rounded,
    color: Color(0xffc23b62), // Gallery Rose
    gradient: [Color(0xffdb4f77), Color(0xff9c2b4c)],
  ),
  cinema(
    label: '影视',
    icon: Icons.movie_rounded,
    color: Color(0xffd4653e), // Coral Clay
    gradient: [Color(0xffe67953), Color(0xffb54f2b)],
  ),
  settings(
    label: '设置',
    icon: Icons.settings_rounded,
    color: Color(0xff6b5799), // Modern Iris Slate
    gradient: [Color(0xff826db3), Color(0xff53427a)],
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

/// Tactile Gallery Bento Stat Card with warm recessed progress track and
/// tabular display typography. Shares identical height whether [progress] is
/// provided or null when [footer] is absent.
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
      tint: color,
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
                    fontSize: 12.5,
                    height: 1.25,
                    color: colors.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.1,
                  ),
                  strutStyle: const StrutStyle(
                    fontSize: 12.5,
                    height: 1.25,
                    forceStrutHeight: true,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 38),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        value,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontSize: 16,
                          height: 1.25,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.35,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                        strutStyle: const StrutStyle(
                          fontSize: 16,
                          height: 1.25,
                          forceStrutHeight: true,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant.withValues(alpha: 0.88),
                          fontSize: 12,
                          height: 1.25,
                        ),
                        strutStyle: const StrutStyle(
                          fontSize: 12,
                          height: 1.25,
                          forceStrutHeight: true,
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
          ),
          const SizedBox(height: 9),
          if (footer != null)
            footer!
          else if (progress == null)
            const SizedBox(height: 5)
          else
            Builder(
              builder: (context) {
                final style = IsleThemeStyle.of(context);
                final isSharp = style.preset.cornerStyle == IsleCornerStyle.sharp;
                final isBrutal =
                    style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal;
                final barRadius = isSharp
                    ? BorderRadius.circular(2)
                    : IsleRadius.brPill;
                final barHeight = isBrutal ? 7.0 : 5.0;
                return Container(
                  decoration: isBrutal
                      ? BoxDecoration(
                          borderRadius: barRadius,
                          border: Border.all(
                            color: style.rimBorderColor(),
                            width: 1.2,
                          ),
                        )
                      : null,
                  child: ClipRRect(
                    borderRadius: barRadius,
                    child: Stack(
                      children: [
                        Container(
                          height: barHeight,
                          color: colors.surfaceContainerHighest.withValues(
                            alpha: isDark ? 0.45 : 0.65,
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
                                  height: barHeight,
                                  decoration: BoxDecoration(
                                    borderRadius: barRadius,
                                    gradient:
                                        !isBrutal &&
                                            gradient != null &&
                                            gradient!.length >= 2
                                        ? LinearGradient(colors: gradient!)
                                        : null,
                                    color:
                                        isBrutal ||
                                            gradient == null ||
                                            gradient!.length < 2
                                        ? color.withValues(
                                            alpha: isDark ? 0.92 : 0.88,
                                          )
                                        : null,
                                  ),
                                ),
                              ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// Editorial Section Header with warm vertical pigment bar, optional inline `?`
/// help trigger beside the title, and trailing action slot.
class IsleSectionHeader extends StatelessWidget {
  const IsleSectionHeader({
    super.key,
    required this.title,
    this.action,
    this.padding,
    this.accentColor,
    this.helpTitle,
    this.helpBody,
    this.helpItems = const [],
  });

  final String title;
  final Widget? action;
  final EdgeInsetsGeometry? padding;
  final Color? accentColor;
  final String? helpTitle;
  final String? helpBody;
  final List<IsleHelpItem> helpItems;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final compact =
        MediaQuery.sizeOf(context).width < IsleLayout.compactPageWidth;
    final effectivePadding =
        padding ??
        (compact
            ? const EdgeInsets.fromLTRB(2, 14, 2, 7)
            : const EdgeInsets.fromLTRB(2, 18, 2, 9));
    final style = IsleThemeStyle.of(context);
    final barColor = accentColor ?? scheme.primary.withValues(alpha: 0.72);
    final hasHelp =
        (helpBody != null && helpBody!.trim().isNotEmpty) ||
        helpItems.isNotEmpty;
    final Widget marker = switch (style.preset.surfaceMaterial) {
      IsleSurfaceMaterial.flatHairline => Container(
        width: 8,
        height: 8,
        color: barColor,
      ),
      IsleSurfaceMaterial.neoBrutal => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: barColor,
          borderRadius: BorderRadius.circular(2.5),
          border: Border.all(color: style.rimBorderColor(), width: 1.5),
        ),
      ),
      IsleSurfaceMaterial.terminalGlow => Text(
        '//',
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12.5,
          fontWeight: FontWeight.w800,
          color: barColor,
        ),
      ),
      IsleSurfaceMaterial.frostedGlass || IsleSurfaceMaterial.paperEmbossed =>
        Container(
          width: 3,
          height: 13,
          decoration: BoxDecoration(
            color: barColor,
            borderRadius: IsleRadius.brPill,
          ),
        ),
    };
    return Padding(
      padding: effectivePadding,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                marker,
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontSize: compact ? 13.5 : 14,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.1,
                      color: scheme.onSurface.withValues(alpha: 0.90),
                    ),
                  ),
                ),
                if (hasHelp) ...[
                  const SizedBox(width: 3),
                  IsleHelpButton.compact(
                    title: helpTitle ?? title,
                    body: helpBody,
                    items: helpItems,
                    accentColor: accentColor,
                  ),
                ],
              ],
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
    this.offset = const Offset(0, 10),
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
      curve: const Interval(0.0, 0.80, curve: Curves.easeOut),
    );
    _slideAnimation = Tween<Offset>(
      begin: widget.offset,
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _controller, curve: IsleMotion.gentleSpring),
    );

    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      _delayTimer = Timer(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (IsleMotion.reducedMotion(context)) {
      _delayTimer?.cancel();
      _delayTimer = null;
      if (_controller.isAnimating || _controller.value < 1.0) {
        _controller.value = 1.0;
      }
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
/// and contextual banners.
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
      reverseDuration: const Duration(milliseconds: 185),
      switchInCurve: IsleMotion.gentleSpring,
      switchOutCurve: IsleMotion.exitCurve,
      layoutBuilder: (currentChild, previousChildren) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[...previousChildren, ?currentChild],
      ),
      transitionBuilder: (inner, animation) => ClipRect(
        child: SizeTransition(
          sizeFactor: animation,
          alignment: alignment,
          child: FadeTransition(opacity: animation, child: inner),
        ),
      ),
      child: expanded
          ? KeyedSubtree(key: const ValueKey<bool>(true), child: child)
          : const SizedBox.shrink(key: ValueKey<bool>(false)),
    );
  }
}

/// Non-overlapping editorial sub-view switcher for in-page mode, folder, and
/// collection transitions with asymmetric incoming lift and clean outgoing fade.
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
    final currentKey = ValueKey<Object>(modeKey);
    if (IsleMotion.reducedMotion(context)) {
      return KeyedSubtree(key: currentKey, child: child);
    }
    return AnimatedSwitcher(
      duration: duration,
      reverseDuration: const Duration(milliseconds: 155),
      switchInCurve: const Interval(
        0.18,
        1.0,
        curve: IsleMotion.gentleSpring,
      ),
      switchOutCurve: Curves.easeOutCubic,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: alignment,
        children: <Widget>[...previousChildren, ?currentChild],
      ),
      transitionBuilder: (switchedChild, animation) {
        final isIncoming = switchedChild.key == currentKey;
        if (!isIncoming) {
          return FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.993, end: 1.0).animate(animation),
              child: switchedChild,
            ),
          );
        }
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, IsleMotion.tabVerticalLift),
              end: Offset.zero,
            ).animate(animation),
            child: ScaleTransition(
              scale: Tween<double>(
                begin: IsleMotion.tabScaleBegin,
                end: 1.0,
              ).animate(animation),
              child: switchedChild,
            ),
          ),
        );
      },
      child: KeyedSubtree(key: currentKey, child: child),
    );
  }
}

/// Zero-overlap, two-stage fluid tab switcher.
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
      _awaitingSettle = true;
      if (_controller.isAnimating && activeOpacity < 0.25) {
        _previousIndex = null;
        _outgoingStartOpacity = 1.0;
        _currentIndex = widget.index;
        _controller.forward(from: 0.20);
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
                  begin: Offset(
                    IsleMotion.tabSlideDistance * 0.65 * direction,
                    0.008,
                  ),
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
                  end: 0.992,
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
