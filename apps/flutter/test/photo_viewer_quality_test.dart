import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/media_models.dart';
import 'package:lightisle/features/media/photo_gallery_viewer.dart';
import 'package:lightisle/features/media/photo_viewer_quality.dart';

PhotoAsset photo({String name = 'MVIMG_20261027_230138.jpg', int size = 4800000}) =>
    PhotoAsset(
      id: 9,
      path: '图库/2026/$name',
      name: name,
      type: 'photo',
      size: size,
      takenAt: 0,
      favorite: false,
      canWrite: true,
    );

class _ImageRequests extends LightIsleApi {
  _ImageRequests() : super('http://127.0.0.1');
  final paths = <String>[];
  final queries = <Map<String, String>?>[];
  final limits = <int?>[];

  @override
  Future<Uint8List> bytes(
    String path, {
    Map<String, String>? query,
    int? maxBytes,
  }) async {
    paths.add(path);
    queries.add(query);
    limits.add(maxBytes);
    // A tiny valid GIF; the test is interested in the authenticated source,
    // not platform-specific JPEG decoding.
    return base64Decode('R0lGODlhAQABAAAAACwAAAAAAQABAAACAUwAOw==');
  }
}

void main() {
  test('standard photos open their actual original without a manual zoom', () {
    for (final name in ['Photo.jpg', 'Photo.JPEG', 'still.png', 'photo.webp', 'a.gif']) {
      expect(photoViewerCanOpenOriginal(photo(name: name)), isTrue);
    }
    expect(photoViewerCanOpenOriginal(photo(name: 'photo.heic')), isFalse);
    expect(photoViewerCanOpenOriginal(photo(name: 'image.dng')), isFalse);
    expect(
      photoViewerCanOpenOriginal(photo(size: photoViewerOriginalMaxBytes + 1)),
      isFalse,
    );
    expect(
      photoViewerOriginalTooLarge(photo(size: photoViewerOriginalMaxBytes + 1)),
      isTrue,
    );
  });

  testWidgets('fullscreen JPEG displays a quick preview while requesting full original', (tester) async {
    final api = _ImageRequests();
    addTearDown(api.close);
    final asset = photo();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PhotoMediaImage(
            api: api,
            asset: asset,
            onTap: () {},
            onZoomChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(api.paths, containsAll([
      '/api/v2/files/thumbnail',
      '/api/v2/files/preview',
    ]));
    final originalIndex = api.paths.indexOf('/api/v2/files/preview');
    expect(api.queries[originalIndex], {'path': asset.path});
    expect(api.limits[originalIndex], photoViewerOriginalMaxBytes);
    final original = find.byKey(ValueKey('img-${asset.id}-${asset.path}-orig'));
    final images = tester.widgetList<Image>(
      find.descendant(of: original, matching: find.byType(Image)),
    ).toList();
    if (images.isNotEmpty) {
      expect(images.first.image, isNot(isA<ResizeImage>()),
          reason: 'full-screen original must never be decoded at a smaller fixed cacheWidth');
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('HEIC falls back to explicitly labeled rendered preview', (tester) async {
    final api = _ImageRequests();
    addTearDown(api.close);
    final asset = photo(name: 'still.heic');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PhotoMediaImage(
            api: api,
            asset: asset,
            onTap: () {},
            onZoomChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(api.paths, ['/api/v2/files/thumbnail']);
    expect(api.queries.single, {'path': asset.path, 'size': '2048'});
    expect(find.textContaining('压缩预览'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('neighbour page uses preview until it becomes active', (tester) async {
    final api = _ImageRequests();
    addTearDown(api.close);
    final asset = photo();
    Widget viewer({required bool active}) => MaterialApp(
      home: Scaffold(
        body: PhotoMediaImage(
          api: api,
          asset: asset,
          active: active,
          onTap: () {},
          onZoomChanged: (_) {},
        ),
      ),
    );
    await tester.pumpWidget(viewer(active: false));
    await tester.pump();
    expect(api.paths, ['/api/v2/files/thumbnail']);
    await tester.pumpWidget(viewer(active: true));
    await tester.pump();
    expect(api.paths, [
      '/api/v2/files/thumbnail',
      '/api/v2/files/preview',
    ]);
    expect(api.limits.last, photoViewerOriginalMaxBytes);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
