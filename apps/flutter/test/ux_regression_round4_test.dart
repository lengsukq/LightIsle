import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_quick_jump.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/core/media_image_memory_cache.dart';
import 'package:lightisle/features/media/cinema_catalog_display.dart';
import 'package:lightisle/features/media/cinema_series_overview.dart';
import 'package:lightisle/features/media/media_models.dart';
import 'package:lightisle/features/media/photo_gallery_viewer_filmstrip.dart';
import 'package:lightisle/features/media/photo_media_view.dart';
import 'package:lightisle/features/settings/storage_page.dart';

class _RegressionStorageApi extends LightIsleApi {
  _RegressionStorageApi() : super('http://127.0.0.1');

  final List<(String, Map<String, String>?)> byteCalls = [];

  static final Uint8List _tinyPng = Uint8List.fromList([
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x08,
    0x06,
    0x00,
    0x00,
    0x00,
    0x1F,
    0x15,
    0xC4,
    0x89,
    0x00,
    0x00,
    0x00,
    0x0A,
    0x49,
    0x44,
    0x41,
    0x54,
    0x78,
    0x9C,
    0x63,
    0x00,
    0x01,
    0x00,
    0x00,
    0x05,
    0x00,
    0x01,
    0x0D,
    0x0A,
    0x2D,
    0xB4,
    0x00,
    0x00,
    0x00,
    0x00,
    0x49,
    0x45,
    0x4E,
    0x44,
    0xAE,
    0x42,
    0x60,
    0x82,
  ]);

  @override
  Future<Uint8List> bytes(
    String path, {
    Map<String, String>? query,
    int? maxBytes,
  }) async {
    byteCalls.add((path, query));
    return _tinyPng;
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    switch (path) {
      case '/api/v2/roots':
        return {
          'roots': [
            {
              'rootID': 'drive-1',
              'name': '主力盘',
              'generation': 1,
              'online': true,
              'filesystemTotalBytes': 200 * (1 << 30),
              'filesystemAvailableBytes': 100 * (1 << 30),
            },
          ],
        };
      case '/api/v2/me/storage':
      case '/api/v2/users/1/storage':
        return {
          'userId': 1,
          'quotaBytes': null,
          'accountedBytes': 10 * (1 << 30),
          'reservedBytes': 0,
          'enforcement': 'pending',
          'rootQuotas': [
            {
              'rootID': 'drive-1',
              'rootGeneration': 1,
              'quotaBytes': 100 * (1 << 30),
              'accountedBytes': 10 * (1 << 30),
              'reservedBytes': 0,
            },
          ],
          'locations': [],
        };
      case '/api/v2/users':
        return {
          'users': [
            {'id': 1, 'username': '成员'},
          ],
        };
      default:
        return {};
    }
  }
}

