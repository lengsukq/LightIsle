import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/cinema_film_tile.dart';
import 'package:lightisle/features/media/media_models.dart';
import 'package:lightisle/features/media/photo_ai_models.dart';
import 'package:lightisle/features/media/photo_person_shares_card.dart';
import 'package:lightisle/features/overview/overview_page.dart';
import 'package:lightisle/features/settings/automation_page.dart';

class _AuditFakeApi extends LightIsleApi {
  _AuditFakeApi() : super('http://127.0.0.1:16666');

  Map<String, dynamic> _automationTasks() => {
    'tasks': [
      {
        'id': 'daily-report',
        'name': '每日简报',
        'enabled': false,
        'running': false,
        'revision': 'r1',
        'schedule': {'cron': '0 8 * * *', 'timezone': 'Asia/Shanghai'},
        'notification': {
          'events': ['failure'],
          'channels': ['email'],
        },
      },
    ],
  };

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    if (method == 'POST' && path == '/api/v2/automation/refresh') {
      return _automationTasks();
    }
    return <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    return switch (path) {
      '/api/v2/automation/tasks' => _automationTasks(),
      '/api/v2/automation/channels' => {
        'channels': ['email'],
      },
      '/api/v2/photos/person-shares' => {
        'shares': <Map<String, dynamic>>[],
        'members': [
          {'id': 2, 'username': 'alice'},
        ],
      },
      '/api/v2/system' => {
        'hostname': '测试 Mac',
        'architecture': 'arm64',
        'cpuCount': 8,
        'cpuPercent': 12.5,
        'memoryTotal': 16000000000,
        'memoryUsed': 8000000000,
        'diskTotal': 1000000000000,
        'diskFree': 500000000000,
        'volumes': <Map<String, dynamic>>[],
      },
      '/api/v2/roots' => {
        'roots': [
          {
            'rootID': 'offline-disk',
            'name': '外置备盘',
            'generation': 1,
            'online': false,
          },
        ],
      },
      '/api/v2/tasks' => {'tasks': <Map<String, dynamic>>[]},
      _ => <String, dynamic>{},
    };
  }
}

void main() {
  testWidgets('CinemaFilmTile InkWell does not claim a duplicate focus stop', (
    tester,
  ) async {
    final api = _AuditFakeApi();
    addTearDown(api.close);
    const film = CinemaFilm(
      id: 1,
      title: '测试影片',
      path: 'movies/test.mp4',
      kind: 'movie',
      series: '',
      season: 0,
      episode: 0,
      year: 2025,
      size: 1024,
      playable: true,
      mime: 'video/mp4',
      probeStatus: 'done',
      browserPlayback: 'native',
      container: 'mp4',
      videoCodec: 'h264',
      audioCodec: 'aac',
      durationSeconds: 120,
      width: 1920,
      height: 1080,
      position: 0,
      duration: 120,
      completed: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.light),
        home: Scaffold(
          body: SizedBox(
            width: 180,
            height: 360,
            child: CinemaFilmTile(
              api: api,
              film: film,
              isAdmin: true,
              selecting: false,
              selected: false,
              onToggle: () {},
              onOpen: () {},
              onRename: () async => film,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tileInkWell = tester
        .widgetList<InkWell>(find.byType(InkWell))
        .where((w) => w.onLongPress != null)
        .single;
    expect(tileInkWell.canRequestFocus, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AutomationPage editor action bar wraps cleanly on 320px width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _AuditFakeApi();
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildIsleTheme(Brightness.light),
        home: AutomationPage(api: api),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Cron 与通知'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cron 与通知'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('加载最新配置'));
    await tester.pumpAndSettle();
    expect(find.text('保存设置'), findsOneWidget);
    expect(find.text('加载最新配置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'PhotoPersonSharesCard resets selection cleanly when selected person disappears',
    (tester) async {
      final api = _AuditFakeApi();
      addTearDown(api.close);

      const person1 = PersonSummary(
        id: 10,
        name: '宝宝',
        photoCount: 12,
        faceCount: 12,
      );
      const person2 = PersonSummary(
        id: 20,
        name: '妈妈',
        photoCount: 8,
        faceCount: 8,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          home: Scaffold(
            body: SingleChildScrollView(
              child: PhotoPersonSharesCard(
                api: api,
                persons: const [person1, person2],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Remove person1 (which was selected initially) -> dropdown must not assert.
      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          home: Scaffold(
            body: SingleChildScrollView(
              child: PhotoPersonSharesCard(api: api, persons: const [person2]),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'OverviewPage attention banner stacks cleanly on 320px at 2.0x text scale',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = _AuditFakeApi();
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2.0)),
            child: IsleCanvas(child: child!),
          ),
          home: Scaffold(
            body: OverviewPage(api: api, isAdmin: true, onNavigate: (_) {}),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('1 个存储目录离线'), findsOneWidget);
      expect(find.text('查看存储'), findsOneWidget);
      expect(find.text('重新检查'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
