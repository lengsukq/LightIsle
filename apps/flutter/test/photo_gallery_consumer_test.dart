import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/media_models.dart';
import 'package:lightisle/features/media/photo_gallery_viewer.dart';
import 'package:lightisle/features/media/photo_zoom_surface.dart';

class _ViewerApi extends LightIsleApi {
  _ViewerApi() : super('http://127.0.0.1');

  final List<Map<String, Object?>> shares = [];

  @override
  Future<Uint8List> bytes(
    String path, {
    Map<String, String>? query,
    int? maxBytes,
  }) async => base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lwAAAABJRU5ErkJggg==',
  );

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

PhotoAsset _asset(int id, {bool video = false}) =>
    PhotoAsset.fromJson(<String, dynamic>{
      'id': id,
      'name': video ? 'movie.mp4' : 'photo-$id.jpg',
      'path': video ? 'Trips/movie.mp4' : 'Trips/photo-$id.jpg',
      'type': video ? 'video' : 'photo',
      'takenAt': 1792000000,
    });

Widget _viewer(_ViewerApi api, List<PhotoAsset> assets) => MaterialApp(
  home: PhotoGalleryViewer(
    api: api,
    assets: assets,
    initialIndex: 0,
    canEditSharedFavorite: (_) => false,
    onSharedFavorite: (asset) async => asset,
    onPersonalFavorite: (asset) async => asset,
    onDetails: (_) async {},
    onLoadMore: () async => assets,
  ),
);

void main() {
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
      tester.widget<CircularProgressIndicator>(
        find.byKey(const Key('slideshowCountdownRing')),
      ).value,
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
    expect(find.byTooltip('保存原文件'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
