part of 'media_pages_test.dart';

void _registerMediaDetailTests() {
  testWidgets('cinema metadata search is explicit and matching is confirmed', (
    tester,
  ) async {
    final api = _MediaApi()
      ..cinemaDetail = <String, dynamic>{
        'id': 201,
        'title': 'Manual title',
        'path': 'Cinema/manual.mp4',
        'kind': 'movie',
        'playable': false,
        'browserPlayback': 'download-only',
        'probeStatus': 'unsupported',
      }
      ..tmdbResults.add(<String, dynamic>{
        'id': 908,
        'kind': 'movie',
        'title': 'Suggested film',
        'year': '2025',
        'overview': 'A manually selected result.',
        'rating': 8.1,
        'posterURL': 'https://image.tmdb.org/t/p/w342/sample.jpg',
      });
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.light),
        home: Scaffold(
          body: CinemaDetailDialog(
            api: api,
            film: CinemaFilm.fromJson(api.cinemaDetail!),
            isAdmin: true,
            onRename: (film) async => film,
            onProgressUpdated: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.sendRequests, isEmpty);
    expect(find.textContaining('不会自动联网查询'), findsOneWidget);
    expect(
      find.textContaining('not endorsed or certified by TMDB'),
      findsOneWidget,
    );

    final importNfo = find.widgetWithText(OutlinedButton, '导入本地 NFO 资料');
    await tester.ensureVisible(importNfo);
    await tester.tap(importNfo);
    await tester.pumpAndSettle();
    expect(api.sendRequests.single['path'], '/api/v2/cinema/201/metadata/nfo');
    expect(find.text('Imported from local sidecar.'), findsOneWidget);
    expect(find.text('资料来源：本地 NFO'), findsOneWidget);

    final fields = find.byType(TextField);
    await tester.ensureVisible(fields.at(0));
    await tester.enterText(fields.at(0), 'user-provided-token');
    await tester.enterText(fields.at(1), 'Suggested film');
    final searchButton = find.widgetWithText(FilledButton, '搜索 TMDB');
    await tester.ensureVisible(searchButton);
    await tester.tap(searchButton);
    await tester.pumpAndSettle();

    expect(api.sendRequests, hasLength(2));
    expect(
      api.sendRequests.last['path'],
      '/api/v2/cinema/201/metadata/tmdb/search',
    );
    expect(api.sendRequests.last['body'], <String, String>{
      'accessToken': 'user-provided-token',
      'query': 'Suggested film',
    });
    expect(find.text('Suggested film (2025)'), findsOneWidget);
    expect(find.text('A manually selected result.'), findsOneWidget);

    final chooseMatch = find.text('选择匹配');
    await tester.ensureVisible(chooseMatch);
    await tester.tap(chooseMatch);
    await tester.pumpAndSettle();
    expect(find.text('确认匹配影视资料？'), findsOneWidget);
    await tester.tap(find.text('确认匹配'));
    await tester.pumpAndSettle();
    expect(
      api.sendRequests.last['path'],
      '/api/v2/cinema/201/metadata/tmdb/match',
    );
    expect(api.sendRequests.last['body'], <String, Object>{
      'accessToken': 'user-provided-token',
      'tmdbId': 908,
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cinema discards a page response from the previous filter', (
    tester,
  ) async {
    final api = _MediaApi();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CinemaPage(api: api, isAdmin: false)),
      ),
    );
    await tester.pump();

    tester
        .widget<PopupMenuButton<String>>(find.byType(PopupMenuButton<String>))
        .onSelected!('movie');
    // The first page request is intentionally in flight; wait for the new
    // filter state, not for the still-spinning old request to settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.cinemaQueries.last['kind'], 'movie');
    expect(find.text('影视库还没有影片'), findsOneWidget);

    api.firstCinema.complete(<String, dynamic>{
      'films': <Object>[
        <String, Object>{
          'id': 52,
          'title': 'Stale film',
          'kind': 'movie',
          'playable': false,
          'browserPlayback': 'download-only',
        },
      ],
      'nextCursor': 0,
    });
    await tester.pumpAndSettle();

    expect(find.text('影视库还没有影片'), findsOneWidget);
    expect(find.text('Stale film'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cinema title opens the film from the whole card surface', (
    tester,
  ) async {
    final api = _MediaApi();
    final platform = _videoPlayerTestPlatform;
    platform.calls.clear();
    VideoPlayerPlatform.instance = platform;
    api.firstCinema.complete(<String, dynamic>{
      'films': <Object>[
        <String, Object>{
          'id': 62,
          'title': 'Card title opens the film',
          'path': 'Cinema/card-title.mp4',
          'kind': 'movie',
          'playable': true,
          'browserPlayback': 'verified-direct',
          'probeStatus': 'ready',
        },
      ],
      'nextCursor': 0,
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      api.close();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CinemaPage(api: api, isAdmin: false)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(api.mediaByteRequests, hasLength(1));
    expect(api.mediaByteRequests.single['path'], '/api/v2/cinema/62/poster');
    expect(api.mediaByteRequests.single['maxBytes'], 4 * 1024 * 1024);
    await tester.pump(const Duration(milliseconds: 20));
    final title = find.text('Card title opens the film').first;
    await tester.tap(title);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();

    // Clicking a film card directly enters the player route without an intermediate overview.
    expect(find.byKey(const ValueKey('cinemaPlayerPage')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('cinemaPlayerDetailsToggle')),
      findsOneWidget,
    );
    expect(find.byTooltip('关闭'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cinemaPlayerPage')), findsNothing);
    expect(find.text('Card title opens the film'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('gallery thumbnails use bounded API bytes and can be retried', (
    tester,
  ) async {
    final api = _MediaApi()..failMediaBytes = true;
    addTearDown(api.close);
    api.firstPhotos.complete(<String, dynamic>{
      'assets': <Object>[
        <String, Object>{
          'id': 73,
          'path': 'Photos/retry.jpg',
          'name': 'retry.jpg',
          'type': 'photo',
          'size': 1024,
          'takenAt': 1,
          'favorite': false,
          'canWrite': true,
        },
      ],
      'nextCursor': 0,
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PhotosPage(api: api, isAdmin: false)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(api.mediaByteRequests, hasLength(1));
    expect(api.mediaByteRequests.single['path'], '/api/v2/photos/73/thumbnail');
    expect(api.mediaByteRequests.single['maxBytes'], 4 * 1024 * 1024);
    expect(find.byTooltip('重试缩略图'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'retry\.jpg')), findsOneWidget);

    api.failMediaBytes = false;
    await tester.tap(
      find.ancestor(
        of: find.byTooltip('重试缩略图'),
        matching: find.byType(IconButton),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(api.mediaByteRequests, hasLength(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('populated media grids fit phone, tablet, and desktop widths', (
    tester,
  ) async {
    final api = _MediaApi();
    final viewport = ValueNotifier<Size>(const Size(320, 560));
    tester.view.physicalSize = const Size(320, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      viewport.dispose();
      api.close();
    });
    api.firstCinema.complete(<String, dynamic>{
      'films': <Object>[
        <String, Object>{
          'id': 21,
          'title': 'A film title that wraps at large text sizes',
          'path': 'Cinema/film.mp4',
          'kind': 'movie',
          'year': 2026,
          'playable': true,
          'browserPlayback': 'verified-direct',
          'probeStatus': 'pending',
          'container': 'mp4',
          'videoCodec': 'h264',
          'audioCodec': 'aac',
          'position': 120,
          'duration': 3600,
        },
      ],
      'nextCursor': 0,
    });
    api.firstPhotos.complete(<String, dynamic>{
      'assets': <Object>[
        for (var id = 1; id <= 6; id++)
          <String, Object>{
            'id': id,
            'path': 'Photos/photo-$id.jpg',
            'name': 'photo-$id.jpg',
            'type': 'photo',
            'size': 1024,
            'takenAt': 1_760_000_000 + id,
            'favorite': false,
            'canWrite': true,
            'width': 1600,
            'height': 1200,
          },
      ],
      'nextCursor': 0,
    });

    Widget responsivePage(Widget page) => MaterialApp(
      theme: buildIsleTheme(Brightness.light),
      home: Scaffold(
        body: ValueListenableBuilder<Size>(
          valueListenable: viewport,
          child: page,
          builder: (context, size, child) => MediaQuery(
            data: MediaQueryData(size: size, textScaler: TextScaler.linear(2)),
            child: child!,
          ),
        ),
      ),
    );

    await tester.pumpWidget(
      responsivePage(CinemaPage(api: api, isAdmin: false)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(
      find.text('A film title that wraps at large text sizes'),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);

    for (final size in const [Size(600, 800), Size(1280, 900)]) {
      tester.view.physicalSize = size;
      viewport.value = size;
      await tester.pump();
      expect(
        find.text('A film title that wraps at large text sizes'),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    }

    await tester.pumpWidget(
      responsivePage(PhotosPage(api: api, isAdmin: false)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.byType(SliverGrid), findsOneWidget);
    // Page branding is also an Image on wide layouts; count media tiles,
    // not all Image widgets including the shared LightIsle mark.
    expect(find.byType(AuthenticatedMediaImage), findsNWidgets(6));
    expect(tester.takeException(), isNull);
    for (final size in const [Size(600, 800), Size(1280, 900)]) {
      tester.view.physicalSize = size;
      viewport.value = size;
      await tester.pump();
      expect(find.byType(SliverGrid), findsOneWidget);
      expect(find.byType(AuthenticatedMediaImage), findsNWidgets(6));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('gallery video preview pauses when the app is hidden', (
    tester,
  ) async {
    final api = _MediaApi();
    final platform = _videoPlayerTestPlatform;
    platform.calls.clear();
    VideoPlayerPlatform.instance = platform;

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PhotoDetailDialog(
              api: api,
              asset: PhotoAsset.fromJson(<String, dynamic>{
                'id': 7,
                'path': 'Videos/clip.mp4',
                'name': 'clip.mp4',
                'type': 'video',
                'size': 1024,
                'canWrite': false,
              }),
              albums: const [],
              isAdmin: false,
              currentAlbumId: 0,
              canToggleFavorite: false,
              onToggleFavorite: (asset) async => asset,
              onAddToAlbum: (_, _) async {},
              onRemoveFromAlbum: (_, _) async {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();

      expect(find.byType(PhotoMediaVideo), findsOneWidget);
      expect(find.byType(VideoPlayer), findsOneWidget);
      await tester.tap(find.byTooltip('播放视频'));
      await tester.pump();
      expect(platform.calls, contains('play'));

      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.hidden,
      );
      await tester.pump();
      expect(platform.calls, contains('pause'));
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      api.close();
    }
  });

  testWidgets('media details remain scrollable at 320px and 200% text', (
    tester,
  ) async {
    final api = _MediaApi();
    final platform = _videoPlayerTestPlatform;
    platform.calls.clear();
    VideoPlayerPlatform.instance = platform;
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      api.close();
    });
    final mediaQuery = MediaQueryData(
      size: const Size(320, 480),
      textScaler: TextScaler.linear(2),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.light),
        home: Scaffold(
          body: MediaQuery(
            data: mediaQuery,
            child: PhotoDetailDialog(
              api: api,
              asset: PhotoAsset.fromJson(<String, dynamic>{
                'id': 9,
                'path': 'Photos/memory.jpg',
                'name': 'A memorable photograph with a long filename.jpg',
                'type': 'photo',
                'size': 12 * 1024 * 1024,
                'takenAt': 1_760_000_000,
                'width': 4000,
                'height': 3000,
                'canWrite': true,
              }),
              albums: const [],
              isAdmin: false,
              currentAlbumId: 0,
              canToggleFavorite: true,
              onToggleFavorite: (asset) async => asset,
              onAddToAlbum: (_, _) async {},
              onRemoveFromAlbum: (_, _) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(tester.takeException(), isNull);
    final photoClose = find.byTooltip('关闭');
    final photoHeaderTop = tester.getTopLeft(photoClose).dy;
    await tester.drag(
      find.byType(SingleChildScrollView).last,
      const Offset(0, -360),
    );
    await tester.pumpAndSettle();
    expect(photoClose.hitTestable(), findsOneWidget);
    expect(tester.getTopLeft(photoClose).dy, closeTo(photoHeaderTop, 1));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.light),
        home: Scaffold(
          body: MediaQuery(
            data: mediaQuery,
            child: CinemaDetailDialog(
              api: api,
              film: CinemaFilm.fromJson(<String, dynamic>{
                'id': 8,
                'title': 'A feature length film with a long title',
                'path': 'Cinema/feature.mp4',
                'kind': 'movie',
                'year': 2026,
                'playable': true,
                'browserPlayback': 'verified-direct',
                'probeStatus': 'ready',
                'container': 'mp4',
                'videoCodec': 'h264',
                'audioCodec': 'aac',
                'duration': 7200,
              }),
              isAdmin: false,
              onRename: (film) async => film,
              onProgressUpdated: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    expect(
      find.text('A feature length film with a long title'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    final cinemaClose = find.byTooltip('关闭');
    final cinemaHeaderTop = tester.getTopLeft(cinemaClose).dy;
    await tester.drag(
      find.byType(SingleChildScrollView).last,
      const Offset(0, -420),
    );
    await tester.pumpAndSettle();
    expect(cinemaClose.hitTestable(), findsOneWidget);
    expect(tester.getTopLeft(cinemaClose).dy, closeTo(cinemaHeaderTop, 1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'cinema bounds wide and portrait video without clipping controls',
    (tester) async {
      final api = _MediaApi();
      final platform = _videoPlayerTestPlatform;
      VideoPlayerPlatform.instance = platform;
      tester.view.devicePixelRatio = 1;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        platform.videoSize = const Size(640, 360);
        api.close();
      });

      Widget detailAt(Size size, {bool largeText = false}) => MaterialApp(
        theme: buildIsleTheme(Brightness.light).copyWith(
          dialogTheme: const DialogThemeData(
            constraints: BoxConstraints(minWidth: 280, maxWidth: 1000),
          ),
        ),
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(largeText ? 2 : 1),
            ),
            child: CinemaDetailDialog(
              api: api,
              film: CinemaFilm.fromJson(<String, dynamic>{
                'id': 8,
                'title': 'A wide video with visible controls',
                'path': 'Cinema/wide.mp4',
                'kind': 'movie',
                'playable': true,
                'browserPlayback': 'verified-direct',
                'probeStatus': 'ready',
              }),
              isAdmin: false,
              onRename: (film) async => film,
              onProgressUpdated: (_) {},
            ),
          ),
        ),
      );

      tester.view.physicalSize = const Size(1200, 900);
      platform.videoSize = const Size(96, 64);
      await tester.pumpWidget(detailAt(const Size(1200, 900)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();

      var videoSize = tester.getSize(find.byType(VideoPlayer));
      expect(videoSize.width / videoSize.height, closeTo(1.5, .02));
      expect(videoSize.height, lessThanOrEqualTo(400.5));
      expect(
        tester.widget<Text>(find.text('00:00')).style?.color,
        Colors.white,
      );
      final playButton = find.widgetWithIcon(IconButton, Icons.play_arrow);
      expect(tester.widget<IconButton>(playButton).color, Colors.white);
      // 清晰度 and 字幕 are both string dropdowns now; the subtitle one comes
      // first in the controls row.
      final dropdowns = tester
          .widgetList<DropdownButton<String>>(
            find.byType(DropdownButton<String>),
          )
          .toList();
      expect(dropdowns.length, greaterThanOrEqualTo(2));
      final subtitles = dropdowns.first;
      expect(subtitles.style?.color, Colors.white);
      expect(subtitles.dropdownColor, const Color(0xFF202124));
      for (final item in subtitles.items!) {
        final label = (item.child as Text);
        expect(label.style?.color, Colors.white);
      }
      final quality = dropdowns[1];
      expect(
        quality.items!.map((item) => (item.child as Text).data),
        containsAll(<String?>['原画', '720P', '480P']),
      );
      expect(formatMediaSeconds(2), '2 秒');
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      tester.view.physicalSize = const Size(320, 480);
      platform.videoSize = const Size(180, 360);
      await tester.pumpWidget(detailAt(const Size(320, 480), largeText: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();

      videoSize = tester.getSize(find.byType(VideoPlayer));
      expect(videoSize.width / videoSize.height, closeTo(.5, .02));
      expect(videoSize.height, lessThanOrEqualTo(400.5));
      final seekBar = find.byType(VideoProgressIndicator);
      await tester.ensureVisible(seekBar);
      await tester.pumpAndSettle();
      expect(seekBar.hitTestable(), findsOneWidget);
      expect(find.byTooltip('关闭').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cinema shows and clears a failed progress-save notice', (
    tester,
  ) async {
    final api = _MediaApi()..failProgressSaves = true;
    final platform = _videoPlayerTestPlatform;
    platform.calls.clear();
    VideoPlayerPlatform.instance = platform;

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CinemaDetailDialog(
              api: api,
              film: CinemaFilm.fromJson(<String, dynamic>{
                'id': 8,
                'title': 'A short film',
                'path': 'Cinema/short.mp4',
                'kind': 'movie',
                'playable': true,
                'browserPlayback': 'verified-direct',
                'probeStatus': 'ready',
              }),
              isAdmin: false,
              onRename: (film) async => film,
              onProgressUpdated: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('播放'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));

      expect(find.text('播放进度暂时未能保存，请检查连接后重试。'), findsOneWidget);
      expect(api.progressSaveCount, 1);

      api.failProgressSaves = false;
      final retry = find.widgetWithText(TextButton, '重试');
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));

      expect(api.progressSaveCount, 2);
      expect(find.text('播放进度暂时未能保存，请检查连接后重试。'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      api.close();
    }
  });

  testWidgets('cinema close reports failed final save before allowing exit', (
    tester,
  ) async {
    final api = _MediaApi()..failProgressSaves = true;
    final platform = _videoPlayerTestPlatform;
    platform.calls.clear();
    VideoPlayerPlatform.instance = platform;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  useSafeArea: true,
                  barrierDismissible: false,
                  builder: (context) => CinemaDetailDialog(
                    api: api,
                    film: CinemaFilm.fromJson(<String, dynamic>{
                      'id': 8,
                      'title': 'A short film',
                      'path': 'Cinema/short.mp4',
                      'kind': 'movie',
                      'playable': true,
                      'browserPlayback': 'verified-direct',
                      'probeStatus': 'ready',
                    }),
                    isAdmin: false,
                    onRename: (film) async => film,
                    onProgressUpdated: (_) {},
                  ),
                ),
                child: const Text('打开影片'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开影片'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('播放'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.text('播放进度暂时未能保存，请检查连接后重试。'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();

    expect(find.text('A short film'), findsOneWidget);
    expect(find.text('播放进度暂时未能保存，请检查连接后重试。'), findsOneWidget);

    final closeAnyway = find.widgetWithText(TextButton, '仍然关闭');
    await tester.ensureVisible(closeAnyway);
    await tester.tap(closeAnyway);
    await tester.pumpAndSettle();
    expect(find.text('A short film'), findsNothing);
    expect(find.text('打开影片'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    api.close();
  });

  testWidgets('cinema system Back retries final progress before closing', (
    tester,
  ) async {
    final api = _MediaApi()..failProgressSaves = true;
    VideoPlayerPlatform.instance = _videoPlayerTestPlatform;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      api.close();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (context) => CinemaDetailDialog(
                  api: api,
                  film: CinemaFilm.fromJson(<String, dynamic>{
                    'id': 8,
                    'title': 'Back-handled film',
                    'path': 'Cinema/back.mp4',
                    'kind': 'movie',
                    'playable': true,
                    'browserPlayback': 'verified-direct',
                    'probeStatus': 'ready',
                  }),
                  isAdmin: false,
                  onRename: (film) async => film,
                  onProgressUpdated: (_) {},
                ),
              ),
              child: const Text('打开影片'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开影片'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('Back-handled film'), findsOneWidget);
    expect(find.text('播放进度暂时未能保存，请检查连接后重试。'), findsOneWidget);

    api.failProgressSaves = false;
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Back-handled film'), findsNothing);
    expect(find.text('打开影片'), findsOneWidget);
    expect(api.progressSaveCount, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('standalone cinema Escape respects failed progress save', (
    tester,
  ) async {
    final api = _MediaApi()..failProgressSaves = true;
    VideoPlayerPlatform.instance = _videoPlayerTestPlatform;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      api.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => CinemaDetailDialog(
                    api: api,
                    film: CinemaFilm.fromJson(<String, dynamic>{
                      'id': 81,
                      'title': 'Keyboard media',
                      'path': 'Cinema/keyboard.mp4',
                      'kind': 'movie',
                      'playable': true,
                      'browserPlayback': 'verified-direct',
                      'probeStatus': 'ready',
                    }),
                    isAdmin: false,
                    playerOnly: true,
                    onRename: (film) async => film,
                    onProgressUpdated: (_) {},
                  ),
                ),
              ),
              child: const Text('打开测试播放器'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开测试播放器'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cinemaPlayerPage')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.byKey(const ValueKey('cinemaPlayerPage')), findsOneWidget);
    expect(find.text('播放进度暂时未能保存，请检查连接后重试。'), findsOneWidget);

    api.failProgressSaves = false;
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cinemaPlayerPage')), findsNothing);
    expect(find.text('打开测试播放器'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'standalone cinema player fills full window on black stage with macOS traffic-light inset',
    (tester) async {
      final api = _MediaApi();
      final platform = _videoPlayerTestPlatform;
      VideoPlayerPlatform.instance = platform;
      platform.videoSize = const Size(1080, 1920);
      addTearDown(() async {
        platform.videoSize = const Size(640, 360);
        await tester.binding.setSurfaceSize(null);
        await tester.pumpWidget(const SizedBox.shrink());
        api.close();
      });

      await tester.binding.setSurfaceSize(const Size(1280, 800));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.macOS),
          home: CinemaDetailDialog(
            api: api,
            film: CinemaFilm.fromJson(<String, dynamic>{
              'id': 82,
              'title': '27366',
              'path': 'Cinema/Cats/27366.mov',
              'kind': 'movie',
              'year': 2026,
              'width': 1080,
              'height': 1920,
              'videoCodec': 'hevc',
              'playable': true,
              'browserPlayback': 'verified-direct',
              'probeStatus': 'ready',
            }),
            playlist: <CinemaFilm>[
              CinemaFilm.fromJson(const <String, dynamic>{
                'id': 82,
                'title': '27366',
                'path': 'Cinema/Cats/27366.mov',
                'kind': 'movie',
                'playable': true,
                'browserPlayback': 'verified-direct',
                'probeStatus': 'ready',
              }),
              CinemaFilm.fromJson(const <String, dynamic>{
                'id': 331,
                'title': '27367',
                'path': 'Cinema/Cats/27367.mov',
                'kind': 'movie',
                'playable': true,
                'browserPlayback': 'verified-direct',
                'probeStatus': 'ready',
              }),
              CinemaFilm.fromJson(const <String, dynamic>{
                'id': 332,
                'title': 'Other folder video',
                'path': 'Cinema/Dogs/99999.mov',
                'kind': 'movie',
                'playable': true,
                'browserPlayback': 'verified-direct',
                'probeStatus': 'ready',
              }),
            ],
            isAdmin: true,
            playerOnly: true,
            onRename: (film) async => film,
            onProgressUpdated: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final scaffold = tester.widget<Scaffold>(
        find.byKey(const ValueKey('cinemaPlayerPage')),
      );
      expect(scaffold.backgroundColor, Colors.black);

      final videoSize = tester.getSize(find.byType(VideoPlayer));
      expect(videoSize.height, closeTo(800.0, 1.0));
      expect(videoSize.width, closeTo(450.0, 1.0));

      final titleTopLeft = tester.getTopLeft(find.text('27366'));
      expect(titleTopLeft.dx, greaterThanOrEqualTo(96.0));

      final subtitlePillSize = tester.getSize(find.byTooltip('字幕与字号'));
      final qualityPillSize = tester.getSize(find.byTooltip('清晰度'));
      final speedPillSize = tester.getSize(find.byTooltip('播放倍速'));
      expect(subtitlePillSize.width, lessThan(140.0));
      expect(qualityPillSize.width, lessThan(120.0));
      expect(speedPillSize.width, lessThan(120.0));

      await tester.tap(find.byTooltip('铺满画面'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('适应屏幕'), findsOneWidget);
      await tester.tap(find.byTooltip('适应屏幕'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('cinemaPlayerPrevButton')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('cinemaPlayerNextButton')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('cinemaPlayerPlaylistToggle')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('cinemaPlayerPlaylistToggle')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cinemaPlaylistSheet')), findsOneWidget);
      expect(find.textContaining('Cinema / Cats · 共 2 个视频'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('cinemaPlaylistItem_82')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('cinemaPlaylistItem_331')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('cinemaPlaylistItem_332')),
        findsNothing,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cinemaPlaylistSheet')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('cinemaPlayerDetailsToggle')));
      await tester.pumpAndSettle();
      expect(find.byTooltip('收起播放信息'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byTooltip('收起播放信息'), findsNothing);
      expect(find.byKey(const ValueKey('cinemaPlayerPage')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
