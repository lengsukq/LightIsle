import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/core/media_image_memory_cache.dart';
import 'package:lightisle/features/media/media_models.dart';
import 'package:lightisle/features/media/photo_gallery_viewer.dart';
import 'package:lightisle/features/media/photo_zoom_surface.dart';

class _ViewerApi extends LightIsleApi {
  _ViewerApi() : super('http://127.0.0.1');

  final List<Map<String, Object?>> shares = [];
  final List<(String, String)> mediaRequests = [];

  @override
  Future<Uint8List> bytes(
    String path, {
    Map<String, String>? query,
    int? maxBytes,
  }) async {
    mediaRequests.add((path, query?['path'] ?? ''));
    return base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lwAAAABJRU5ErkJggg==',
    );
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/file-shares' && method == 'POST') {
      shares.add(Map<String, Object?>.from(body as Map));
      return {'token': 'temporary-test-token'};
    }
    throw StateError('Unexpected $method $path');
  }
}

class _SlowOriginalViewerApi extends _ViewerApi {
  final original = Completer<Uint8List>();

  @override
  Future<Uint8List> bytes(
    String path, {
    Map<String, String>? query,
    int? maxBytes,
  }) {
    if (path == '/api/v2/files/preview') {
      mediaRequests.add((path, query?['path'] ?? ''));
      return original.future;
    }
    return super.bytes(path, query: query, maxBytes: maxBytes);
  }
}

PhotoAsset _asset(int id, {bool video = false}) =>
    PhotoAsset.fromJson(<String, dynamic>{
      'id': id,
      'name': video ? 'movie.mp4' : 'photo-$id.jpg',
      'path': video ? 'Trips/movie.mp4' : 'Trips/photo-$id.jpg',
      'type': video ? 'video' : 'photo',
      'takenAt': 1792000000,
    });

Widget _viewer(
  _ViewerApi api,
  List<PhotoAsset> assets, {
  bool editable = false,
  bool deleteConfirmed = false,
  bool offline = false,
  MediaImageMemoryCache? sharedCache,
}) => MaterialApp(
  home: PhotoGalleryViewer(
    api: api,
    memoryCache: sharedCache,
    assets: assets,
    initialIndex: 0,
    canEditSharedFavorite: (_) => editable,
    onSharedFavorite: (asset) async => asset,
    onPersonalFavorite: (asset) async => asset,
    onDelete: editable ? (_) async => deleteConfirmed : null,
    onDetails: (_) async {},
    onLoadMore: () async => assets,
    offlineAccountId: offline ? 'test-account' : '',
  ),
);

