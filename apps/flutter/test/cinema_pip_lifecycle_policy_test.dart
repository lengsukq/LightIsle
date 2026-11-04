import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/features/media/cinema_pip_lifecycle_policy.dart';

void main() {
  test('foreground playback never saves or pauses on lifecycle change', () {
    expect(
      CinemaPipLifecyclePolicy.shouldPauseOnLifecycle(
        AppLifecycleState.resumed,
        pipRequested: false,
        pipActive: false,
      ),
      false,
    );
  });

  test('non-PiP playback pauses on every background lifecycle', () {
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.detached,
    ]) {
      expect(
        CinemaPipLifecyclePolicy.shouldPauseOnLifecycle(
          state,
          pipRequested: false,
          pipActive: false,
        ),
        true,
        reason: 'Expected pause on $state',
      );
    }
  });

  test('pending and active native PiP both suppress background pause', () {
    for (final state in AppLifecycleState.values) {
      expect(
        CinemaPipLifecyclePolicy.shouldPauseOnLifecycle(
          state,
          pipRequested: true,
          pipActive: false,
        ),
        false,
      );
      expect(
        CinemaPipLifecyclePolicy.shouldPauseOnLifecycle(
          state,
          pipRequested: false,
          pipActive: true,
        ),
        false,
      );
    }
  });

  test('PiP timeout or exit restores ordinary background policy', () {
    expect(
      CinemaPipLifecyclePolicy.shouldPauseAfterPipExit(
        AppLifecycleState.resumed,
      ),
      false,
    );
    expect(
      CinemaPipLifecyclePolicy.shouldPauseAfterPipExit(
        AppLifecycleState.paused,
      ),
      true,
    );
    expect(CinemaPipLifecyclePolicy.shouldPauseAfterPipExit(null), true);
  });
}
