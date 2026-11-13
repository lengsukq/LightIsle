import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_data_cache.dart';
import 'package:lightisle/core/isle_ui.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/media/cinema_page.dart';
import 'package:lightisle/features/media/photos_page.dart';
import 'package:lightisle/features/media/photos_page_state_models.dart';
import 'package:lightisle/features/overview/overview_page.dart';
import 'package:lightisle/features/settings/beta_diagnostic_report.dart';
import 'package:lightisle/features/settings/settings_troubleshooting_section.dart';

final Uint8List _transparentPng = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
  0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, //
  0x89, 0x00, 0x00, 0x00, 0x0a, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, //
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, //
  0x42, 0x60, 0x82,
]);

class _StatefulTabBox extends StatefulWidget {
  const _StatefulTabBox(this.label);

  final String label;

  @override
  State<_StatefulTabBox> createState() => _StatefulTabBoxState();
}

class _StatefulTabBoxState extends State<_StatefulTabBox> {
  int _count = 0;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('${widget.label}:$_count'),
      TextButton(
        onPressed: () => setState(() => _count++),
        child: Text('inc-${widget.label}'),
      ),
    ],
  );
}

class _Round3FakeApi extends LightIsleApi {
  _Round3FakeApi() : super('http://127.0.0.1:16667');

  Completer<Map<String, dynamic>>? pendingPhotos;
  Completer<Map<String, dynamic>>? pendingCinema;
  int systemCalls = 0;
  double cpuPercent = 12.5;

  @override
  Map<String, String> get mediaHeaders => const {};

  @override
  Uri uri(String path, [Map<String, String>? query]) => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: 16667,
    path: path,
    queryParameters: query,
  );

  @override
  Future<String> betaDiagnosticReport() async =>
      '{"status":"ok","client":"flutter"}';

  @override
  Future<Uint8List> bytes(
    String path, {
    Map<String, String>? query,
    int? maxBytes,
  }) async => _transparentPng;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/photos') {
      final completer = pendingPhotos;
      if (completer != null && !completer.isCompleted) {
        return completer.future;
      }
      return <String, dynamic>{'assets': <Object>[], 'nextCursor': 0};
    }
    if (path == '/api/v2/cinema') {
      final kind = query?['kind'];
      if (kind == null) {
        final completer = pendingCinema;
        if (completer != null && !completer.isCompleted) {
          return completer.future;
        }
      }
      return <String, dynamic>{'films': <Object>[], 'nextCursor': 0};
    }
    return switch (path) {
      '/api/v2/photos/status' || '/api/v2/cinema/status' => <String, dynamic>{
        'status': <String, dynamic>{'running': false},
      },
      '/api/v2/photos/albums' || '/api/v2/photos/private-albums' =>
        <String, dynamic>{'albums': <Object>[]},
      '/api/v2/photos/timeline' => <String, dynamic>{'months': <Object>[]},
      '/api/v2/system' => <String, dynamic>{
        'hostname': '测试 Mac',
        'architecture': 'arm64',
        'cpuCount': 8,
        'cpuPercent': cpuPercent,
        'memoryTotal': 16000000000,
        'memoryUsed': 8000000000,
        'diskTotal': 1000000000000,
        'diskFree': 500000000000,
        'volumes': <Map<String, dynamic>>[],
      }..also((_) => systemCalls++),
      '/api/v2/roots' => <String, dynamic>{
        'roots': <Map<String, dynamic>>[
          {
            'rootID': 'main-disk',
            'name': '主盘',
            'generation': 1,
            'online': true,
          },
        ],
      },
      '/api/v2/tasks' => <String, dynamic>{'tasks': <Object>[]},
      _ => <String, dynamic>{},
    };
  }
}

extension<T> on T {
  T also(void Function(T value) block) {
    block(this);
    return this;
  }
}

