import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/files/downloads_page.dart';

class _MultiEngineDownloadApi extends LightIsleApi {
  _MultiEngineDownloadApi({
    this.aria2Available = true,
    this.ytdlpAvailable = false,
    this.webArchiveAvailable = true,
  }) : super('http://127.0.0.1:17777');

  bool aria2Available;
  bool ytdlpAvailable;
  bool webArchiveAvailable;
  final List<({String method, String path, Object? body})> writes = [];
  List<Map<String, dynamic>> tasks = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/downloads/status') {
      return {
        'available': aria2Available,
        'reason': aria2Available ? '' : 'aria2_not_installed',
        'aria2Available': aria2Available,
        'aria2Version': aria2Available ? '1.37.0' : '',
        'aria2Reason': aria2Available ? '' : 'aria2_not_installed',
        'ytdlpAvailable': ytdlpAvailable,
        'ytdlpVersion': ytdlpAvailable ? '2026.11.01' : '',
        'ytdlpReason': ytdlpAvailable ? '' : 'ytdlp_not_installed',
        'webArchiveAvailable': webArchiveAvailable,
        'networkAllowed': true,
      };
    }
    if (path == '/api/v2/downloads') {
      return {'tasks': tasks};
    }
    return {'entries': [], 'canWrite': true};
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    writes.add((method: method, path: path, body: body));
    return {};
  }
}

void main() {
  testWidgets(
    'shows honest yt-dlp install hint without blocking web archive creation',
    (tester) async {
      final api = _MultiEngineDownloadApi(
        aria2Available: false,
        ytdlpAvailable: false,
        webArchiveAvailable: true,
      );
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: DownloadsPage(api: api, initialDestination: 'Articles'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('downloadEngineStatusCard')),
        findsOneWidget,
      );
      expect(find.textContaining('未安装 yt-dlp'), findsOneWidget);
      expect(find.text('网页离线保存 · 内置就绪'), findsOneWidget);

      await tester.tap(find.text('新建下载'));
      await tester.pumpAndSettle();

      // Switch to yt-dlp to verify honest hint & disabled submit.
      await tester.tap(find.byKey(const ValueKey('dlEngineChipYtdlp')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('brew install yt-dlp'),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '开始下载'))
            .onPressed,
        isNull,
      );

      // Switch to Web Archive and submit cleanly.
      await tester.tap(find.byKey(const ValueKey('dlEngineChipWebArchive')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'https://example.com/family-recipe',
      );
      await tester.tap(find.widgetWithText(FilledButton, '开始保存'));
      await tester.pumpAndSettle();

      expect(api.writes.single.method, 'POST');
      expect(api.writes.single.path, '/api/v2/downloads');
      expect(api.writes.single.body, {
        'url': 'https://example.com/family-recipe',
        'destination': 'Articles',
        'maxBytes': 0,
        'engine': 'webarchive',
      });
    },
  );

  testWidgets('yt-dlp mode submits engine and options payload', (tester) async {
    final api = _MultiEngineDownloadApi(
      aria2Available: true,
      ytdlpAvailable: true,
      webArchiveAvailable: true,
    )..tasks = [
        {
          'id': 'dl-yt-1',
          'engine': 'ytdlp',
          'url': 'https://www.bilibili.com/video/BV1demo',
          'filename': '旅行Vlog.mp4',
          'destination': 'Videos',
          'status': 'running',
          'totalBytes': 1000,
          'completedBytes': 400,
        },
      ];
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(home: DownloadsPage(api: api, initialDestination: 'Videos')),
    );
    await tester.pumpAndSettle();

    // Non-aria2 running tasks display engine tag and do not offer aria2 pause.
    expect(find.textContaining('yt-dlp · 下载中'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '暂停'), findsNothing);

    await tester.tap(find.text('新建下载'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dlEngineChipYtdlp')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField).first,
      'https://www.bilibili.com/video/BV1test',
    );
    await tester.tap(find.byKey(const ValueKey('dlYtdlpFormatDropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1080P 优先').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('dlYtdlpPlaylistSwitch')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('dlYtdlpPlaylistMaxField')),
      '5',
    );
    await tester.tap(find.widgetWithText(FilledButton, '开始下载'));
    await tester.pumpAndSettle();

    expect(api.writes.single.path, '/api/v2/downloads');
    expect(api.writes.single.body, {
      'url': 'https://www.bilibili.com/video/BV1test',
      'destination': 'Videos',
      'maxBytes': 0,
      'engine': 'ytdlp',
      'options': {
        'format': '1080p',
        'allowPlaylist': true,
        'playlistMaxItems': 5,
      },
    });
  });
}