void main() {
  test('parseSubtitleText parses VTT, SRT, and ASS/SSA accurately', () {
    const vtt = '''
WEBVTT

00:00:01.000 --> 00:00:03.500
<b>LightIsle</b> 家庭影院
''';
    final vttCues = parseSubtitleText(vtt);
    expect(vttCues, hasLength(1));
    expect(vttCues.single.start, const Duration(seconds: 1));
    expect(vttCues.single.end, const Duration(seconds: 3, milliseconds: 500));
    expect(vttCues.single.text, 'LightIsle 家庭影院');

    const srt = '''
1
00:01:02,250 --> 00:01:05,750
<i>第一行</i>
第二行
''';
    final srtCues = parseSubtitleText(srt);
    expect(srtCues, hasLength(1));
    expect(
      srtCues.single.start,
      const Duration(minutes: 1, seconds: 2, milliseconds: 250),
    );
    expect(srtCues.single.text, '第一行\n第二行');

    const ass = '''
[Script Info]
Title: Test

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:10.50,0:00:14.00,Default,,0,0,0,,{\\an8}第二句
Dialogue: 0,0:00:02.00,0:00:05.00,Default,,0,0,0,,第一句\\N换行展示
''';
    final assCues = parseSubtitleText(ass);
    expect(assCues, hasLength(2));
    expect(assCues.first.start, const Duration(seconds: 2));
    expect(assCues.first.text, '第一句\n换行展示');
    expect(assCues.last.text, '第二句');
  });

  test(
    'cinema resume display helpers format season/episode and remaining time',
    () {
      final film = CinemaFilm.fromJson(<String, Object>{
        'id': 42,
        'title': '星际远航',
        'path': 'Shows/S02/E03.mp4',
        'kind': 'series',
        'season': 2,
        'episode': 3,
        'playable': true,
        'browserPlayback': 'verified-direct',
        'position': 600.0,
        'duration': 3600.0,
      });
      expect(formatCinemaSeasonEpisodeCode(film), 'S02E03');
      expect(formatCinemaRemainingText(film), '50 分钟');
      expect(formatCinemaResumeCtaLabel(film), '继续播放 S02E03 · 剩余 50 分钟');

      final other = CinemaFilm.fromJson(<String, Object>{
        'id': 41,
        'title': '序曲',
        'path': 'Shows/S01/E01.mp4',
        'kind': 'series',
        'season': 1,
        'episode': 1,
        'playable': true,
        'browserPlayback': 'verified-direct',
      });
      const series = CinemaSeriesInfo(
        id: 7,
        name: '星际远航',
        episodeCount: 2,
        watchedCount: 0,
        nextFilmId: 42,
        nextSeason: 2,
        nextEpisode: 3,
        inProgress: true,
      );
      expect(resolveSeriesResumeEpisode(series, [other, film])?.id, 42);
    },
  );

  testWidgets(
    'CinemaSeriesOverview auto-selects resume season and exposes hero CTA',
    (tester) async {
      final played = <int>[];
      final ep1 = CinemaFilm.fromJson(<String, Object>{
        'id': 10,
        'title': '第一季初遇',
        'path': 'Shows/S01E01.mp4',
        'kind': 'series',
        'season': 1,
        'episode': 1,
        'playable': true,
        'browserPlayback': 'verified-direct',
        'completed': true,
      });
      final ep2 = CinemaFilm.fromJson(<String, Object>{
        'id': 20,
        'title': '第二季启航',
        'path': 'Shows/S02E01.mp4',
        'kind': 'series',
        'season': 2,
        'episode': 1,
        'playable': true,
        'browserPlayback': 'verified-direct',
        'position': 300.0,
        'duration': 2100.0,
      });
      const series = CinemaSeriesInfo(
        id: 1,
        name: '航行日志',
        episodeCount: 2,
        watchedCount: 1,
        nextFilmId: 20,
        nextSeason: 2,
        nextEpisode: 1,
        nextTitle: '第二季启航',
        inProgress: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: CinemaSeriesOverview(
            series: series,
            episodes: [ep1, ep2],
            onEpisode: (f) async => played.add(f.id),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('cinemaSeriesResumeEpisode')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('cinemaEpisode_20')), findsOneWidget);
      expect(find.byKey(const ValueKey('cinemaEpisode_10')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('cinemaSeriesPlayCta')));
      await tester.pump();
      expect(played, [20]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'IsleQuickJumpStrip works inside IsleCanvas without Scaffold and enforces tooltips',
    (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: IsleCanvas(
            child: ListView(
              children: [
                IsleQuickJumpStrip(
                  items: [
                    IsleQuickJumpItem(
                      label: '测试跳转',
                      tooltip: '跳转到目标页面',
                      icon: Icons.bolt_rounded,
                      onTap: () => tapped = true,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(Tooltip), findsOneWidget);
      await tester.tap(find.widgetWithText(ActionChip, '测试跳转'));
      await tester.pump();
      expect(tapped, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'StoragePage quick jumps enforce strict member vs admin visibility',
    (tester) async {
      final api = _RegressionStorageApi();
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: StoragePage(
            key: const ValueKey('storage-member'),
            api: api,
            isAdmin: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('storageQuickJumpStrip')),
        250,
      );
      expect(
        find.byKey(const ValueKey('storageQuickJumpStrip')),
        findsOneWidget,
      );
      expect(find.text('重复大文件清理'), findsOneWidget);
      expect(find.text('相似照片去重'), findsOneWidget);
      expect(find.text('Mac 文件共享 (SMB)'), findsNothing);

      await tester.pumpWidget(
        MaterialApp(
          home: StoragePage(
            key: const ValueKey('storage-admin'),
            api: api,
            isAdmin: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('storageQuickJumpStrip')),
        250,
      );
      expect(find.text('Mac 文件共享 (SMB)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Filmstrip and inactive PhotoMediaVideo respect thumbnail size and route contracts',
    (tester) async {
      final api = _RegressionStorageApi();
      addTearDown(api.close);

      final galleryPhoto = PhotoAsset.fromJson(<String, Object>{
        'id': 101,
        'name': 'IMG_101.jpg',
        'path': 'Photos/IMG_101.jpg',
        'mime': 'image/jpeg',
      });
      final galleryRaw = PhotoAsset.fromJson(<String, Object>{
        'id': 102,
        'name': 'IMG_102.dng',
        'path': 'Photos/IMG_102.dng',
        'mime': 'image/x-adobe-dng',
      });
      final galleryVideo = PhotoAsset.fromJson(<String, Object>{
        'id': 202,
        'name': 'CLIP_202.mp4',
        'path': 'Photos/CLIP_202.mp4',
        'type': 'video',
        'mime': 'video/mp4',
      });

      // 1. Gallery mode filmstrip: photo uses /api/v2/photos/{id}/thumbnail (no query), RAW uses placeholder.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                PhotoGalleryViewerFilmstrip(
                  api: api,
                  memoryCache: MediaImageMemoryCache(),
                  items: [galleryPhoto, galleryRaw],
                  currentIndex: 0,
                  fileBrowserMode: false,
                  onSelectIndex: (_) {},
                ),
                Expanded(
                  child: PhotoMediaVideo(
                    api: api,
                    asset: galleryVideo,
                    active: false,
                    fileBrowserMode: false,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('RAW'), findsOneWidget);
      expect(
        api.byteCalls,
        containsAll([
          ('/api/v2/photos/101/thumbnail', null),
          ('/api/v2/photos/202/thumbnail', null),
        ]),
      );
      expect(api.byteCalls.where((c) => c.$1.contains('/102/')), isEmpty);

      // 2. File browser mode: both filmstrip and inactive video cover request size=512 (never 256 or 1024).
      api.byteCalls.clear();
      const filePhoto = PhotoAsset(
        id: 0,
        name: 'file_photo.jpg',
        path: 'Docs/file_photo.jpg',
        type: 'image',
        size: 1024,
        takenAt: 0,
        favorite: false,
        canWrite: false,
        mime: 'image/jpeg',
      );
      const filePhotoSecond = PhotoAsset(
        id: 0,
        name: 'file_photo_2.jpg',
        path: 'Docs/file_photo_2.jpg',
        type: 'image',
        size: 1024,
        takenAt: 0,
        favorite: false,
        canWrite: false,
        mime: 'image/jpeg',
      );
      const fileVideo = PhotoAsset(
        id: 0,
        name: 'file_clip.mp4',
        path: 'Docs/file_clip.mp4',
        type: 'video',
        size: 2048,
        takenAt: 0,
        favorite: false,
        canWrite: false,
        mime: 'video/mp4',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                PhotoGalleryViewerFilmstrip(
                  key: const ValueKey('file-filmstrip'),
                  api: api,
                  memoryCache: MediaImageMemoryCache(),
                  items: const [filePhoto, filePhotoSecond],
                  currentIndex: 0,
                  fileBrowserMode: true,
                  onSelectIndex: (_) {},
                ),
                Expanded(
                  child: PhotoMediaVideo(
                    key: const ValueKey('file-video'),
                    api: api,
                    asset: fileVideo,
                    active: false,
                    fileBrowserMode: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(api.byteCalls, hasLength(3));
      for (final call in api.byteCalls) {
        expect(call.$1, '/api/v2/files/thumbnail');
        expect(call.$2?['size'], '512');
      }
      expect(tester.takeException(), isNull);
    },
  );
}