void main() {
  testWidgets(
    'IsleFluidTabSwitcher handles rapid interruptions, preserves state, and stops idle tickers',
    (tester) async {
      var settledCount = 0;
      var activeIndex = 0;
      late StateSetter setHostState;

      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                setHostState = setState;
                return IsleFluidTabSwitcher(
                  index: activeIndex,
                  onSettled: () => settledCount++,
                  children: const [
                    _StatefulTabBox('tab0'),
                    _StatefulTabBox('tab1'),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);

      await tester.tap(find.text('inc-tab0'));
      await tester.pump();
      expect(find.text('tab0:1'), findsOneWidget);

      // Start transition 0 -> 1, then interrupt mid-flight back to 0.
      setHostState(() => activeIndex = 1);
      await tester.pump(const Duration(milliseconds: 60));
      setHostState(() => activeIndex = 0);
      await tester.pumpAndSettle();

      expect(settledCount, greaterThanOrEqualTo(1));
      expect(find.text('tab0:1'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('IsleFluidTabSwitcher settles immediately under reduced motion', (
    tester,
  ) async {
    var settledCount = 0;
    var activeIndex = 0;
    late StateSetter setHostState;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                setHostState = setState;
                return IsleFluidTabSwitcher(
                  index: activeIndex,
                  onSettled: () => setHostState(() => settledCount++),
                  children: const [
                    _StatefulTabBox('reduced0'),
                    _StatefulTabBox('reduced1'),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    setHostState(() => activeIndex = 1);
    await tester.pump();
    await tester.pump();

    expect(settledCount, 1);
    expect(find.text('reduced1:0'), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'buildIslePageRoute adapts desktop vs mobile transitions and obeys reduced motion',
    (tester) async {
      final navKey = GlobalKey<NavigatorState>();
      final desktopTheme = buildIsleTheme(Brightness.light)
          .copyWith(platform: TargetPlatform.macOS);

      expect(
        islePageTransitionBuilders[TargetPlatform.macOS],
        isA<IsleDesktopPageTransitionsBuilder>(),
      );
      expect(
        islePageTransitionBuilders[TargetPlatform.windows],
        isA<IsleDesktopPageTransitionsBuilder>(),
      );
      expect(
        islePageTransitionBuilders[TargetPlatform.linux],
        isA<IsleDesktopPageTransitionsBuilder>(),
      );

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          theme: desktopTheme,
          home: const Scaffold(body: Text('root-screen')),
        ),
      );

      unawaited(
        navKey.currentState!.push<void>(
          buildIslePageRoute(
            builder: (_) => const Scaffold(body: Text('desktop-detail')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      expect(find.text('desktop-detail'), findsOneWidget);
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('desktop-detail'),
            matching: find.byType(ColoredBox),
          ),
          matching: find.byType(ScaleTransition),
        ),
        findsWidgets,
      );
      await tester.pumpAndSettle();

      // Reduced motion bypasses desktop ScaleTransition wrapper during push.
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: MaterialApp(
            navigatorKey: navKey,
            theme: desktopTheme,
            home: const Scaffold(body: Text('root-reduced')),
          ),
        ),
      );
      unawaited(
        pushIslePage<void>(
          navKey.currentContext!,
          (_) => const Scaffold(body: Text('reduced-detail')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(find.text('reduced-detail'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.text('reduced-detail'),
          matching: find.byType(ScaleTransition),
        ),
        findsNothing,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'PhotosPage SWR renders cached items immediately without loading flash',
    (tester) async {
      IsleDataCache.instance.clearMemory();
      addTearDown(IsleDataCache.instance.clearMemory);

      final api = _Round3FakeApi()
        ..pendingPhotos = Completer<Map<String, dynamic>>();
      addTearDown(api.close);

      final cacheKey = Uri(
        queryParameters: PhotosFilterScopeState().buildQueryParameters(
          limit: 48,
          cursor: 0,
        ),
      ).query;
      IsleDataCache.instance.putJsonMap(
        api,
        'photos',
        cacheKey,
        <String, dynamic>{
          'assets': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 901,
              'path': 'Trips/cached.jpg',
              'name': 'cached.jpg',
              'type': 'photo',
              'size': 2048,
              'takenAt': DateTime(2026, 11, 5).millisecondsSinceEpoch ~/ 1000,
              'favorite': false,
              'canWrite': false,
            },
          ],
          'nextCursor': 0,
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          home: Scaffold(body: PhotosPage(api: api, isAdmin: true)),
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('selectMonth_2026-11')), findsOneWidget);
      expect(find.byType(IsleLoadingState), findsNothing);

      api.pendingPhotos!.complete(<String, dynamic>{
        'assets': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 902,
            'path': 'Trips/fresh.jpg',
            'name': 'fresh.jpg',
            'type': 'photo',
            'size': 2048,
            'takenAt': DateTime(2026, 10, 12).millisecondsSinceEpoch ~/ 1000,
            'favorite': false,
            'canWrite': false,
          },
        ],
        'nextCursor': 0,
      });
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('selectMonth_2026-10')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'CinemaPage SWR renders cached films immediately without loading flash',
    (tester) async {
      IsleDataCache.instance.clearMemory();
      addTearDown(IsleDataCache.instance.clearMemory);

      final api = _Round3FakeApi()
        ..pendingCinema = Completer<Map<String, dynamic>>();
      addTearDown(api.close);

      final cacheKey = Uri(
        queryParameters: const <String, String>{'limit': '48', 'cursor': '0'},
      ).query;
      IsleDataCache.instance.putJsonMap(
        api,
        'cinema',
        cacheKey,
        <String, dynamic>{
          'films': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 701,
              'title': '缓存影片标题',
              'path': 'Cinema/cached.mp4',
              'kind': 'movie',
              'playable': true,
              'browserPlayback': 'verified-direct',
              'probeStatus': 'ready',
            },
          ],
          'nextCursor': 0,
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          home: Scaffold(body: CinemaPage(api: api, isAdmin: true)),
        ),
      );
      await tester.pump();

      expect(find.text('缓存影片标题'), findsWidgets);
      expect(find.byType(IsleLoadingState), findsNothing);

      api.pendingCinema!.complete(<String, dynamic>{
        'films': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 702,
            'title': '最新影片标题',
            'path': 'Cinema/fresh.mp4',
            'kind': 'movie',
            'playable': true,
            'browserPlayback': 'verified-direct',
            'probeStatus': 'ready',
          },
        ],
        'nextCursor': 0,
      });
      await tester.pumpAndSettle();

      expect(find.text('最新影片标题'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'OverviewPage coalesces unchanged 5s admin polls with zero redundant rebuilds',
    (tester) async {
      final api = _Round3FakeApi();
      addTearDown(api.close);

      var overviewRebuilds = 0;
      final prevCallback = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (Element element, bool builtOnce) {
        if (element.widget is OverviewPage) {
          overviewRebuilds++;
        }
        prevCallback?.call(element, builtOnce);
      };
      addTearDown(() => debugOnRebuildDirtyWidget = prevCallback);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildIsleTheme(Brightness.light),
          home: Scaffold(
            body: OverviewPage(api: api, isAdmin: true, onNavigate: (_) {}),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final callsAfterInitial = api.systemCalls;
      expect(callsAfterInitial, greaterThanOrEqualTo(1));
      expect(find.text('12.5%'), findsOneWidget);
      overviewRebuilds = 0;

      // Poll fires after 5s with identical data -> zero OverviewPage rebuilds.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(api.systemCalls, greaterThan(callsAfterInitial));
      expect(overviewRebuilds, 0);

      // Mutate payload -> next 5s poll updates OverviewPage once.
      api.cpuPercent = 58.0;
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(overviewRebuilds, 1);
      expect(find.text('58.0%'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Controls, troubleshooting expand, and diagnostic copy feedback respect motion and render contracts',
    (tester) async {
      String? copiedText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments as Map<dynamic, dynamic>?;
            copiedText = args?['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final api = _Round3FakeApi();
      addTearDown(api.close);
      var pillTapped = 0;
      late BuildContext hostContext;

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: MaterialApp(
            theme: buildIsleTheme(Brightness.light),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  hostContext = context;
                  return SingleChildScrollView(
                    child: Column(
                      children: [
                        const IsleLoadingState(label: '加载中'),
                        IslePillButton(
                          label: '动作胶囊',
                          onPressed: () => pillTapped++,
                        ),
                        const IslePillButton(label: '禁用胶囊'),
                        AdminTroubleshootingSection(
                          onOpenDiagnostics: () {},
                          onOpenAudit: () {},
                          onOpenUploadMaintenance: () {},
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );

      final progress = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(progress.value, isNotNull);

      await tester.tap(find.text('动作胶囊'));
      await tester.tap(find.text('禁用胶囊'));
      expect(pillTapped, 1);

      await tester.tap(find.text('高级排障'));
      await tester.pumpAndSettle();
      expect(find.text('设备诊断与 Key 状态'), findsOneWidget);

      unawaited(showBetaDiagnosticReport(hostContext, api));
      await tester.pumpAndSettle();
      expect(find.text('复制报告'), findsOneWidget);

      await tester.tap(find.text('复制报告'));
      await tester.pumpAndSettle();
      expect(copiedText, contains('"client":"flutter"'));
      expect(find.text('已复制报告'), findsOneWidget);

      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
