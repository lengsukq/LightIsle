part of 'widgets.dart';

class IsleFloatingRailDock extends StatelessWidget {
  const IsleFloatingRailDock({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette.of(context);
    final isOpaque = IsleLayout.opaqueNavigation(context);
    final shape = IsleShapes.hero(
      side: BorderSide(
        color: IsleGlass.rimBorderColor(isDark, isGlass: true),
        width: 1.0,
      ),
    );
    final innerShape = IsleShapes.hero();

    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.only(
          left: 16,
          top: 12,
          bottom: 16,
          right: 12,
        ),
        child: ClipPath(
          clipper: ShapeBorderClipper(shape: innerShape),
          child: IsleGlassBackdrop(
            blur: IsleGlass.sigmaRegular,
            child: IntrinsicHeight(
              child: Container(
                decoration: ShapeDecoration(
                  shape: shape,
                  color: isOpaque ? palette['cardTop'] : null,
                  gradient: isOpaque
                      ? null
                      : LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: isDark
                              ? [
                                  const Color(0xff242a3d)
                                      .withValues(alpha: 0.78),
                                  const Color(0xff141826)
                                      .withValues(alpha: 0.68),
                                ]
                              : [
                                  Colors.white.withValues(alpha: 0.82),
                                  const Color(0xfff5f8fd)
                                      .withValues(alpha: 0.68),
                                ],
                        ),
                  shadows: isOpaque ? const [] : IsleShadows.floating(isDark),
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// iOS Liquid Glass bottom navigation dock with luminous specular top rim
/// and frosted backdrop blur.
class IsleFloatingBottomNavDock extends StatelessWidget {
  const IsleFloatingBottomNavDock({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette.of(context);
    final isOpaque = IsleLayout.opaqueNavigation(context);
    final topBorderColor = isDark
        ? Colors.white.withValues(alpha: 0.16)
        : Colors.white.withValues(alpha: 0.85);

    return RepaintBoundary(
      child: ClipRect(
        child: IsleGlassBackdrop(
          blur: IsleGlass.sigmaRegular,
          child: Container(
            decoration: BoxDecoration(
              color: isOpaque ? palette['cardTop'] : null,
              gradient: isOpaque
                  ? null
                  : LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: isDark
                          ? [
                              const Color(0xff202536).withValues(alpha: 0.82),
                              const Color(0xff121520).withValues(alpha: 0.74),
                            ]
                          : [
                              Colors.white.withValues(alpha: 0.84),
                              const Color(0xfff4f7fc).withValues(alpha: 0.72),
                            ],
                    ),
              border: Border(
                top: BorderSide(color: topBorderColor, width: 0.75),
              ),
              boxShadow: isOpaque
                  ? const []
                  : [
                      BoxShadow(
                        color: isDark
                            ? Colors.black.withValues(alpha: 0.35)
                            : const Color(0xff0f172a).withValues(alpha: 0.06),
                        blurRadius: 24,
                        offset: const Offset(0, -4),
                      ),
                    ],
            ),
            child: SafeArea(
              top: false,
              left: false,
              right: false,
              bottom: true,
              child: Padding(
                padding: IsleSpace.floatingDockMargin,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Status and severity badge pill with iOS capsule aesthetic
class IsleBadgePill extends StatelessWidget {
  const IsleBadgePill({super.key, required this.label, this.color, this.icon});

  final String label;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: effectiveColor.withValues(alpha: isDark ? 0.20 : 0.12),
        borderRadius: IsleRadius.brPill,
        border: Border.all(
          color: effectiveColor.withValues(alpha: isDark ? 0.35 : 0.25),
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: effectiveColor),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: effectiveColor,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Adaptive responsive grid that arranges cards into 1, 2, or more columns
/// based on container constraints and system font scaling.
class IsleResponsiveGrid extends StatelessWidget {
  const IsleResponsiveGrid({
    super.key,
    required this.children,
    this.minItemWidth = 300,
    this.maxColumns = 3,
    this.spacing = 10,
    this.runSpacing = 10,
  });

  final List<Widget> children;
  final double minItemWidth;
  final int maxColumns;
  final double spacing;
  final double runSpacing;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final adjustedMinWidth = minItemWidth * (textScale > 1.3 ? 1.25 : 1.0);
        final rawColumns = (width / adjustedMinWidth).floor().clamp(
          1,
          maxColumns,
        );
        final columns = math.min(rawColumns.toInt(), children.length);
        final itemWidth = (width - (columns - 1) * spacing) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: runSpacing,
          children: [
            for (final child in children)
              SizedBox(width: itemWidth, child: child),
          ],
        );
      },
    );
  }
}

/// Unified secondary page AppBar with frosted Liquid Glass backdrop and automatic
/// macOS traffic-light clearance so scrolling content never collides with titles.
class IsleAppBar extends StatelessWidget implements PreferredSizeWidget {
  const IsleAppBar({
    super.key,
    this.title,
    this.actions,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.bottom,
    this.toolbarHeight = 52,
    this.centerTitle = false,
    this.foregroundColor,
    this.backgroundColor,
  });

  final Widget? title;
  final List<Widget>? actions;
  final Widget? leading;
  final bool automaticallyImplyLeading;
  final PreferredSizeWidget? bottom;
  final double toolbarHeight;
  final bool centerTitle;
  final Color? foregroundColor;
  final Color? backgroundColor;

  @override
  Size get preferredSize =>
      Size.fromHeight(toolbarHeight + (bottom?.preferredSize.height ?? 1.0));

  @override
  Widget build(BuildContext context) {
    final isMac = defaultTargetPlatform == TargetPlatform.macOS;
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final isOpaque = IsleLayout.opaqueNavigation(context);

    Widget? effectiveLeading = leading;
    double? effectiveLeadingWidth;

    if (isMac) {
      if (effectiveLeading != null) {
        effectiveLeading = Row(
          mainAxisSize: MainAxisSize.min,
          children: [const SizedBox(width: 78), effectiveLeading],
        );
        effectiveLeadingWidth = 78 + 48;
      } else if (automaticallyImplyLeading && canPop) {
        effectiveLeading = const Row(
          mainAxisSize: MainAxisSize.min,
          children: [SizedBox(width: 78), BackButton()],
        );
        effectiveLeadingWidth = 78 + 48;
      } else if (!canPop) {
        effectiveLeading = const SizedBox(width: 78);
        effectiveLeadingWidth = 78;
      }
    }

    final hairlineColor = isDark
        ? Colors.white.withValues(alpha: 0.09)
        : const Color(0xff0f172a).withValues(alpha: 0.06);

    final effectiveBottom =
        bottom ??
        PreferredSize(
          preferredSize: const Size.fromHeight(1.0),
          child: Container(height: 0.6, color: hairlineColor),
        );

    return AppBar(
      title: title != null
          ? DefaultTextStyle.merge(
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.25,
              ),
              child: title!,
            )
          : null,
      actions: actions,
      actionsPadding: const EdgeInsets.only(right: 8),
      leading: effectiveLeading,
      leadingWidth: effectiveLeadingWidth,
      automaticallyImplyLeading: isMac ? false : automaticallyImplyLeading,
      bottom: effectiveBottom,
      toolbarHeight: toolbarHeight,
      centerTitle: centerTitle,
      foregroundColor: foregroundColor,
      backgroundColor: Colors.transparent,
      flexibleSpace: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: isMac
            ? (_) => unawaited(
                const MethodChannel('lightisle/native-video')
                    .invokeMethod<void>('startWindowDrag')
                    .catchError((_) {}),
              )
            : null,
        onDoubleTap: isMac
            ? () => unawaited(
                const MethodChannel('lightisle/native-video')
                    .invokeMethod<void>('doubleClickTitlebar')
                    .catchError((_) {}),
              )
            : null,
        child: RepaintBoundary(
          child: IsleGlassBackdrop(
            blur: IsleGlass.sigmaRegular,
            child: ColoredBox(
              color:
                  backgroundColor ??
                  (isOpaque
                      ? colors.surface
                      : IsleGlass.regularTint(isDark, colors.surface)),
            ),
          ),
        ),
      ),
    );
  }
}

class _IslePopCoordinatorScope extends InheritedWidget {
  const _IslePopCoordinatorScope({required this.host, required super.child});

  final _IslePopScopeHostState host;

  @override
  bool updateShouldNotify(_IslePopCoordinatorScope oldWidget) =>
      host != oldWidget.host;
}

/// Hosts a single [ModalRoute] [PopEntry] for a multi-tab shell so visible
/// descendants using [IsleChildPopScope] intercept Back cleanly without double
/// invocation or interference from offstage tabs.
class IslePopScopeHost extends StatefulWidget {
  const IslePopScopeHost({
    super.key,
    required this.child,
    this.canPop = true,
    this.onPopInvokedWithResult,
  });

  final Widget child;
  final bool canPop;
  final PopInvokedWithResultCallback<Object?>? onPopInvokedWithResult;

  @override
  State<IslePopScopeHost> createState() => _IslePopScopeHostState();
}

class _IslePopScopeHostState extends State<IslePopScopeHost>
    implements PopEntry<Object?> {
  final List<_IsleChildPopScopeState> _children = <_IsleChildPopScopeState>[];
  ModalRoute<dynamic>? _route;
  bool _disposed = false;

  @override
  late final ValueNotifier<bool> canPopNotifier = ValueNotifier<bool>(
    widget.canPop,
  );

  void _registerChild(_IsleChildPopScopeState child) {
    if (!_children.contains(child)) {
      _children.add(child);
    }
    _syncCanPop();
  }

  void _unregisterChild(_IsleChildPopScopeState child) {
    _children.remove(child);
    _syncCanPop();
  }

  void _syncCanPop() {
    if (_disposed || !mounted) return;
    final hasBlockingChild = _children.any((c) => !c.widget.canPop);
    canPopNotifier.value = widget.canPop && !hasBlockingChild;
  }

  @override
  void onPopInvoked(bool didPop) {
    throw UnimplementedError();
  }

  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (didPop) return;
    for (var i = _children.length - 1; i >= 0; i--) {
      final child = _children[i];
      if (!child.widget.canPop) {
        child.widget.onPopInvokedWithResult?.call(false, result);
        return;
      }
    }
    if (!widget.canPop) {
      widget.onPopInvokedWithResult?.call(false, result);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextRoute = ModalRoute.of(context);
    if (nextRoute != _route) {
      _route?.unregisterPopEntry(this);
      _route = nextRoute;
      _route?.registerPopEntry(this);
    }
    _syncCanPop();
  }

  @override
  void didUpdateWidget(covariant IslePopScopeHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncCanPop();
  }

  @override
  void dispose() {
    _disposed = true;
    _children.clear();
    _route?.unregisterPopEntry(this);
    canPopNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _IslePopCoordinatorScope(host: this, child: widget.child);
  }
}

/// Coordinates Back handling with an enclosing [IslePopScopeHost] when mounted
/// inside a multi-tab shell (ignoring inactive offstage tabs), and falls back
/// to [PopScope] when presented standalone.
class IsleChildPopScope extends StatefulWidget {
  const IsleChildPopScope({
    super.key,
    required this.child,
    this.canPop = true,
    this.onPopInvokedWithResult,
  });

  final Widget child;
  final bool canPop;
  final PopInvokedWithResultCallback<Object?>? onPopInvokedWithResult;

  @override
  State<IsleChildPopScope> createState() => _IsleChildPopScopeState();
}

class _IsleChildPopScopeState extends State<IsleChildPopScope> {
  _IslePopScopeHostState? _host;
  bool _tickerEnabled = true;

  void _syncHostRegistration() {
    final host = _host;
    if (host == null) return;
    if (_tickerEnabled) {
      host._registerChild(this);
    } else {
      host._unregisterChild(this);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextHost = context
        .dependOnInheritedWidgetOfExactType<_IslePopCoordinatorScope>()
        ?.host;
    final nextTicker = TickerMode.valuesOf(context).enabled;
    if (nextHost != _host) {
      _host?._unregisterChild(this);
      _host = nextHost;
    }
    _tickerEnabled = nextTicker;
    _syncHostRegistration();
  }

  @override
  void didUpdateWidget(covariant IsleChildPopScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncHostRegistration();
  }

  @override
  void deactivate() {
    _host?._unregisterChild(this);
    super.deactivate();
  }

  @override
  void dispose() {
    _host?._unregisterChild(this);
    _host = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_host != null) return widget.child;
    return PopScope<Object?>(
      canPop: widget.canPop,
      onPopInvokedWithResult: widget.onPopInvokedWithResult,
      child: widget.child,
    );
  }
}
