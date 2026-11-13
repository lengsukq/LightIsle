part of 'android_photo_backup_test.dart';

void _registerPhotoBackupRecoveryTests() {
  testWidgets(
    'failure registry is capped at 512 and preserves the omitted failure count',
    (tester) async {
      final rows = List<Map<String, dynamic>>.generate(
        513,
        (index) => {
          'id': '${1000 + index}',
          'name': 'unavailable-$index.jpg',
          'modified': 1,
          'size': 6,
          'generation': 0,
        },
      );
      listHandler = (_) async => {
        'items': rows,
        'nextCursor': '',
        'version': storeVersion,
      };
      prepareHandler = (_) async =>
          throw PlatformException(code: 'photo_prepare_failed');

      await open(tester);
      await tester.runAsync(() async {
        await tester.tap(find.text('检查并备份最近照片'));
        await Future<void>.delayed(const Duration(seconds: 3));
      });
      await tester.pumpAndSettle();

      expect(prepared, 513);
      expect(find.textContaining('513 项原片尚未备份'), findsOneWidget);
      expect(find.textContaining('其中 1 项超过本机 512 条失败记录上限'), findsOneWidget);
      final preferences = await SharedPreferences.getInstance();
      final storageKey = preferences.getKeys().singleWhere(
        (key) => key.endsWith('.failures.photos'),
      );
      final encoded = preferences.getString(storageKey)!;
      expect((jsonDecode(encoded) as List).length, 512);
      expect(preferences.getInt('$storageKey.omitted'), 1);
      expect(
        preferences.getKeys().where((key) => key.endsWith('.lastCompleteAt')),
        isEmpty,
      );
    },
  );

  testWidgets(
    'a native permission revocation stops the page without advancing its cursor',
    (tester) async {
      listHandler = (arguments) async => {
        'items': [
          {
            'id': '234',
            'name': 'first.jpg',
            'modified': 100,
            'size': 6,
            'generation': 0,
          },
          {
            'id': '235',
            'name': 'second.jpg',
            'modified': 101,
            'size': 6,
            'generation': 0,
          },
        ],
        'nextCursor': '120',
        'version': storeVersion,
      };
      prepareHandler = (_) async =>
          throw PlatformException(code: 'photo_permission_required');

      await open(tester);
      await start(tester);

      expect(listed, 1);
      expect(prepared, 1);
      expect(api.created, 0);
      expect(find.textContaining('备份中断'), findsOneWidget);
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getKeys().where((key) => key.endsWith('.cursor')),
        isEmpty,
      );
      expect(
        preferences.getKeys().where((key) => key.endsWith('.lastCompleteAt')),
        isEmpty,
      );
    },
  );

  testWidgets(
    'lost complete response resumes from durable NAS file without reuploading',
    (tester) async {
      api.loseCompletionOnce = true;
      await open(tester);
      await start(tester);
      expect(api.created, 1);
      expect(find.textContaining('备份中断'), findsOneWidget);
      await start(tester);
      expect(api.created, 1);
      expect(find.textContaining('跳过 1 张'), findsOneWidget);
      expect(prepared, 2);
    },
  );

  testWidgets(
    'older Android without generation rehashes original before skip',
    (tester) async {
      generation = 0;
      await open(tester);
      await start(tester);
      expect(api.created, 1);
      await start(tester);
      expect(api.created, 1);
      expect(
        prepared,
        2,
        reason: 'without generation token a same-size/mmtime replacement must be rehashed',
      );
    },
  );

  testWidgets(
    'consumes more than one native page without extra manual tapping',
    (tester) async {
      nextPages = true;
      await open(tester);
      await start(tester);
      expect(listed, 2);
      expect(find.textContaining('已检查至相册末尾'), findsOneWidget);
      expect(api.created, 0);
    },
  );

  testWidgets(
    'refuses partial/no Android photo access before reading or sending',
    (tester) async {
      granted = false;
      await open(tester);
      await start(tester);
      expect(listed, 0);
      expect(api.created, 0);
      expect(find.textContaining('需要在 Android 系统设置中授权访问所有照片'), findsOneWidget);
    },
  );

  _registerPhotoBackupPauseTests(
    currentApi: () => api,
    preparedCount: () => prepared,
    tempDir: () => temporary,
    releasedPaths: releasedPaths,
    startUntil: startUntil,
    waitForPausedRun: _waitForPausedRun,
  );

  testWidgets(
    'background backup can be enabled after manually pausing the foreground run',
    (tester) async {
      final prepareStarted = Completer<void>();
      final prepareReply = Completer<Map<String, dynamic>?>();
      prepareHandler = (_) {
        if (!prepareStarted.isCompleted) prepareStarted.complete();
        return prepareReply.future;
      };

      await startUntil(tester, prepareStarted);
      await tester.tap(find.text('暂停'));
      await tester.pump();
      prepareReply.complete({
        'path': '${temporary.path}/original.jpg',
        'size': 6,
      });
      await _waitForPausedRun(tester);

      expect(releasedPaths, ['${temporary.path}/original.jpg']);
      expect(api.created, 0);
      expect(find.textContaining('已暂停'), findsOneWidget);

      await tester.tap(find.text('系统后台自动备份（每 6 小时检查）'));
      await tester.pumpAndSettle();
      expect(find.text('开启系统后台照片备份？'), findsOneWidget);
      await tester.tap(find.text('同意并开启'));
      await tester.pumpAndSettle();

      expect(backgroundConfigured, 1);
      expect(backgroundEnabled, isTrue);
    },
  );

  testWidgets(
    'pausing during native prepare cancels by request id and releases a late temp file',
    (tester) async {
      final prepareStarted = Completer<void>();
      final prepareReply = Completer<Map<String, dynamic>?>();
      prepareHandler = (_) {
        if (!prepareStarted.isCompleted) prepareStarted.complete();
        return prepareReply.future;
      };
      await open(tester);
      await tester.runAsync(() async {
        await tester.tap(find.text('检查并备份最近照片'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      expect(prepareStarted.isCompleted, isTrue);

      final requestId = prepareArguments.single['requestId'] as String;
      expect(requestId, isNotEmpty);
      await tester.tap(find.text('暂停'));
      await tester.pump();
      expect(cancelledRequestIds, [requestId]);
      expect(find.textContaining('等待当前系统或网络请求结束'), findsOneWidget);

      // Model the native copy finishing just as cancellation arrives. The page
      // must discard this result before hashing/uploading, then release its file.
      prepareReply.complete({
        'path': '${temporary.path}/original.jpg',
        'size': 6,
      });
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();

      expect(api.created, 0);
      expect(releasedPaths, ['${temporary.path}/original.jpg']);
      expect(find.textContaining('已暂停'), findsOneWidget);
    },
  );

  testWidgets(
    'resume during cancellation queues a new foreground pass after cleanup',
    (tester) async {
      const deviceId = 'aaaaaaaaaaaaaaaaaaaaaaaa';
      SharedPreferences.setMockInitialValues({
        'lightisle.photoBackup.installationId': deviceId,
        'lightisle.photoBackup.http://127.0.0.1.owner.$deviceId.disk_photo:4.Users/u7/photos.onForeground':
            true,
      });
      final firstPrepareStarted = Completer<void>();
      final secondPrepareStarted = Completer<void>();
      final secondPrepareReply = Completer<Map<String, dynamic>?>();
      final prepareReply = Completer<Map<String, dynamic>?>();
      final releaseStarted = Completer<void>();
      final releaseGate = Completer<void>();
      prepareHandler = (_) {
        if (prepareArguments.length == 1) {
          firstPrepareStarted.complete();
          return prepareReply.future;
        }
        if (prepareArguments.length == 2) {
          secondPrepareStarted.complete();
          return secondPrepareReply.future;
        }
        throw StateError('Unexpected third prepare');
      };
      releaseHandler = (_) async {
        if (!releaseStarted.isCompleted) releaseStarted.complete();
        await releaseGate.future;
      };

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: MobilePhotoBackupPage(
            api: api,
            accountName: 'owner',
            baseDirectory: 'Users/u7/photos',
            androidPlatformOverride: true,
          ),
        ),
      );
      await tester.runAsync(
        () => firstPrepareStarted.future.timeout(const Duration(seconds: 3)),
      );

      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await tester.pump();
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pump();
      expect(cancelledRequestIds, [prepareArguments.first['requestId']]);

      prepareReply.complete({
        'path': '${temporary.path}/original.jpg',
        'size': 6,
      });
      await tester.runAsync(
        () => releaseStarted.future.timeout(const Duration(seconds: 3)),
      );
      expect(
        prepareArguments,
        hasLength(1),
        reason: 'the next pass waits for old temp cleanup',
      );

      releaseGate.complete();
      await tester.runAsync(
        () => secondPrepareStarted.future.timeout(const Duration(seconds: 3)),
      );
      expect(
        prepareArguments,
        hasLength(2),
        reason: 'a rapid resume must not be lost while cancellation unwinds',
      );
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await tester.pump();
      expect(cancelledRequestIds, [
        prepareArguments[0]['requestId'],
        prepareArguments[1]['requestId'],
      ]);
      secondPrepareReply.complete({
        'path': '${temporary.path}/original.jpg',
        'size': 6,
      });
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(releasedPaths, hasLength(2));
      expect(api.created, 0);
    },
  );

  testWidgets('manual pause after a rapid resume clears the queued rerun', (
    tester,
  ) async {
    const deviceId = 'bbbbbbbbbbbbbbbbbbbbbbbb';
    SharedPreferences.setMockInitialValues({
      'lightisle.photoBackup.installationId': deviceId,
      'lightisle.photoBackup.http://127.0.0.1.owner.$deviceId.disk_photo:4.Users/u7/photos.onForeground':
          true,
    });
    final prepareStarted = Completer<void>();
    final prepareReply = Completer<Map<String, dynamic>?>();
    final releaseFinished = Completer<void>();
    prepareHandler = (_) {
      if (!prepareStarted.isCompleted) prepareStarted.complete();
      return prepareReply.future;
    };
    releaseHandler = (_) async {
      if (!releaseFinished.isCompleted) releaseFinished.complete();
    };

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: MobilePhotoBackupPage(
          api: api,
          accountName: 'owner',
          baseDirectory: 'Users/u7/photos',
          androidPlatformOverride: true,
        ),
      ),
    );
    await tester.runAsync(
      () => prepareStarted.future.timeout(const Duration(seconds: 3)),
    );
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.paused,
    );
    await tester.pump();
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    await tester.pump();
    expect(cancelledRequestIds, [prepareArguments.single['requestId']]);

    await tester.tap(find.text('暂停'));
    await tester.pump();
    prepareReply.complete({
      'path': '${temporary.path}/original.jpg',
      'size': 6,
    });
    await tester.runAsync(
      () => releaseFinished.future.timeout(const Duration(seconds: 3)),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();

    expect(prepareArguments, hasLength(1));
    expect(api.created, 0);
  });

  testWidgets(
    'disposing the page cancels an active native prepare and releases its late result',
    (tester) async {
      final prepareStarted = Completer<void>();
      final prepareReply = Completer<Map<String, dynamic>?>();
      prepareHandler = (_) {
        if (!prepareStarted.isCompleted) prepareStarted.complete();
        return prepareReply.future;
      };
      await open(tester);
      await tester.runAsync(() async {
        await tester.tap(find.text('检查并备份最近照片'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      expect(prepareStarted.isCompleted, isTrue);
      final requestId = prepareArguments.single['requestId'] as String;

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(cancelledRequestIds, [requestId]);
      prepareReply.complete({
        'path': '${temporary.path}/original.jpg',
        'size': 6,
      });
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );

      expect(api.created, 0);
      expect(releasedPaths, ['${temporary.path}/original.jpg']);
    },
  );
}
