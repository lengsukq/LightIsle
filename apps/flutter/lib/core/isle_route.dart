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

/// Damped micro-scale + fade route transition tailored for desktop targets.
class IsleDesktopPageTransitionsBuilder extends PageTransitionsBuilder {
  const IsleDesktopPageTransitionsBuilder();

  static final Animatable<double> _enterFade = CurveTween(
    curve: IsleMotion.curve,
  );
  static final Animatable<double> _enterScale = Tween<double>(
    begin: 0.985,
    end: 1.0,
  ).chain(CurveTween(curve: IsleMotion.spring));
  static final Animatable<double> _exitScale = Tween<double>(
    begin: 1.0,
    end: 0.992,
  ).chain(CurveTween(curve: IsleMotion.curve));
  static final Animatable<double> _exitFade = Tween<double>(
    begin: 1.0,
    end: 0.92,
  ).chain(CurveTween(curve: IsleMotion.curve));

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
      child: ScaleTransition(
        scale: secondaryAnimation.drive(_exitScale),
        child: FadeTransition(
          opacity: secondaryAnimation.drive(_exitFade),
          child: FadeTransition(
            opacity: animation.drive(_enterFade),
            child: ScaleTransition(
              scale: animation.drive(_enterScale),
              child: child,
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
