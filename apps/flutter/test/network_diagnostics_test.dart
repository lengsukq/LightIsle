import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/settings/network_diagnostics_controller.dart';
import 'package:lightisle/features/settings/network_diagnostics_page.dart';

class _DiagnosticApi extends LightIsleApi {
  _DiagnosticApi() : super('http://127.0.0.1:17880');
  int pingCount = 0, downloadCount = 0, uploadCount = 0;
  bool failSomePings = false;
  bool emulateCoreRestart = false;
  Completer<void>? holdDownload;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path != '/api/v2/network-test/ping') {
      throw StateError('Unexpected path: $path');
    }
    pingCount++;
    if (failSomePings && pingCount % 5 == 0) {
      throw const LightIsleApiException(
        code: 'network_timeout',
        message: '本次请求超时',
      );
    }
    return {
      'ok': true,
      'coreUptimeSeconds': emulateCoreRestart && pingCount > 6
          ? pingCount - 6
          : 900 + pingCount,
    };
  }

  @override
  Future<int> networkTestDownload(
    int length, {
    void Function(int, int)? onProgress,
  }) async {
    downloadCount++;
    onProgress?.call(0, length);
    await holdDownload?.future;
    onProgress?.call(length, length);
    return length;
  }

  @override
  Future<int> networkTestUpload(
    int length, {
    void Function(int, int)? onProgress,
  }) async {
    uploadCount++;
    onProgress?.call(length, length);
    return length;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (!const bool.fromEnvironment('LIGHTISLE_CAPTURE_NETWORK')) return;
    final body = FontLoader('IsleNetworkReviewBody')
      ..addFont(
        File('/System/Library/Fonts/Supplemental/Arial Unicode.ttf')
            .readAsBytes()
            .then((v) => ByteData.sublistView(v)),
      );
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          '${File('/opt/homebrew/bin/flutter').resolveSymbolicLinksSync().replaceFirst(RegExp(r'/bin/flutter$'), '')}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes().then((v) => ByteData.sublistView(v)),
      );
    await body.load();
    await icons.load();
  });
  test(
    'real staged experiment measures both directions and failed requests',
    () async {
      final api = _DiagnosticApi()..failSomePings = true;
      final model = NetworkDiagnosticsController(
        api: api,
        probeInterval: Duration.zero,
      );
      addTearDown(() {
        model.dispose();
        api.close();
      });
      await model.start();
      expect(model.stage, NetworkTestStage.completed);
      expect(model.downloadSamples, hasLength(2));
      expect(model.uploadSamples, hasLength(2));
      expect(model.downloadMbps, greaterThan(0));
      expect(model.uploadMbps, greaterThan(0));
      expect(model.totalProbes, 13);
      expect(model.failedRequests, greaterThan(0));
      expect(model.failureRate, greaterThan(0));
      expect(model.progress, 1);
      expect(model.finishedAt, isNotNull);
    },
  );

  test(
    'stop cancels the experiment without committing a false result',
    () async {
      final api = _DiagnosticApi()..holdDownload = Completer<void>();
      final model = NetworkDiagnosticsController(
        api: api,
        probeInterval: Duration.zero,
      );
      addTearDown(() {
        model.dispose();
        api.close();
      });
      final running = model.start();
      while (model.stage != NetworkTestStage.download) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      model.stop();
      api.holdDownload!.complete();
      await running;
      expect(model.stage, NetworkTestStage.cancelled);
      expect(model.finishedAt, isNull);
      expect(api.uploadCount, 0);
    },
  );

  test(
    'continuous stability observation only probes and records failures',
    () async {
      final api = _DiagnosticApi()
        ..failSomePings = true
        ..emulateCoreRestart = true;
      final model = NetworkDiagnosticsController(
        api: api,
        probeInterval: Duration.zero,
        observationInterval: Duration.zero,
      );
      addTearDown(() {
        model.dispose();
        api.close();
      });
      model.selectMode(NetworkTestMode.observe);
      expect(model.mode.plannedTransferBytes, 0);
      await model.start();
      expect(model.stage, NetworkTestStage.completed);
      expect(model.totalProbes, 33);
      expect(model.successfulRequests + model.failedRequests, 33);
      expect(model.failedRequests, greaterThan(0));
      expect(model.longestFailureStreak, 1);
      expect(model.restartHints, 1);
      expect(model.coreUptimeSeconds, isNotNull);
      expect(model.successRate, greaterThan(0));
      expect(model.successRate, lessThan(100));
      expect(model.downloadMbps, isNull);
      expect(model.uploadMbps, isNull);
      expect(api.downloadCount, 0);
      expect(api.uploadCount, 0);
    },
  );

  for (final size in [const Size(360, 680), const Size(1180, 840)]) {
    testWidgets('native-style speedtest UI is responsive at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _DiagnosticApi();
      final model = NetworkDiagnosticsController(
        api: api,
        probeInterval: Duration.zero,
      );
      addTearDown(() {
        model.dispose();
        api.close();
      });
      final captureKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: const bool.fromEnvironment('LIGHTISLE_CAPTURE_NETWORK')
                ? buildIsleTheme(Brightness.light).copyWith(
                    textTheme: buildIsleTheme(Brightness.light).textTheme
                        .apply(fontFamily: 'IsleNetworkReviewBody'),
                  )
                : buildIsleTheme(Brightness.light),
            builder: (context, child) => IsleCanvas(child: child!),
            home: NetworkDiagnosticsPage(api: api, controller: model),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (const bool.fromEnvironment('LIGHTISLE_CAPTURE_NETWORK')) {
        final boundary =
            captureKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final directory = Directory('../../build/flutter-mobile-review');
          await directory.create(recursive: true);
          await File('${directory.path}/network-test-${size.width.toInt()}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(find.byKey(const ValueKey('networkTestGauge')), findsOneWidget);
      expect(find.text('持续观察'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('下载速度'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('下载速度'), findsWidgets);
      expect(find.text('延迟抖动'), findsWidgets);
      expect(tester.takeException(), isNull);
      await model.start();
      await tester.pumpAndSettle();
      expect(model.stage, NetworkTestStage.completed);
      expect(find.textContaining('Mbps'), findsWidgets);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('networkTestLatencyChart')),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.byKey(const ValueKey('networkTestLatencyChart')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
