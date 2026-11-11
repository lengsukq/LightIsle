import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/overview/overview_page.dart';
import 'package:lightisle/features/shell/client_shell.dart';
import 'package:lightisle/features/overview/storage_volume_browser.dart';

import 'client_shell_test.dart' show FixtureApi;

class _StorageBrowserApi extends FixtureApi {
  final opened = <(String?, String)>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    switch (path) {
      case '/api/v2/system':
        return {
          'hostname': 'Mac',
          'architecture': 'arm64',
          'cpuCount': 8,
          'cpuPercent': 5,
          'memoryTotal': 16 * 1024 * 1024 * 1024,
          'memoryUsed': 8 * 1024 * 1024 * 1024,
          'diskTotal': 10000000000,
          'diskFree': 5000000000,
          'volumes': [
            {
              'name': 'Macintosh HD',
              'mount': '/',
              'total': 10000000000,
              'free': 5000000000,
              'filesystem': 'apfs',
              'readOnly': true,
            },
            {
              'name': 'lightIsle',
              'mount': '/Volumes/lightIsle',
              'total': 10000000000,
              'free': 8000000000,
              'filesystem': 'exfat',
              'readOnly': false,
            },
            {
              'name': 'Recovery',
              'mount': '/Volumes/Recovery',
              'total': 10000000000,
              'free': 4000000000,
              'filesystem': 'apfs',
              'readOnly': true,
            },
          ],
        };
      case '/api/v2/roots':
        return {
          'roots': [
            {
              'rootID': 'root-a',
              'name': '家庭资料',
              'generation': 3,
              'online': true,
              'volumeMount': '/Volumes/lightIsle',
            },
            {
              'rootID': 'root-b',
              'name': '未分配给当前用户',
              'generation': 3,
              'online': true,
              'volumeMount': '/Volumes/another',
            },
          ],
        };
      case '/api/v2/me/storage':
        return {
          'userId': 7,
          'locations': [
            {
              'category': 'photos',
              'rootID': 'root-a',
              'rootGeneration': 3,
              'relativePath': 'Users/u7/photos',
            },
          ],
          'rootQuotas': [],
          'usageComplete': true,
        };
      case '/api/v2/files':
        opened.add((selectedRoot?.id, query?['path'] ?? '.'));
        return {'entries': [], 'nextCursor': '', 'canWrite': false};
      default:
        return super.get(path, query: query);
    }
  }
}

void main() {
  for (final size in [const Size(360, 700), const Size(1200, 820)]) {
    testWidgets('admin volume browser opens registered NAS root at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _StorageBrowserApi();
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: ClientShell(
            api: api,
            identity: const {'username': 'admin', 'role': 'admin'},
            onLogout: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scrollable = find
          .descendant(
            of: find.byType(OverviewPage),
            matching: find.byType(Scrollable),
          )
          .first;
      final macCard = find.byKey(const ValueKey('physicalVolume:/'));
      final isleCard = find.byKey(
        const ValueKey('physicalVolume:/Volumes/lightIsle'),
      );
      await tester.scrollUntilVisible(macCard, 100, scrollable: scrollable);
      await tester.pumpAndSettle();
      expect(macCard, findsOneWidget);
      expect(isleCard, findsOneWidget);
      if (size.width >= 1000) {
        // Wide screen: 2-column layout side-by-side
        expect(
          tester.getTopLeft(macCard).dy,
          equals(tester.getTopLeft(isleCard).dy),
        );
        expect(
          tester.getTopLeft(isleCard).dx,
          greaterThan(tester.getTopLeft(macCard).dx),
        );
      } else {
        // Narrow screen: single column vertically stacked
        expect(
          tester.getTopLeft(macCard).dx,
          equals(tester.getTopLeft(isleCard).dx),
        );
        expect(
          tester.getTopLeft(isleCard).dy,
          greaterThan(tester.getTopLeft(macCard).dy),
        );
      }
      await tester.scrollUntilVisible(
        find.text('浏览文件'),
        200,
        scrollable: scrollable,
      );
      await tester.ensureVisible(find.text('浏览文件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('浏览文件'));
      await tester.pumpAndSettle();
      expect(api.selectedRoot?.id, 'root-a');
      expect(api.opened, contains(('root-a', '.')));
      expect(tester.takeException(), isNull);
    });

    testWidgets('member only browses assigned directory at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _StorageBrowserApi();
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: ClientShell(
            api: api,
            identity: const {'username': 'member', 'role': 'member'},
            onLogout: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AdminVolumeBrowser), findsNothing);
      expect(find.byKey(const ValueKey('shellRootPicker')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('shellRootPickerSurface')));
      await tester.pumpAndSettle();
      expect(find.text('未分配给当前用户'), findsNothing);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      final scrollable = find
          .descendant(
            of: find.byType(OverviewPage),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('memberStorage:photos')),
        160,
        scrollable: scrollable,
      );
      await tester.tap(find.byKey(const ValueKey('memberStorage:photos')));
      await tester.pumpAndSettle();
      expect(api.selectedRoot?.id, 'root-a');
      expect(api.opened, contains(('root-a', 'Users/u7/photos')));
      expect(api.opened, isNot(contains(('root-a', '.'))));
      expect(api.opened, isNot(contains(('root-b', '.'))));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('member rejects a stale or unallocated root', (tester) async {
    final api = _StorageBrowserApi();
    addTearDown(api.close);
    final storage = await api.get('/api/v2/me/storage');
    final roots = [
      const LightIsleRoot(
        id: 'root-a',
        name: '家庭资料',
        generation: 4,
        online: true,
      ),
      const LightIsleRoot(
        id: 'root-b',
        name: '未分配',
        generation: 3,
        online: true,
      ),
    ];
    final seen = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MemberStorageBrowser(
            storage: storage,
            roots: roots,
            onOpen: (_, path) => seen.add(path),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('存储位置离线或绑定尚未验证'), findsOneWidget);
    expect(
      tester
          .widget<ListTile>(find.byKey(const ValueKey('memberStorage:photos')))
          .onTap,
      isNull,
    );
    expect(seen, isEmpty);
  });
}
