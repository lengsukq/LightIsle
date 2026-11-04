import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/authenticated_media_image.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/photos_page.dart';

/// A deliberately oversized first page. The production API pages results,
/// but the rendering path must remain lazy even for a 10k-item local list.
class _LargePhotoApi extends LightIsleApi {
  _LargePhotoApi() : super('http://127.0.0.1');

  final Uint8List _pixel = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lwAAAABJRU5ErkJggg==',
  );

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/photos/status') {
      return {
        'status': <String, Object>{'running': false},
      };
    }
    if (path.endsWith('/albums')) return {'albums': <Object>[]};
    if (path == '/api/v2/photos') {
      final newest = DateTime.utc(2026, 11, 4);
      return {
        'assets': [
          for (var i = 0; i < 10000; i++)
            {
              'id': i + 1,
              'name': 'family-${i + 1}.jpg',
              'path': 'Photos/family-${i + 1}.jpg',
              'type': 'photo',
              'size': 10000,
              'takenAt':
                  newest
                      .subtract(Duration(days: i ~/ 120))
                      .millisecondsSinceEpoch ~/
                  1000,
              'canWrite': false,
            },
        ],
        'nextCursor': 0,
      };
    }
    throw StateError('Unexpected request: $path');
  }

  @override
  Future<Uint8List> bytes(
    String path, {
    Map<String, String>? query,
    int? maxBytes,
  }) async => _pixel;
}

void main() {
  testWidgets('10k gallery items render only viewport thumbnail widgets', (
    tester,
  ) async {
    final api = _LargePhotoApi();
    addTearDown(api.close);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PhotosPage(api: api, isAdmin: false)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(SliverGrid), findsWidgets);
    expect(
      find.byType(AuthenticatedMediaImage).evaluate().length,
      lessThan(100),
    );
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byType(AuthenticatedMediaImage).evaluate().length,
      lessThan(100),
    );
    expect(tester.takeException(), isNull);
  });
}
