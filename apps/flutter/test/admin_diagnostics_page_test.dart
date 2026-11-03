import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/settings/admin_diagnostics_page.dart';

class _AdminDiagnosticsApi extends LightIsleApi {
  _AdminDiagnosticsApi() : super('http://127.0.0.1');
  final paths = <String>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    paths.add(path);
    switch (path) {
      case '/api/v2/system/history':
        return {
          'samples': [
            {'cpuPercent': 18.5, 'memoryPercent': 34, 'diskPercent': 47},
          ],
        };
      case '/api/v2/system/diagnostics':
        return {
          'requestTransport': 'HTTPS（当前请求已使用 TLS）',
          'gatewayIPv4': '192.168.1.1',
          'defaultInterface': 'en0',
          'interfaces': [
            {
              'name': 'en0',
              'up': true,
              'addresses': ['192.168.1.30'],
            },
          ],
        };
      case '/api/v2/admin/disks':
        return {
          'disks': [
            {
              'id': 'disk5s1',
              'name': 'Backup',
              'external': true,
              'mounted': true,
              'filesystem': 'apfs',
              'readOnly': false,
              'total': 1073741824,
              'free': 536870912,
            },
          ],
        };
      case '/api/v2/map/status':
        return {'tiandituConfigured': true};
      case '/api/v2/cinema/scrape/status':
        return {'tmdbConfigured': true};
      case '/api/v2/admin/disks/disk5s1/smart':
        return {
          'report': {'source': 'none', 'reason': 'smartctl_not_installed'},
          'risk': 'unknown',
        };
    }
    throw StateError('unexpected request $path');
  }
}

void main() {
  for (final size in [const Size(320, 640), const Size(1100, 800)]) {
    testWidgets('admin read-only diagnostics are usable at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _AdminDiagnosticsApi();
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(home: AdminDiagnosticsPage(api: api)),
      );
      await tester.pumpAndSettle();
      expect(api.paths, contains('/api/v2/system/history'));
      expect(api.paths, contains('/api/v2/system/diagnostics'));
      expect(api.paths, contains('/api/v2/admin/disks'));
      expect(api.paths, contains('/api/v2/map/status'));
      expect(api.paths, contains('/api/v2/cinema/scrape/status'));
      expect(find.text('设备诊断'), findsWidgets);
      expect(find.text('18.5%'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('检查 SMART'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('检查 SMART'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('检查 SMART'));
      await tester.pumpAndSettle();
      expect(api.paths, contains('/api/v2/admin/disks/disk5s1/smart'));
      expect(find.text('Mac 未安装 smartmontools'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('第三方服务 Key 状态'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('已配置并由 Mac Core 接收'), findsNWidgets(2));
      expect(api.paths.where((path) => path.contains('/actions')), isEmpty);
    });
  }
}
