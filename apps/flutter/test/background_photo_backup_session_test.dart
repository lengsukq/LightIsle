import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/background_photo_backup_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'replacement waits for old cleanup and stale end cannot clear new token',
    () async {
      const channel = MethodChannel('test/lightisle-background-session');
      final events = <String>[];
      String? nativeToken;
      var delayNextEnd = false;
      Completer<void>? endGate;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = (call.arguments as Map).cast<String, dynamic>();
            final token = args['token'] as String;
            switch (call.method) {
              case 'bindSession':
                events.add('bind:${args['username']}');
                expect(nativeToken, isNull);
                nativeToken = token;
                return null;
              case 'endSession':
                events.add('end:$token');
                if (nativeToken == token && delayNextEnd) {
                  delayNextEnd = false;
                  await endGate!.future;
                }
                if (nativeToken == token) nativeToken = null;
                return null;
              default:
                throw PlatformException(code: 'unexpected_method');
            }
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final session = BackgroundPhotoBackupSession(
        channel: channel,
        enabled: true,
      );
      final oldToken = await session.replaceSession(
        server: 'https://nas.example',
        cookie: 'lightisle_session=old-session',
        username: 'alice',
      );
      expect(oldToken, isNotNull);
      expect(events, ['bind:alice']);

      endGate = Completer<void>();
      delayNextEnd = true;
      final oldCleanup = session.end(oldToken!);
      await Future<void>.delayed(Duration.zero);

      var visibleAccount = '';
      final replacement = session
          .replaceSession(
            server: 'https://nas.example',
            cookie: 'lightisle_session=new-session',
            username: 'bob',
          )
          .then((token) {
            visibleAccount = 'bob';
            return token;
          });
      await Future<void>.delayed(Duration.zero);
      expect(visibleAccount, isEmpty);
      expect(events.where((event) => event == 'bind:bob'), isEmpty);

      endGate.complete();
      await oldCleanup;
      final newToken = await replacement;
      expect(newToken, isNotNull);
      expect(events, ['bind:alice', 'end:$oldToken', 'bind:bob']);
      expect(visibleAccount, 'bob');
      expect(nativeToken, newToken);

      await session.end(oldToken);
      expect(session.activeToken, newToken);
      expect(nativeToken, newToken);
    },
  );

  test('cold-start signout fences old native backup before a new binding', () async {
    const channel = MethodChannel('test/lightisle-cold-start-forget');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final forgetGate = Completer<void>();
    final events = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'forgetSession') {
        events.add('forget');
        await forgetGate.future;
        return null;
      }
      if (call.method == 'bindSession') {
        events.add('bind');
        return null;
      }
      throw PlatformException(code: 'unexpected_method');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final session = BackgroundPhotoBackupSession(
      channel: channel,
      enabled: true,
    );
    // No previous in-memory token exists, although Android may have kept a
    // WorkManager authorization from the preceding application process.
    expect(session.activeToken, isNull);
    final clear = session.forgetLocalSession();
    await Future<void>.delayed(Duration.zero);
    final newBinding = session.replaceSession(
      server: 'https://nas.example',
      cookie: 'lightisle_session=new-session',
      username: 'new-owner',
    );
    await Future<void>.delayed(Duration.zero);
    expect(events, ['forget']);
    forgetGate.complete();
    await clear;
    expect(await newBinding, isNotNull);
    expect(events, ['forget', 'bind']);
  });
}
