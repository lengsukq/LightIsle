part of 'files_test.dart';

void _registerFilesPreviewExportTests() {
  testWidgets('files layout fits narrow, tablet, wide, and 200% text sizes', (
    tester,
  ) async {
    final api = _FilesTestApi(writable: true);
    addTearDown(api.close);
    const viewports = [
      (width: 320.0, scale: 1.0, select: true),
      (width: 600.0, scale: 1.0, select: false),
      (width: 1280.0, scale: 1.0, select: false),
      (width: 320.0, scale: 2.0, select: true),
    ];
    var hasSelected = false;

    for (final viewport in viewports) {
      tester.view.physicalSize = Size(viewport.width, 900);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(
                size: Size(viewport.width, 900),
                textScaler: TextScaler.linear(viewport.scale),
              ),
              child: FilesPage(api: api, isAdmin: false),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // At 200% text the responsive toolbar is taller than the initial
      // viewport. A lazily-built ListView child is not mounted until the
      // user scrolls to it; ensure the file list is actually reachable.
      if (find.text('计划说明.txt').evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          find.text('计划说明.txt'),
          160,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 20,
        );
        await tester.pumpAndSettle();
      }
      expect(
        find.text('计划说明.txt'),
        findsOneWidget,
        reason: 'width=${viewport.width} scale=${viewport.scale}',
      );
      if (viewport.select && !hasSelected) {
        await tester.ensureVisible(find.text('资料夹'));
        await tester.longPress(find.text('资料夹'));
        await tester.pumpAndSettle();
        hasSelected = true;
      }
      if (viewport.select) {
        expect(find.text('批量移到回收站'), findsOneWidget);
      }
      expect(
        tester.takeException(),
        isNull,
        reason: '${viewport.width}px at ${viewport.scale}x text',
      );
    }
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  });

  testWidgets('mobile export streams to temporary storage and cleans it up', (
    tester,
  ) async {
    final tempRoot = Directory.systemTemp.createTempSync(
      'lightisle-files-test-',
    );
    final exportDirectory = Directory('${tempRoot.path}/export')..createSync();
    final api = _DownloadTestApi();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    const exportChannel = MethodChannel('lightisle/export');
    addTearDown(api.close);
    addTearDown(() {
      messenger.setMockMethodCallHandler(pathProviderChannel, null);
      messenger.setMockMethodCallHandler(exportChannel, null);
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });
    messenger.setMockMethodCallHandler(pathProviderChannel, (call) async {
      expect(call.method, 'getTemporaryDirectory');
      return tempRoot.path;
    });

    String? exportedPath;
    messenger.setMockMethodCallHandler(exportChannel, (call) async {
      expect(call.method, 'exportFile');
      final arguments = Map<String, Object?>.from(call.arguments as Map);
      exportedPath = arguments['path'] as String;
      expect(arguments['name'], '说明.txt');
      expect(File(exportedPath!).readAsStringSync(), 'test bytes');
      return 'content://downloads/document/1';
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: FilesPage(
            api: api,
            isAdmin: false,
            mobileExportOverride: true,
            exportDirectoryFactory: (_) async => exportDirectory,
            exportDirectoryCleanup: (directory) async {
              directory.deleteSync(recursive: true);
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('说明.txt'), findsOneWidget);

    await tester.tap(find.byTooltip('文件操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('已保存到所选位置：content://downloads/document/1'),
      findsOneWidget,
    );
    expect(exportedPath, isNotNull);
    expect(File(exportedPath!).existsSync(), isFalse);
    expect(tempRoot.listSync(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('folder download uses the archive endpoint and exports a ZIP', (
    tester,
  ) async {
    final tempRoot = Directory.systemTemp.createTempSync(
      'lightisle-archive-test-',
    );
    final exportDirectory = Directory('${tempRoot.path}/export')..createSync();
    final api = _FilesParityTestApi();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    const exportChannel = MethodChannel('lightisle/export');
    addTearDown(api.close);
    addTearDown(() {
      messenger.setMockMethodCallHandler(pathProviderChannel, null);
      messenger.setMockMethodCallHandler(exportChannel, null);
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });
    messenger.setMockMethodCallHandler(pathProviderChannel, (call) async {
      return tempRoot.path;
    });
    String? exportedName;
    messenger.setMockMethodCallHandler(exportChannel, (call) async {
      final arguments = Map<String, Object?>.from(call.arguments as Map);
      exportedName = arguments['name'] as String;
      expect(File(arguments['path'] as String).readAsStringSync(), 'zip bytes');
      return 'saved.zip';
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: FilesPage(
            api: api,
            isAdmin: false,
            mobileExportOverride: true,
            exportDirectoryFactory: (_) async => exportDirectory,
            exportDirectoryCleanup: (directory) async {
              directory.deleteSync(recursive: true);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('文件操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载文件夹 ZIP'));
    await tester.pumpAndSettle();

    expect(api.downloads.single.path, '/api/v2/files/archive');
    expect(api.downloads.single.queryParameters, {'path': '资料夹'});
    expect(exportedName, '资料夹.zip');
    expect(find.textContaining('已保存到所选位置：saved.zip'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'file share creates a one-time public link with selected expiry',
    (tester) async {
      final api = _FilesParityTestApi();
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(body: FilesPage(api: api, isAdmin: false)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('文件操作').at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('分享文件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成分享链接'));
      await tester.pumpAndSettle();

      final request = api.sent.single;
      expect(request.method, 'POST');
      expect(request.path, '/api/v2/file-shares');
      expect(request.body, {'path': '说明.txt', 'hours': 24});
      final linkField = tester.widget<TextField>(find.byType(TextField).last);
      expect(
        linkField.controller!.text,
        'http://127.0.0.1:1/api/v2/public/file/demo-token',
      );
      expect(find.text('复制分享链接'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('my shares page lists and revokes the current user link', (
    tester,
  ) async {
    final api = _FilesParityTestApi(withShare: true);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: FileSharesPage(api: api),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Docs/说明.txt'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, '撤销链接'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '撤销链接'));
    await tester.pumpAndSettle();

    expect(api.sent.single.method, 'DELETE');
    expect(api.sent.single.path, '/api/v2/file-shares/share-id');
    expect(find.text('当前没有有效的分享链接。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('video preview asks the API for its authenticated media URI', (
    tester,
  ) async {
    final api = _FilesParityTestApi(withVideo: true);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(body: FilesPage(api: api, isAdmin: false)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('clip.mp4'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('clip.mp4'));
    await tester.pumpAndSettle();

    expect(api.mediaRequests, hasLength(1));
    expect(api.mediaRequests.single.path, '/api/v2/files/preview');
    expect(api.mediaRequests.single.queryParameters, {'path': 'clip.mp4'});
    expect(find.byType(PhotoGalleryViewer), findsOneWidget);
    expect(find.byTooltip('返回文件'), findsOneWidget);
    expect(find.byTooltip('播放列表'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'files reuse the Photos viewer for images and videos on a narrow phone',
    (tester) async {
      final api = _FilesParityTestApi(withVideo: true, withImage: true);
      addTearDown(api.close);
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: FilesPage(api: api, isAdmin: false),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('photo.jpg'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('photo.jpg'));
      await tester.pumpAndSettle();
      final gallery = tester.widget<PhotoGalleryViewer>(
        find.byType(PhotoGalleryViewer),
      );
      expect(gallery.fileBrowserMode, isTrue);
      expect(
        gallery.assets.map((asset) => asset.name),
        containsAll(['photo.jpg', 'clip.mp4']),
      );
      expect(find.byTooltip('返回文件'), findsOneWidget);
      expect(find.byTooltip('加入我的收藏'), findsNothing);
      expect(find.byTooltip('照片信息与相册管理'), findsNothing);
      expect(find.byTooltip('播放列表'), findsOneWidget);
      await tester.tap(find.byTooltip('播放列表'));
      await tester.pumpAndSettle();
      expect(find.text('photo.jpg'), findsWidgets);
      expect(find.text('clip.mp4'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('text preview drops a response from a different physical disk', (
    tester,
  ) async {
    final api = _DelayedTextPreviewApi();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FilesPage(api: api, isAdmin: false)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('计划说明.txt').last);
    await tester.pump();
    expect(api.previewCalls, 1);
    api.selectRoot(
      const LightIsleRoot(
        id: 'new-disk',
        name: '新硬盘',
        generation: 3,
        online: true,
      ),
    );
    api.completePreview();
    await tester.pumpAndSettle();
    expect(find.byType(FileTextPreviewDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
