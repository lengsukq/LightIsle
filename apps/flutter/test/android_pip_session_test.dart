import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/features/media/android_pip_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('nested PiP routes retain the underlying native handler', () async {
    const channel = MethodChannel('lightisle/pip');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (method) async {
      if (method.method == 'supported') return true;
      if (method.method == 'enter') return true;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final states = <String>[];
    final first = AndroidPipSession(
      onChanged: () => states.add('cinema-changed'),
      onTimeout: () => states.add('cinema-timeout'),
      onError: (_) => states.add('cinema-error'),
      onExit: () => states.add('cinema-exit'),
    )..attach();
    addTearDown(first.dispose);
    await Future<void>.delayed(Duration.zero);
    expect(first.supported, true);

    final second = AndroidPipSession(
      onChanged: () => states.add('local-changed'),
      onTimeout: () => states.add('local-timeout'),
      onError: (_) => states.add('local-error'),
      onExit: () => states.add('local-exit'),
    )..attach();
    addTearDown(second.dispose);
    await Future<void>.delayed(Duration.zero);
    expect(second.supported, true);

    const codec = StandardMethodCodec();
    messenger.handlePlatformMessage(
      'lightisle/pip',
      codec.encodeMethodCall(const MethodCall('state', true)),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(second.active, true);
    expect(first.active, false);

    second.dispose();
    messenger.handlePlatformMessage(
      'lightisle/pip',
      codec.encodeMethodCall(const MethodCall('state', true)),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(first.active, true);
    expect(states, isNot(contains('local-error')));
    first.dispose();
  });

  test(
    'PiP rejection resets the pending state without suppressing playback',
    () async {
      const channel = MethodChannel('lightisle/pip');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (method) async {
        if (method.method == 'supported') return true;
        if (method.method == 'enter') return false;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      var failed = false;
      final session = AndroidPipSession(
        onChanged: () {},
        onTimeout: () {},
        onError: (_) => failed = true,
        onExit: () {},
      )..attach();
      addTearDown(session.dispose);
      await Future<void>.delayed(Duration.zero);
      await session.enter();
      expect(failed, isTrue);
      expect(session.allowsBackgroundPlayback, isFalse);
    },
  );
}