void main() {
  testWidgets('slow original never obscures the loaded thumbnail preview', (
    tester,
  ) async {
    final api = _SlowOriginalViewerApi();
    addTearDown(api.close);
    await tester.pumpWidget(_viewer(api, [_asset(1)]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      api.mediaRequests.any(
        (item) =>
            item.$1 == '/api/v2/files/thumbnail' &&
            item.$2 == 'Trips/photo-1.jpg',
      ),
      isTrue,
    );
    expect(
      api.mediaRequests.any((item) => item.$1 == '/api/v2/files/preview'),
      isTrue,
    );
    // The preview stays rendered while full-resolution bytes are pending.
    expect(find.byType(Image), findsWidgets);
    expect(find.text('正在加载清晰原图…'), findsNothing);

    api.original.complete(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lwAAAABJRU5ErkJggg==',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('原图暂不可用，已显示压缩预览'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reopening the viewer reuses the photo tab original cache', (
    tester,
  ) async {
    final api = _ViewerApi();
    addTearDown(api.close);
    final cache = MediaImageMemoryCache();
    addTearDown(cache.dispose);

    await tester.pumpWidget(_viewer(api, [_asset(1)], sharedCache: cache));
    await tester.pumpAndSettle();
    final initialRequests = api.mediaRequests
        .where(
          (request) =>
              request.$1 == '/api/v2/files/preview' &&
              request.$2 == 'Trips/photo-1.jpg',
        )
        .length;
    expect(initialRequests, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_viewer(api, [_asset(1)], sharedCache: cache));
    await tester.pumpAndSettle();
    expect(
      api.mediaRequests.where(
        (request) =>
            request.$1 == '/api/v2/files/preview' &&
            request.$2 == 'Trips/photo-1.jpg',
      ),
      hasLength(1),
    );
  });

  testWidgets('revisiting a photo uses session-cached original bytes', (
    tester,
  ) async {
    final api = _ViewerApi();
    addTearDown(api.close);
    await tester.pumpWidget(_viewer(api, [_asset(1), _asset(2), _asset(3)]));
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      await tester.pumpAndSettle();
    }
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byIcon(Icons.chevron_left_rounded));
      await tester.pumpAndSettle();
    }
    expect(find.text('1 / 3'), findsOneWidget);
    expect(
      find.text('正在加载清晰原图…'),
      findsNothing,
      reason: 'Returning to a cached original should not show a loading state.',
    );
    expect(
      api.mediaRequests.where(
        (request) =>
            request.$1 == '/api/v2/files/preview' &&
            request.$2 == 'Trips/photo-1.jpg',
      ),
      hasLength(1),
      reason: 'Navigating back should not download the same original again.',
    );
  });

  testWidgets(
    'horizontal swipe still changes photo after zoom viewer upgrade',
    (tester) async {
      final api = _ViewerApi();
      addTearDown(api.close);
      await tester.pumpWidget(_viewer(api, [_asset(1), _asset(2)]));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byType(PhotoZoomSurface).first,
        const Offset(-420, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
    },
  );

  testWidgets('slideshow auto-advances past videos and stops at the end', (
    tester,
  ) async {
    final api = _ViewerApi();
    addTearDown(api.close);
    await tester.pumpWidget(
      _viewer(api, [_asset(1), _asset(2, video: true), _asset(3)]),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('幻灯片设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckedPopupMenuItem<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('播放幻灯片'));
    await tester.pump();
    expect(find.byKey(const Key('slideshowCountdownRing')), findsOneWidget);
    expect(find.byKey(const Key('slideshowCountdownLabel')), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.byKey(const Key('slideshowCountdownRing')),
          )
          .value,
      closeTo(1.0, .01),
    );
    // The scroll animation starts on the next frame after the countdown's
    // ticker completes; give it its first frame before advancing by 400ms.
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 400));
    final counters = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data)
        .where((value) => value != null && value.contains(' / '))
        .toList();
    expect(counters, contains('3 / 3'));
    // The second countdown starts after the page transition finishes.
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(seconds: 3));
    // End-of-album may await the next-page check before stopping playback.
    await tester.pump();
    expect(find.byTooltip('播放幻灯片'), findsOneWidget);
  });

  testWidgets('bottom photo toolbar is a compact clipped floating pill', (
    tester,
  ) async {
    final api = _ViewerApi();
    addTearDown(api.close);
    await tester.pumpWidget(_viewer(api, [_asset(1)]));
    await tester.pumpAndSettle();

    final toolbar = find.byKey(const Key('photoViewerBottomToolbar'));
    expect(toolbar, findsOneWidget);
    expect(tester.getSize(toolbar).width, lessThan(450));
    expect(tester.getSize(toolbar).height, lessThanOrEqualTo(64));
    expect(
      find.descendant(of: toolbar, matching: find.byType(BackdropFilter)),
      findsOneWidget,
    );
    expect(find.byTooltip('分享媒体'), findsOneWidget);
    expect(find.byTooltip('更多媒体操作'), findsOneWidget);
    await tester.tap(find.byTooltip('更多媒体操作'));
    await tester.pumpAndSettle();
    expect(find.text('保存原文件'), findsOneWidget);
  });

  testWidgets(
    'secondary actions are accessible in overflow on narrow screens',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final api = _ViewerApi();
      addTearDown(api.close);
      await tester.pumpWidget(
        _viewer(api, [_asset(1)], editable: true, offline: true),
      );
      await tester.pumpAndSettle();

      final toolbar = find.byKey(const Key('photoViewerBottomToolbar'));
      expect(tester.getSize(toolbar).width, lessThanOrEqualTo(292));
      expect(tester.getSize(toolbar).height, lessThanOrEqualTo(64));
      await tester.tap(find.byTooltip('更多媒体操作'));
      await tester.pumpAndSettle();
      expect(find.text('将原文件移入回收站'), findsOneWidget);
      expect(find.text('离线保存照片原件'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pausing removes the visible countdown and stops auto-advance', (
    tester,
  ) async {
    final api = _ViewerApi();
    addTearDown(api.close);
    await tester.pumpWidget(_viewer(api, [_asset(1), _asset(2)]));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('播放幻灯片'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    final progress = tester.widget<CircularProgressIndicator>(
      find.byKey(const Key('slideshowCountdownRing')),
    );
    expect(progress.value, greaterThan(0));
    expect(find.byKey(const Key('slideshowCountdownLabel')), findsOneWidget);
    await tester.tap(find.byTooltip('暂停幻灯片'));
    await tester.pump();
    expect(find.byKey(const Key('slideshowCountdownRing')), findsNothing);
    expect(find.byTooltip('播放幻灯片'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    expect(
      tester.widget<PageView>(find.byType(PageView)).controller?.page,
      closeTo(0, .01),
      reason: 'Paused slides must not advance after the header auto-hides.',
    );
  });

  testWidgets('desktop keyboard arrows navigate and space toggles slideshow', (
    tester,
  ) async {
    final api = _ViewerApi();
    addTearDown(api.close);
    await tester.pumpWidget(_viewer(api, [_asset(1), _asset(2)]));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(find.byTooltip('暂停幻灯片'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(find.byTooltip('播放幻灯片'), findsOneWidget);
  });

  testWidgets(
    'photo sharing reuses the authenticated expiring file-share API',
    (tester) async {
      final api = _ViewerApi();
      addTearDown(api.close);
      await tester.pumpWidget(_viewer(api, [_asset(9)]));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('分享媒体'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成分享链接'));
      await tester.pumpAndSettle();
      expect(api.shares, hasLength(1));
      expect(api.shares.single['path'], 'Trips/photo-9.jpg');
      expect(api.shares.single['hours'], 24);
      expect(find.text('复制分享链接'), findsOneWidget);
    },
  );

  testWidgets('gallery controls fit 320px and 200% text without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final api = _ViewerApi();
    addTearDown(api.close);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 720),
          textScaler: TextScaler.linear(2),
        ),
        child: _viewer(api, [_asset(1), _asset(2)]),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('分享媒体'), findsOneWidget);
    await tester.tap(find.byTooltip('更多媒体操作'));
    await tester.pumpAndSettle();
    expect(find.text('保存原文件'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('gallery arrow glass is clipped to its button, not the photo', (
    tester,
  ) async {
    final api = _ViewerApi();
    addTearDown(api.close);
    await tester.pumpWidget(_viewer(api, [_asset(1), _asset(2)]));
    await tester.pumpAndSettle();

    final arrow = find.byIcon(Icons.chevron_right_rounded);
    expect(arrow, findsOneWidget);
    final circle = find.ancestor(of: arrow, matching: find.byType(ClipOval));
    expect(circle, findsOneWidget);
    expect(tester.getSize(circle), const Size(44, 44));
    // A BackdropFilter with no local clip can blur the entire background
    // beneath the overlay even though its child is only a tiny button.
    expect(
      find.descendant(of: circle, matching: find.byType(ClipRect)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: circle, matching: find.byType(BackdropFilter)),
      findsOneWidget,
    );
  });

  testWidgets(
    'desktop navigation arrows and horizontal scroll navigate photos',
    (tester) async {
      final previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = previous);

      final api = _ViewerApi();
      addTearDown(api.close);
      await tester.pumpWidget(_viewer(api, [_asset(1), _asset(2), _asset(3)]));
      await tester.pumpAndSettle();

      expect(find.text('1 / 3'), findsOneWidget);
      // On photo 1, right navigation arrow is visible, left is not
      final nextBtn = find.byIcon(Icons.chevron_right_rounded);
      expect(nextBtn, findsOneWidget);
      expect(find.byIcon(Icons.chevron_left_rounded), findsNothing);

      await tester.tap(nextBtn);
      await tester.pumpAndSettle();
      expect(find.text('2 / 3'), findsOneWidget);

      // On photo 2, both left and right navigation arrows are visible
      expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);

      await tester.tap(find.byIcon(Icons.chevron_left_rounded));
      await tester.pumpAndSettle();
      expect(find.text('1 / 3'), findsOneWidget);
      debugDefaultTargetPlatformOverride = previous;
    },
  );

  testWidgets(
    'deleting a photo in multi-photo viewer advances to the remaining photo without closing',
    (tester) async {
      final api = _ViewerApi();
      addTearDown(api.close);
      await tester.pumpWidget(
        _viewer(
          api,
          [_asset(1), _asset(2)],
          editable: true,
          deleteConfirmed: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 / 2'), findsOneWidget);

      await tester.tap(find.byTooltip('更多媒体操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('将原文件移入回收站'));
      await tester.pumpAndSettle();

      expect(find.text('1 / 1'), findsOneWidget);
      expect(find.text('photo-2.jpg'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'macOS modern header reserves clearance for window traffic lights',
    (tester) async {
      final previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = previous);

      final api = _ViewerApi();
      addTearDown(api.close);
      await tester.pumpWidget(_viewer(api, [_asset(1)]));
      await tester.pumpAndSettle();

      final backBtn = find.byIcon(Icons.arrow_back_rounded);
      expect(backBtn, findsOneWidget);
      final offset = tester.getTopLeft(backBtn);
      expect(offset.dx, greaterThanOrEqualTo(80.0));
      debugDefaultTargetPlatformOverride = previous;
    },
  );
}
