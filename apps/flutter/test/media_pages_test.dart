import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/media_models.dart';
import 'package:lightisle/features/media/media_ui.dart';
import 'package:lightisle/features/media/cinema_page.dart';
import 'package:lightisle/features/media/photos_page.dart';
import 'package:video_player/video_player.dart';
// The platform interface is a transitive implementation dependency of
// video_player; this fake keeps the lifecycle test independent of native code.
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

final _videoPlayerTestPlatform = _VideoPlayerTestPlatform();

class _MediaApi extends LightIsleApi {
  _MediaApi() : super('http://127.0.0.1');

  bool failProgressSaves = false;
  bool failMediaBytes = false;
  int progressSaveCount = 0;
  final List<Map<String, Object?>> mediaByteRequests = [];
  final List<Map<String, Object?>> sendRequests = [];
  final List<Map<String, String>> photoQueries = [];
  final List<Map<String, String>> cinemaQueries = [];
  final List<Map<String, Object?>> privateAlbumRows = [];
  final List<Map<String, dynamic>> tmdbResults = [];
  Map<String, dynamic>? cinemaDetail;
  final Completer<Map<String, dynamic>> firstPhotos = Completer();
  final Completer<Map<String, dynamic>> firstCinema = Completer();
  int _photoCalls = 0;
  int _cinemaCalls = 0;

  @override
  Map<String, String> get mediaHeaders => const {};

  @override
  Uri uri(String path, [Map<String, String>? query]) => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    path: path,
    queryParameters: query,
  );

  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query}) {
    if (path == '/api/v1/photos/status') {
      return Future.value(<String, dynamic>{
        'status': <String, dynamic>{'running': false},
      });
    }
    if (path == '/api/v1/photos/albums') {
      return Future.value(<String, dynamic>{'albums': <Object>[]});
    }
    if (path == '/api/v1/photos/private-albums') {
      return Future.value(<String, dynamic>{'albums': privateAlbumRows});
    }
    if (path == '/api/v1/photos') {
      _photoCalls++;
      photoQueries.add(Map<String, String>.from(query ?? const {}));
      if (_photoCalls == 1) return firstPhotos.future;
      return Future.value(<String, dynamic>{
        'assets': <Object>[],
        'nextCursor': 0,
      });
    }
    if (path == '/api/v1/cinema/status') {
      return Future.value(<String, dynamic>{
        'status': <String, dynamic>{'running': false},
      });
    }
    if (path == '/api/v1/cinema') {
      _cinemaCalls++;
      cinemaQueries.add(Map<String, String>.from(query ?? const {}));
      if (_cinemaCalls == 1) return firstCinema.future;
      return Future.value(<String, dynamic>{
        'films': <Object>[],
        'nextCursor': 0,
      });
    }
    if (cinemaDetail != null &&
        path == '/api/v1/cinema/${cinemaDetail!['id']}') {
      return Future.value(Map<String, dynamic>.from(cinemaDetail!));
    }
    if (path == '/api/v1/cinema/62') {
      return Future.value(<String, dynamic>{
        'id': 62,
        'title': 'Card title opens the film',
        'path': 'Cinema/card-title.mp4',
        'kind': 'movie',
        'playable': true,
        'browserPlayback': 'verified-direct',
        'probeStatus': 'ready',
      });
    }
    throw StateError('Unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    sendRequests.add(<String, Object?>{
      'method': method,
      'path': path,
      'body': body,
    });
    if (path.endsWith('/progress')) {
      progressSaveCount++;
      if (failProgressSaves) {
        throw const LightIsleApiException(
          code: 'network_timeout',
          message: '连接服务器超时，请检查网络后重试。',
        );
      }
    }
    if (path.endsWith('/metadata/tmdb/search')) {
      return <String, dynamic>{'results': tmdbResults};
    }
    if (path.endsWith('/metadata/nfo') && cinemaDetail != null) {
      cinemaDetail = <String, dynamic>{
        ...cinemaDetail!,
        'overview': 'Imported from local sidecar.',
        'metadataSource': 'nfo:manual.nfo',
      };
      return <String, dynamic>{};
    }
    if (path.endsWith('/metadata/tmdb/match') && cinemaDetail != null) {
      final selected = tmdbResults.first;
      cinemaDetail = <String, dynamic>{
        ...cinemaDetail!,
        'overview': selected['overview'],
        'rating': selected['rating'],
        'metadataSource': 'tmdb:movie:${selected['id']}',
      };
      return <String, dynamic>{};
    }
    return <String, dynamic>{};
  }

  @override
  Future<Uint8List> bytes(
    String path, {
    Map<String, String>? query,
    int? maxBytes,
  }) async {
    mediaByteRequests.add(<String, Object?>{
      'path': path,
      'query': query,
      'maxBytes': maxBytes,
    });
    if (failMediaBytes) {
      throw const LightIsleApiException(
        code: 'network_error',
        message: '无法连接服务器，请检查地址和网络后重试。',
      );
    }
    return Uint8List(0);
  }
}

