import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/authenticated_media_image.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/media_models.dart';
import 'package:lightisle/features/media/media_ui.dart';
import 'package:lightisle/features/media/cinema_page.dart';
import 'package:lightisle/features/media/photos_page.dart';
import 'package:lightisle/features/media/photo_gallery_viewer.dart';
import 'package:video_player/video_player.dart';
// The platform interface is a transitive implementation dependency of
// video_player; this fake keeps the lifecycle test independent of native code.
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

part 'media_pages_test_fakes.dart';
part 'media_pages_detail_cases.dart';

void main() {
  testWidgets('gallery selection mode can select all loaded photos and exit', (
    tester,
  ) async {
    final api = _MediaApi();
    addTearDown(api.close);
    api.firstPhotos.complete(<String, dynamic>{
      'assets': <Object>[
        _photoAssetJson(101, 'select-a.jpg', DateTime(2026, 10, 10)),
        _photoAssetJson(102, 'select-b.jpg', DateTime(2026, 10, 10)),
      ],
      'nextCursor': 0,
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.light),
        home: Scaffold(body: PhotosPage(api: api, isAdmin: false)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(find.byTooltip('选择照片'));
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, '全选当前页'));
    await tester.pump();
    expect(find.text('已选 2 项'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '完成'));
    await tester.pump();
    expect(find.text('已选 2 项'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cinema selection avoids playback and selects all loaded films', (
    tester,
  ) async {
    final api = _MediaApi();
    addTearDown(api.close);
    api.firstCinema.complete(<String, dynamic>{
      'films': <Object>[
        <String, Object>{
          'id': 401,
          'title': 'Selection film A',
          'path': 'Cinema/selection-a.mp4',
          'kind': 'movie',
          'playable': true,
          'browserPlayback': 'verified-direct',
          'size': 1024,
        },
        <String, Object>{
          'id': 402,
          'title': 'Selection film B',
          'path': 'Cinema/selection-b.mp4',
          'kind': 'movie',
          'playable': true,
          'browserPlayback': 'verified-direct',
          'size': 1024,
        },
      ],
      'nextCursor': 0,
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.light),
        home: Scaffold(body: CinemaPage(api: api, isAdmin: false)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(find.byKey(const Key('cinema-select-toggle')));
    await tester.pump();
    await tester.tap(find.text('Selection film A').first);
    await tester.pump();
    expect(find.text('已选 1 项 · 最多 50 项'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, '全选当前页'));
    await tester.pump();
    expect(find.text('已选 2 项 · 最多 50 项'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '完成'));
    await tester.pump();
    expect(find.text('已选 2 项 · 最多 50 项'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long photo timelines only mount visible thumbnail widgets', (
    tester,
  ) async {
    final api = _MediaApi();
    addTearDown(api.close);
    api.firstPhotos.complete(<String, dynamic>{
      'assets': <Object>[
        for (var id = 1; id <= 120; id++)
          _photoAssetJson(id, 'photo-$id.jpg', DateTime(2026, 10, 10)),
      ],
      'nextCursor': 0,
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.light),
        home: Scaffold(body: PhotosPage(api: api, isAdmin: false)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.byType(SliverGrid), findsOneWidget);
    expect(
      find.byType(AuthenticatedMediaImage).evaluate().length,
      lessThan(120),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('album sheet loads a scoped cover through authenticated API', (
    tester,
  ) async {
    final api = _MediaApi();
    addTearDown(api.close);
    api.sharedAlbumRows.add(<String, Object?>{
      'id': 11,
      'name': '旅行',
      'count': 1,
      'coverAssetId': 77,
    });
    api.firstPhotos.complete(<String, dynamic>{
      'assets': <Object>[],
      'nextCursor': 0,
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.light),
        home: Scaffold(body: PhotosPage(api: api, isAdmin: false)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('相册'));
    await tester.pumpAndSettle();

    expect(find.text('旅行 · 1'), findsOneWidget);
    expect(
      api.mediaByteRequests.any(
        (request) =>
            request['path'] == '/api/v2/photos/77/thumbnail' &&
            request['maxBytes'] == 4 * 1024 * 1024,
      ),
      isTrue,
    );
  });

  testWidgets(
    'closing cinema while HLS URI resolves does not create a player',
    (tester) async {
      final api = _DelayedHlsApi();
      final platform = _videoPlayerTestPlatform;
      VideoPlayerPlatform.instance = platform;
      final activeBefore = platform._events.length;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CinemaDetailDialog(
              api: api,
              film: CinemaFilm.fromJson(<String, dynamic>{
                'id': 90,
                'title': 'Delayed HLS',
                'path': 'Cinema/film.mkv',
                'kind': 'movie',
                'playable': false,
                'browserPlayback': 'download-only',
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
      expect(api.resolvingRelay, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      api.relay.complete(Uri.parse('http://127.0.0.1/index.m3u8'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(platform._events.length, activeBefore);
      expect(tester.takeException(), isNull);
      api.close();
    },
  );

  testWidgets('photo grid groups assets under month headers', (tester) async {
    final api = _MediaApi();
    addTearDown(api.close);
    api.firstPhotos.complete(<String, dynamic>{
      'assets': <Object>[
        _photoAssetJson(41, 'september.jpg', DateTime(2026, 9, 15)),
        _photoAssetJson(42, 'october.jpg', DateTime(2026, 10, 2)),
        _photoAssetJson(43, 'october-late.jpg', DateTime(2026, 10, 20)),
      ],
      'nextCursor': 0,
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.light),
        home: Scaffold(body: PhotosPage(api: api, isAdmin: false)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2026年10月'), findsOneWidget);
    expect(find.text('2026年9月'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('scrolling near the end loads the next page automatically', (
    tester,
  ) async {
    final api = _MediaApi();
    addTearDown(api.close);
    final assets = <Object>[
      for (var i = 0; i < 30; i++)
        _photoAssetJson(
          60 + i,
          'batch-$i.jpg',
          DateTime(2026, 8, 1 + (i % 28)),
        ),
    ];
    api.firstPhotos.complete(<String, dynamic>{
      'assets': assets,
      'nextCursor': 48,
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.light),
        home: Scaffold(body: PhotosPage(api: api, isAdmin: false)),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.photoQueries.length, 1);

    await tester.drag(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomScrollView &&
            widget.scrollDirection == Axis.vertical,
      ),
      const Offset(0, -1200),
    );
    await tester.pumpAndSettle();

    expect(api.photoQueries.length, greaterThanOrEqualTo(2));
    expect(api.photoQueries.last['cursor'], '48');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('media labels explain TMDB credential failures', () {
    expect(
      mediaErrorLabel(
        const LightIsleApiException(
          code: 'tmdb_auth_failed',
          statusCode: 401,
          message: 'tmdb_auth_failed',
        ),
      ),
      'TMDB 拒绝了访问令牌，请检查 Read Access Token 是否有效。',
    );
    expect(
      mediaErrorLabel(
        const LightIsleApiException(
          code: 'tmdb_access_denied',
          statusCode: 403,
          message: 'tmdb_access_denied',
        ),
      ),
      'TMDB 不允许此令牌访问，请检查令牌权限或稍后重试。',
    );
  });

  testWidgets(
    'horizontal photo navigation does not load the next timeline page',
    (tester) async {
      final api = _MediaApi();
      addTearDown(api.close);
      api.firstPhotos.complete({'assets': <Object>[], 'nextCursor': 48});
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PhotosPage(api: api, isAdmin: false)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(
        find.byWidgetPredicate(
          (w) =>
              w is SingleChildScrollView &&
              w.scrollDirection == Axis.horizontal,
        ),
        const Offset(-150, 0),
      );
      await tester.pumpAndSettle();
      expect(api.photoQueries.length, 1);
    },
  );

  testWidgets('gallery discards a page response from the previous filter', (
    tester,
  ) async {
    final api = _MediaApi();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PhotosPage(api: api, isAdmin: false)),
      ),
    );
    await tester.pump();

    // This test exercises stale-request isolation rather than the popup hit
    // target. Invoke the same selection callback while the first request is
    // still pending, so an animated menu barrier cannot swallow the tap.
    tester
        .widget<PopupMenuButton<String>>(find.byType(PopupMenuButton<String>))
        .onSelected!('sharedFavorites');
    // The earlier request is deliberately unresolved; its loading spinner
    // keeps animating, so this step must not wait for all frames to settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.photoQueries.last['favorites'], '1');
    expect(find.text('还没有共享收藏'), findsOneWidget);

    api.firstPhotos.complete(<String, dynamic>{
      'assets': <Object>[
        <String, Object>{
          'id': 41,
          'path': 'Old/previous.jpg',
          'name': 'previous.jpg',
          'type': 'photo',
          'size': 1024,
          'takenAt': 1,
          'favorite': false,
          'canWrite': true,
        },
      ],
      'nextCursor': 0,
    });
    await tester.pumpAndSettle();

    expect(find.text('还没有共享收藏'), findsOneWidget);
    expect(find.text('previous.jpg'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'personal favorites and private albums use separate gallery filters',
    (tester) async {
      final api = _MediaApi()
        ..privateAlbumRows.add(<String, Object>{
          'id': 91,
          'name': 'Only for me',
          'count': 2,
        });
      addTearDown(api.close);
      api.firstPhotos.complete(<String, dynamic>{
        'assets': <Object>[],
        'nextCursor': 0,
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          home: Scaffold(body: PhotosPage(api: api, isAdmin: false)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('我的收藏'));
      await tester.pumpAndSettle();
      expect(api.photoQueries.last['personal'], '1');
      expect(api.photoQueries.last.containsKey('favorites'), isFalse);
      expect(api.photoQueries.last.containsKey('privateAlbum'), isFalse);
      expect(find.text('还没有个人收藏'), findsOneWidget);

      await tester.tap(find.text('相册'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Only for me · 2'));
      await tester.pumpAndSettle();
      expect(api.photoQueries.last['privateAlbum'], '91');
      expect(api.photoQueries.last.containsKey('personal'), isFalse);
      expect(api.photoQueries.last.containsKey('favorites'), isFalse);
      expect(find.textContaining('仅当前账号可见'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'private album create rename and delete use owner-scoped routes',
    (tester) async {
      final api = _MediaApi()
        ..privateAlbumRows.add(<String, Object>{
          'id': 91,
          'name': 'Only for me',
          'count': 0,
        });
      addTearDown(api.close);
      api.firstPhotos.complete(<String, dynamic>{
        'assets': <Object>[],
        'nextCursor': 0,
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          home: Scaffold(body: PhotosPage(api: api, isAdmin: false)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('相册'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建私人相册'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Receipts');
      await tester.tap(find.widgetWithText(FilledButton, '创建'));
      await tester.pumpAndSettle();
      expect(api.sendRequests.last['method'], 'POST');
      expect(api.sendRequests.last['path'], '/api/v2/photos/private-albums');
      expect(api.sendRequests.last['body'], <String, String>{
        'name': 'Receipts',
      });

      await tester.tap(find.text('相册'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Only for me · 0'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多照片操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重命名私人相册'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Renamed privately');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(api.sendRequests.last['method'], 'PATCH');
      expect(api.sendRequests.last['path'], '/api/v2/photos/private-albums/91');

      await tester.tap(find.byTooltip('更多照片操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除私人相册'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(OutlinedButton, '删除私人相册'),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.sendRequests.last['method'], 'DELETE');
      expect(api.sendRequests.last['path'], '/api/v2/photos/private-albums/91');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('photo personal and shared favorite actions remain independent', (
    tester,
  ) async {
    final api = _MediaApi()
      ..privateAlbumRows.add(<String, Object>{
        'id': 91,
        'name': 'Only for me',
        'count': 0,
      });
    addTearDown(api.close);
    api.firstPhotos.complete(<String, dynamic>{
      'assets': <Object>[
        <String, Object>{
          'id': 44,
          'path': 'Photos/kept.jpg',
          'name': 'kept.jpg',
          'type': 'photo',
          'size': 12,
          'takenAt': 1,
          'favorite': false,
          'personalFavorite': false,
          'canWrite': true,
        },
      ],
      'nextCursor': 0,
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.light),
        home: Scaffold(body: PhotosPage(api: api, isAdmin: false)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(find.bySemanticsLabel(RegExp('kept\\.jpg')));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('加入我的收藏'));
    await tester.pumpAndSettle();
    expect(
      api.sendRequests.last['path'],
      '/api/v2/photos/44/personal-favorite',
    );
    expect(api.sendRequests.last['body'], <String, Object>{'favorite': true});

    await tester.tap(find.byTooltip('加入共享收藏'));
    await tester.pumpAndSettle();
    expect(api.sendRequests.last['path'], '/api/v2/photos/44/favorite');
    expect(api.sendRequests.last['body'], <String, Object>{'favorite': true});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'photo membership can be added to and removed from a private album',
    (tester) async {
      final api = _MediaApi();
      addTearDown(api.close);
      final asset = PhotoAsset.fromJson(<String, dynamic>{
        'id': 44,
        'path': 'Photos/kept.jpg',
        'name': 'kept.jpg',
        'type': 'photo',
        'size': 12,
        'takenAt': 1,
        'favorite': false,
        'canWrite': true,
      });
      final albums = <MediaAlbum>[
        const MediaAlbum(id: 91, name: 'Only for me', count: 1),
      ];

      Widget detail({required int currentAlbum}) => MaterialApp(
        theme: buildIsleTheme(Brightness.light),
        home: Scaffold(
          body: PhotoDetailDialog(
            api: api,
            asset: asset,
            albums: const [],
            privateAlbums: albums,
            isAdmin: false,
            currentAlbumId: 0,
            currentPrivateAlbumId: currentAlbum,
            canToggleFavorite: false,
            onToggleFavorite: (value) async => value,
            onAddToAlbum: (_, _) async {},
            onRemoveFromAlbum: (_, _) async {},
            onAddToPrivateAlbum: (albumId, assetId) async {
              await api.send(
                'POST',
                '/api/v2/photos/private-albums/$albumId/items',
                body: <String, int>{'assetId': assetId},
              );
            },
            onRemoveFromPrivateAlbum: (albumId, assetId) async {
              await api.send(
                'DELETE',
                '/api/v2/photos/private-albums/$albumId/items/$assetId',
              );
            },
          ),
        ),
      );

      await tester.pumpWidget(detail(currentAlbum: 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      final privateAlbumField = find.byType(DropdownButtonFormField<int>);
      await tester.ensureVisible(privateAlbumField);
      await tester.tap(privateAlbumField);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Only for me').last);
      await tester.pumpAndSettle();
      final addToPrivate = find.text('加入私人相册');
      await tester.ensureVisible(addToPrivate);
      await tester.tap(addToPrivate);
      await tester.pumpAndSettle();
      expect(api.sendRequests.last['method'], 'POST');
      expect(
        api.sendRequests.last['path'],
        '/api/v2/photos/private-albums/91/items',
      );
      expect(api.sendRequests.last['body'], <String, int>{'assetId': 44});

      await tester.pumpWidget(detail(currentAlbum: 91));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.tap(find.text('移出此私人相册'));
      await tester.pumpAndSettle();
      expect(api.sendRequests.last['method'], 'DELETE');
      expect(
        api.sendRequests.last['path'],
        '/api/v2/photos/private-albums/91/items/44',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  _registerMediaDetailTests();
}
