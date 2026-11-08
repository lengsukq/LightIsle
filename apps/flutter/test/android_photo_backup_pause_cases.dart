part of 'android_photo_backup_test.dart';

void _registerPhotoBackupPauseTests({
  required PhotoTestApi Function() currentApi,
  required int Function() preparedCount,
  required Directory Function() tempDir,
  required List<String> releasedPaths,
  required Future<void> Function(WidgetTester, Completer<void>) startUntil,
  required Future<void> Function(WidgetTester) waitForPausedRun,
}) {
  testWidgets(
    'pause during a stale cached-hash probe prevents the next native prepare',
    (tester) async {
      const deviceId = 'cccccccccccccccccccccccc';
      final digest = sha256.convert([10, 20, 30, 40, 50, 60]).toString();
      final versionId = sha256
          .convert('v1'.codeUnits)
          .toString()
          .substring(0, 16);
      SharedPreferences.setMockInitialValues({
        'lightisle.photoBackup.installationId': deviceId,
        'lightisle.photoBackup.http://127.0.0.1.owner.$deviceId.disk_photo:4.Users/u7/photos.sent.234.100.6.3.$versionId':
            digest,
      });
      final probeStarted = Completer<void>();
      final probeReply = Completer<bool>();
      currentApi().remoteHashHandler = (_, _, _) {
        if (!probeStarted.isCompleted) probeStarted.complete();
        return probeReply.future;
      };

      await startUntil(tester, probeStarted);
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await tester.pump();
      await tester.runAsync(() async {
        probeReply.complete(false);
      });
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await waitForPausedRun(tester);

      expect(preparedCount(), 0);
      expect(currentApi().created, 0);
      expect(find.textContaining('已暂停'), findsOneWidget);
    },
  );

  testWidgets(
    'pause during the final SHA probe prevents a new upload session',
    (tester) async {
      final probeStarted = Completer<void>();
      final probeReply = Completer<bool>();
      currentApi().remoteHashHandler = (_, _, _) {
        if (!probeStarted.isCompleted) probeStarted.complete();
        return probeReply.future;
      };

      await startUntil(tester, probeStarted);
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await tester.pump();
      await tester.runAsync(() async {
        probeReply.complete(false);
      });
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await waitForPausedRun(tester);

      expect(preparedCount(), 1);
      expect(currentApi().sizeProbeCalls, 0);
      expect(currentApi().created, 0);
      expect(releasedPaths, ['${tempDir().path}/original.jpg']);
      expect(find.textContaining('已暂停'), findsOneWidget);
    },
  );

  testWidgets(
    'pause while resuming an existing upload session prevents chunk writes',
    (tester) async {
      const deviceId = 'dddddddddddddddddddddddd';
      final digest = sha256.convert([10, 20, 30, 40, 50, 60]).toString();
      SharedPreferences.setMockInitialValues({
        'lightisle.photoBackup.installationId': deviceId,
        'lightisle.photoBackup.http://127.0.0.1.owner.$deviceId.disk_photo:4.Users/u7/photos.upload.234.100.$digest':
            'existing-session',
      });
      final sessionReadStarted = Completer<void>();
      final sessionReadReply = Completer<Map<String, dynamic>>();
      currentApi().uploadStateHandler = (path, _) {
        expect(path, '/api/v2/roots/disk_photo/uploads/existing-session');
        if (!sessionReadStarted.isCompleted) sessionReadStarted.complete();
        return sessionReadReply.future;
      };

      await startUntil(tester, sessionReadStarted);
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await tester.pump();
      await tester.runAsync(() async {
        sessionReadReply.complete({
          'id': 'existing-session',
          'path':
              'Users/u7/photos/$deviceId/photo_234_100_${digest.substring(0, 16)}.jpg',
          'size': 6,
          'offset': 0,
        });
      });
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await waitForPausedRun(tester);

      expect(currentApi().created, 0);
      expect(currentApi().uploadChunkCalls, 0);
      expect(releasedPaths, ['${tempDir().path}/original.jpg']);
      expect(find.textContaining('已暂停'), findsOneWidget);
    },
  );
}

Future<void> _waitForPausedRun(WidgetTester tester) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (find.text('暂停').evaluate().isEmpty &&
        find.textContaining('已暂停').evaluate().isNotEmpty) {
      return;
    }
  }
  fail('foreground backup did not settle into paused state');
}