void main() {
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

    await tester.tap(find.text('共享收藏'));
    await tester.pumpAndSettle();
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

      await tester.tap(find.text('新建私人相册'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Receipts');
      await tester.tap(find.widgetWithText(FilledButton, '创建'));
      await tester.pumpAndSettle();
      expect(api.sendRequests.last['method'], 'POST');
      expect(api.sendRequests.last['path'], '/api/v1/photos/private-albums');
      expect(api.sendRequests.last['body'], <String, String>{
        'name': 'Receipts',
      });

      await tester.tap(find.text('Only for me · 0'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, '改名'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Renamed privately');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(api.sendRequests.last['method'], 'PATCH');
      expect(api.sendRequests.last['path'], '/api/v1/photos/private-albums/91');

      await tester.tap(find.widgetWithText(TextButton, '删除私人相册'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(OutlinedButton, '删除私人相册'),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.sendRequests.last['method'], 'DELETE');
      expect(api.sendRequests.last['path'], '/api/v1/photos/private-albums/91');
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
      '/api/v1/photos/44/personal-favorite',
    );
    expect(api.sendRequests.last['body'], <String, Object>{'favorite': true});

    await tester.tap(find.byTooltip('加入共享收藏'));
    await tester.pumpAndSettle();
    expect(api.sendRequests.last['path'], '/api/v1/photos/44/favorite');
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
                '/api/v1/photos/private-albums/$albumId/items',
                body: <String, int>{'assetId': assetId},
              );
            },
            onRemoveFromPrivateAlbum: (albumId, assetId) async {
              await api.send(
                'DELETE',
                '/api/v1/photos/private-albums/$albumId/items/$assetId',
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
        '/api/v1/photos/private-albums/91/items',
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
        '/api/v1/photos/private-albums/91/items/44',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

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
    expect(api.sendRequests.single['path'], '/api/v1/cinema/201/metadata/nfo');
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
      '/api/v1/cinema/201/metadata/tmdb/search',
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
      '/api/v1/cinema/201/metadata/tmdb/match',
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

    await tester.tap(find.widgetWithText(ChoiceChip, '电影'));
    await tester.pumpAndSettle();
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
    expect(api.mediaByteRequests.single['path'], '/api/v1/cinema/62/poster');
    expect(api.mediaByteRequests.single['maxBytes'], 4 * 1024 * 1024);
    await tester.pump(const Duration(milliseconds: 20));
    final title = find.text('Card title opens the film').first;
    await tester.tap(title);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();

    expect(find.byTooltip('关闭'), findsOneWidget);
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
    expect(api.mediaByteRequests.single['path'], '/api/v1/photos/73/thumbnail');
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
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    for (final size in const [Size(600, 800), Size(1280, 900)]) {
      tester.view.physicalSize = size;
      viewport.value = size;
      await tester.pump();
      expect(
        find.text('A film title that wraps at large text sizes'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }

    await tester.pumpWidget(
      responsivePage(PhotosPage(api: api, isAdmin: false)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.byType(GridView), findsOneWidget);
    expect(find.byType(Image), findsNWidgets(6));
    expect(tester.takeException(), isNull);
    for (final size in const [Size(600, 800), Size(1280, 900)]) {
      tester.view.physicalSize = size;
      viewport.value = size;
      await tester.pump();
      expect(find.byType(GridView), findsOneWidget);
      expect(find.byType(Image), findsNWidgets(6));
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

      await tester.tap(find.byTooltip('播放'));
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
      final subtitles = tester.widget<DropdownButton<String>>(
        find.byType(DropdownButton<String>),
      );
      expect(subtitles.style?.color, Colors.white);
      expect(subtitles.dropdownColor, const Color(0xFF202124));
      for (final item in subtitles.items!) {
        final label = (item.child as Text);
        expect(label.style?.color, Colors.white);
      }
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
}

class _VideoPlayerTestPlatform extends VideoPlayerPlatform {
  final List<String> calls = [];
  final Map<int, StreamController<VideoEvent>> _events = {};
  int _nextId = 1;
  Size videoSize = const Size(640, 360);

  @override
  Future<void> init() async {}

  @override
  Future<int?> create(DataSource dataSource) => createWithOptions(
    VideoCreationOptions(
      dataSource: dataSource,
      viewType: VideoViewType.textureView,
    ),
  );

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _nextId++;
    final events = StreamController<VideoEvent>.broadcast();
    _events[id] = events;
    Timer.run(() {
      if (!events.isClosed) {
        events.add(
          VideoEvent(
            eventType: VideoEventType.initialized,
            duration: const Duration(minutes: 1),
            size: videoSize,
          ),
        );
      }
    });
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    calls.add('dispose');
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> play(int playerId) async => calls.add('play');

  @override
  Future<void> pause(int playerId) async => calls.add('pause');

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildView(int playerId) => Texture(textureId: playerId);
}
