part of 'widgets.dart';

class IsleFloatingRailDock extends StatelessWidget {
  const IsleFloatingRailDock({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final style = IsleThemeStyle.of(context);
    final isDark = style.dark;
    final palette = style.palette;
    final isOpaque = IsleLayout.opaqueNavigation(context) ||
        style.preset.surfaceMaterial == IsleSurfaceMaterial.flatHairline ||
        style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal;
    final shape = style.shapeFor(
      IsleRadius.card,
      side: BorderSide(
        color: style.rimBorderColor(isGlass: !isOpaque),
        width: style.effectiveBorderWidth(),
      ),
    );
    final innerShape = style.shapeFor(IsleRadius.card);
    final topAlpha = style.prefersGlassSurface
        ? (isDark ? 0.72 : 0.82)
        : (isDark ? 0.90 : 0.94);
    final bottomAlpha = style.prefersGlassSurface
        ? (isDark ? 0.62 : 0.72)
        : (isDark ? 0.84 : 0.88);

    final dockBody = IntrinsicHeight(
      child: Container(
        decoration: ShapeDecoration(
          shape: shape,
          color: isOpaque ? palette['cardTop'] : null,
          gradient: isOpaque
              ? null
              : LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    palette['cardTop'].withValues(alpha: topAlpha),
                    palette['cardBottom'].withValues(alpha: bottomAlpha),
                  ],
                ),
          shadows: IsleLayout.opaqueNavigation(context)
              ? const []
              : style.cardShadows(),
        ),
        child: child,
      ),
    );

    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.only(
          left: 12,
          top: 10,
          bottom: 12,
          right: 8,
        ),
        child: ClipPath(
          clipper: ShapeBorderClipper(shape: innerShape),
          child: isOpaque
              ? dockBody
              : IsleGlassBackdrop(blur: IsleGlass.sigmaRegular, child: dockBody),
        ),
      ),
    );
  }
}

/// Bottom navigation dock adapting to the active [IsleThemeStyle].
class IsleFloatingBottomNavDock extends StatelessWidget {
  const IsleFloatingBottomNavDock({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final style = IsleThemeStyle.of(context);
    final isDark = style.dark;
    final palette = style.palette;
    final isOpaque = IsleLayout.opaqueNavigation(context) ||
        style.preset.surfaceMaterial == IsleSurfaceMaterial.flatHairline ||
        style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal;
    final topBorderColor = style.rimBorderColor(isGlass: !isOpaque);
    final topAlpha = style.prefersGlassSurface
        ? (isDark ? 0.74 : 0.82)
        : (isDark ? 0.92 : 0.95);
    final bottomAlpha = style.prefersGlassSurface
        ? (isDark ? 0.64 : 0.74)
        : (isDark ? 0.88 : 0.90);

    return RepaintBoundary(
      child: ClipRect(
        child: IsleGlassBackdrop(
          blur: isOpaque ? 0 : IsleGlass.sigmaRegular,
          child: Container(
            decoration: BoxDecoration(
              color: isOpaque ? palette['chrome'] : null,
              gradient: isOpaque
                  ? null
                  : LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        palette['cardTop'].withValues(alpha: topAlpha),
                        palette['cardBottom'].withValues(alpha: bottomAlpha),
                      ],
                    ),
              border: Border(
                top: BorderSide(
                  color: topBorderColor,
                  width: style.effectiveBorderWidth(),
                ),
              ),
              boxShadow: IsleLayout.opaqueNavigation(context) ||
                      style.preset.surfaceMaterial ==
                          IsleSurfaceMaterial.flatHairline ||
                      style.preset.surfaceMaterial ==
                          IsleSurfaceMaterial.neoBrutal
                  ? const []
                  : [
                      BoxShadow(
                        color: palette['shadow'].withValues(
                          alpha: isDark ? 0.34 : 0.06,
                        ),
                        blurRadius: 18,
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

/// Status and severity badge pill with crisp capsule border.
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
      padding: const EdgeInsets.symmetric(horizontal: 8.5, vertical: 3),
      decoration: BoxDecoration(
        color: effectiveColor.withValues(alpha: isDark ? 0.18 : 0.10),
        borderRadius: IsleRadius.brPill,
        border: Border.all(
          color: effectiveColor.withValues(alpha: isDark ? 0.34 : 0.22),
          width: 0.9,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11.5, color: effectiveColor),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: effectiveColor,
              letterSpacing: 0.1,
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
    this.spacing = 12,
    this.runSpacing = 12,
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

/// Unified secondary page AppBar with warm frosted parchment backdrop and
/// automatic macOS traffic-light clearance.
class IsleAppBar extends StatelessWidget implements PreferredSizeWidget {
  const IsleAppBar({
    super.key,
    this.title,
    this.actions,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.bottom,
    this.toolbarHeight = 50,
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
    final style = IsleThemeStyle.of(context);
    final palette = style.palette;
    final isDark = style.dark;
    final isOpaque = IsleLayout.opaqueNavigation(context) ||
        style.preset.surfaceMaterial == IsleSurfaceMaterial.flatHairline ||
        style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal;

    Widget? effectiveLeading = leading;
    double? effectiveLeadingWidth;

    if (isMac) {
      if (effectiveLeading != null) {
        effectiveLeading = Row(
          mainAxisSize: MainAxisSize.min,
          children: [const SizedBox(width: 78), effectiveLeading],
        );
        effectiveLeadingWidth = 78 + 44;
      } else if (automaticallyImplyLeading && canPop) {
        effectiveLeading = const Row(
          mainAxisSize: MainAxisSize.min,
          children: [SizedBox(width: 78), BackButton()],
        );
        effectiveLeadingWidth = 78 + 44;
      } else if (!canPop) {
        effectiveLeading = const SizedBox(width: 78);
        effectiveLeadingWidth = 78;
      }
    }

    final hairlineColor = style.rimBorderColor();
    final hairlineHeight = style.effectiveBorderWidth();

    final effectiveBottom =
        bottom ??
        PreferredSize(
          preferredSize: Size.fromHeight(hairlineHeight),
          child: Container(height: hairlineHeight, color: hairlineColor),
        );

    return AppBar(
      title: title != null
          ? DefaultTextStyle.merge(
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
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
                      ? palette['chrome']
                      : IsleGlass.regularTint(isDark, palette['chrome'])),
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
  _IslePopCoordinatorScope? _scope;
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
    _scope = context
        .dependOnInheritedWidgetOfExactType<_IslePopCoordinatorScope>();
    final nextHost = _scope?.host;
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
