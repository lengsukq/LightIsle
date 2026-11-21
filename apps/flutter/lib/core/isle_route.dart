import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'isle_style.dart';

/// Platform-adaptive transition builders shared by [ThemeData.pageTransitionsTheme]
/// and [buildIslePageRoute].
const Map<TargetPlatform, PageTransitionsBuilder> islePageTransitionBuilders = {
  TargetPlatform.android: _IsleMobilePageTransitionsBuilder(
    PredictiveBackPageTransitionsBuilder(),
  ),
  TargetPlatform.iOS: _IsleMobilePageTransitionsBuilder(
    CupertinoPageTransitionsBuilder(),
  ),
  TargetPlatform.macOS: IsleDesktopPageTransitionsBuilder(),
  TargetPlatform.windows: IsleDesktopPageTransitionsBuilder(),
  TargetPlatform.linux: IsleDesktopPageTransitionsBuilder(),
};

/// Reduced-motion wrapper around native mobile route builders so edge-swipe
/// and predictive back gestures stay intact while programmatic jumps obey
/// [IsleMotion.reducedMotion].
class _IsleMobilePageTransitionsBuilder extends PageTransitionsBuilder {
  const _IsleMobilePageTransitionsBuilder(this.delegate);

  final PageTransitionsBuilder delegate;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (IsleMotion.reducedMotion(context) && !route.popGestureInProgress) {
      return child;
    }
    return delegate.buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}

/// Editorial gallery vertical lift + damped micro-scale + silk fade route
/// transition tailored for desktop targets.
class IsleDesktopPageTransitionsBuilder extends PageTransitionsBuilder {
  const IsleDesktopPageTransitionsBuilder();

  static final Animatable<double> _enterFade = CurveTween(
    curve: const Interval(0.0, 0.78, curve: Curves.easeOut),
  );
  static final Animatable<Offset> _enterSlide = Tween<Offset>(
    begin: const Offset(0, 0.016),
    end: Offset.zero,
  ).chain(CurveTween(curve: IsleMotion.gentleSpring));
  static final Animatable<double> _enterScale = Tween<double>(
    begin: 0.986,
    end: 1.0,
  ).chain(CurveTween(curve: IsleMotion.gentleSpring));

  static final Animatable<Offset> _exitSlide = Tween<Offset>(
    begin: Offset.zero,
    end: const Offset(0, -0.008),
  ).chain(CurveTween(curve: IsleMotion.silk));
  static final Animatable<double> _exitScale = Tween<double>(
    begin: 1.0,
    end: 0.990,
  ).chain(CurveTween(curve: IsleMotion.silk));
  static final Animatable<double> _exitFade = Tween<double>(
    begin: 1.0,
    end: 0.90,
  ).chain(CurveTween(curve: IsleMotion.silk));

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (IsleMotion.reducedMotion(context)) {
      return child;
    }
    return ColoredBox(
      color: Colors.transparent,
      child: SlideTransition(
        position: secondaryAnimation.drive(_exitSlide),
        child: ScaleTransition(
          scale: secondaryAnimation.drive(_exitScale),
          child: FadeTransition(
            opacity: secondaryAnimation.drive(_exitFade),
            child: FadeTransition(
              opacity: animation.drive(_enterFade),
              child: SlideTransition(
                position: animation.drive(_enterSlide),
                child: ScaleTransition(
                  scale: animation.drive(_enterScale),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IsleAdaptivePageRoute<T> extends MaterialPageRoute<T> {
  _IsleAdaptivePageRoute({
    required super.builder,
    super.settings,
    super.fullscreenDialog,
  });

  @override
  Duration get transitionDuration => IsleMotion.routeEnter;

  @override
  Duration get reverseTransitionDuration => IsleMotion.routeExit;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final builder = islePageTransitionBuilders[Theme.of(context).platform];
    if (builder != null) {
      return builder.buildTransitions(
        this,
        context,
        animation,
        secondaryAnimation,
        child,
      );
    }
    return super.buildTransitions(
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}

/// Platform-adaptive secondary route using LightIsle's transition builders
/// even when presented outside the root app theme.
Route<T> buildIslePageRoute<T>({
  required WidgetBuilder builder,
  RouteSettings? settings,
  bool fullscreenDialog = false,
}) => _IsleAdaptivePageRoute<T>(
  builder: builder,
  settings: settings,
  fullscreenDialog: fullscreenDialog,
);

/// Pushes a secondary page using [buildIslePageRoute].
Future<T?> pushIslePage<T>(
  BuildContext context,
  WidgetBuilder builder, {
  RouteSettings? settings,
  bool fullscreenDialog = false,
}) => Navigator.of(context).push<T>(
  buildIslePageRoute<T>(
    builder: builder,
    settings: settings,
    fullscreenDialog: fullscreenDialog,
  ),
);

class _IsleDialogRoute<T> extends DialogRoute<T> {
  _IsleDialogRoute({
    required super.context,
    required super.builder,
    super.themes,
    super.barrierColor,
    super.barrierDismissible,
    super.barrierLabel,
    super.useSafeArea,
    super.settings,
    super.anchorPoint,
    super.traversalEdgeBehavior,
  });

  @override
  Duration get transitionDuration => IsleMotion.modalEnter;

  @override
  Duration get reverseTransitionDuration => IsleMotion.modalExit;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (IsleMotion.reducedMotion(context)) {
      return child;
    }
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, dialogChild) {
        final isReverse = animation.status == AnimationStatus.reverse;
        final t = animation.value.clamp(0.0, 1.0);
        final progress = isReverse
            ? Curves.easeOutCubic.transform(t)
            : IsleMotion.gentleSpring.transform(t);
        final opacity = isReverse
            ? Curves.easeOut.transform(t)
            : const Interval(0.0, 0.72, curve: Curves.easeOut).transform(t);
        final scale = isReverse
            ? (0.968 + 0.032 * progress)
            : (0.945 + 0.055 * progress);
        final dy = isReverse
            ? (1.0 - progress) * 4.0
            : (1.0 - progress) * 10.0;
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, dy),
            child: Transform.scale(scale: scale, child: dialogChild),
          ),
        );
      },
    );
  }
}

/// Presents a Warm Editorial Gallery dialog with poised spring-scale & vertical
/// lift entrance, crisp fade-down exit, and automatic reduced-motion bypass.
Future<T?> showIsleDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  TraversalEdgeBehavior? traversalEdgeBehavior,
}) {
  final themes = InheritedTheme.capture(
    from: context,
    to: Navigator.of(context, rootNavigator: useRootNavigator).context,
  );
  return Navigator.of(context, rootNavigator: useRootNavigator).push<T>(
    _IsleDialogRoute<T>(
      context: context,
      builder: builder,
      barrierColor: barrierColor ?? const Color(0x70141210),
      barrierDismissible: barrierDismissible,
      barrierLabel: barrierLabel,
      useSafeArea: useSafeArea,
      settings: routeSettings,
      themes: themes,
      anchorPoint: anchorPoint,
      traversalEdgeBehavior:
          traversalEdgeBehavior ?? TraversalEdgeBehavior.closedLoop,
    ),
  );
}
