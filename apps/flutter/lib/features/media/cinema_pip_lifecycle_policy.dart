import 'package:flutter/widgets.dart';

/// Small, platform-neutral part of native PiP coordination. The Android PiP
/// adapter owns requests and platform events; the page owns the video player.
///
/// Keeping this decision pure avoids accidentally pausing an active native
/// picture-in-picture session when Flutter reports a background lifecycle.
abstract final class CinemaPipLifecyclePolicy {
  static bool shouldPauseOnLifecycle(
    AppLifecycleState state, {
    required bool pipRequested,
    required bool pipActive,
  }) {
    if (pipRequested || pipActive) return false;
    return switch (state) {
      AppLifecycleState.inactive ||
      AppLifecycleState.paused ||
      AppLifecycleState.hidden ||
      AppLifecycleState.detached => true,
      AppLifecycleState.resumed => false,
    };
  }

  /// Once native PiP exits or times out, background playback is disallowed.
  /// A missing lifecycle state is treated as not resumed, matching Flutter's
  /// conservative behavior when the app is not fully initialized.
  static bool shouldPauseAfterPipExit(AppLifecycleState? state) =>
      state != AppLifecycleState.resumed;
}
