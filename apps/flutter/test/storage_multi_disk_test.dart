import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/settings/storage_page.dart';

class _MultiDiskStorageApi extends LightIsleApi {
  _MultiDiskStorageApi({this.legacyRemoved = false})
    : super('http://127.0.0.1');
  final bool legacyRemoved;
  Map<String, dynamic>? lastQuotaWrite;
  Map<String, dynamic>? lastAbandonRequest;
  Map<String, String>? lastUsageQuery;
  bool abandoned = false;
  bool failNextPolicyRead = false;
  int diskAQuota = 100 * (1 << 30);

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/roots/drive-one/storage/users/7/usage-check') {
      lastUsageQuery = query;
      return {
        'rootID': 'drive-one',
        'rootGeneration': 3,
        'liveBytes': 12 * (1 << 30),
        'entriesChecked': 8,
      };
    }
    if (path == '/api/v2/users') {
      return {
        'users': [
          {'id': 7, 'username': '家人'},
        ],
      };
    }
    if (path == '/api/v2/me/storage' || path == '/api/v2/users/7/storage') {
      if (failNextPolicyRead) {
        failNextPolicyRead = false;
        throw StateError('NAS 网络已断开');
      }
      return {
        'userId': 7,
        'quotaBytes': null,
        'accountedBytes': 10 * (1 << 30),
        'reservedBytes': 0,
        'enforcement': 'pending',
        'rootQuotas': [
          {
            'rootID': 'drive-one',
            'rootGeneration': 3,
            'quotaBytes': diskAQuota,
            'accountedBytes': 10 * (1 << 30),
            'reservedBytes': 0,
          },
          {
            'rootID': 'drive-two',
            'rootGeneration': 6,
            'quotaBytes': 100 * (1 << 30),
            'accountedBytes': 20 * (1 << 30),
            'reservedBytes': 5 * (1 << 30),
          },
        ],
        'locations': [
          {
            'category': 'files',
            'rootID': 'drive-one',
            'rootGeneration': 3,
            'relativePath': 'Users/u7/files',
          },
          {
            'category': 'photos',
            'rootID': 'drive-two',
            'rootGeneration': 6,
            'relativePath': 'Users/u7/photos',
          },
          if (legacyRemoved && !abandoned)
            {
              'category': 'videos',
              'rootID': 'drive-legacy',
              'rootGeneration': 4,
              'relativePath': 'Users/u7/videos',
            },
        ],
      };
    }
    if (path == '/api/v2/roots') {
      return {
        'roots': [
          {
            'rootID': 'drive-one',
            'name': '家庭文件盘',
            'generation': 3,
            'online': true,
            'filesystemTotalBytes': 200 * (1 << 30),
            'filesystemAvailableBytes': 75 * (1 << 30),
            'capacityScope': 'underlying_filesystem_shared',
          },
          {
            'rootID': 'drive-two',
            'name': '照片存储盘',
            'generation': 6,
            'online': false,
          },
        ],
      };
    }
    throw StateError('unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    if (method == 'POST' &&
        path == '/api/v2/storage/users/7/categories/videos/abandon') {
      lastAbandonRequest = Map<String, dynamic>.from(body! as Map);
      abandoned = true;
      return get('/api/v2/users/7/storage');
    }
    expect(method, 'PUT');
    expect(path, '/api/v2/users/7/storage/roots/drive-one/quota');
    lastQuotaWrite = Map<String, dynamic>.from(body! as Map);
    diskAQuota = (lastQuotaWrite!['quotaBytes'] as num).toInt();
    return get('/api/v2/users/7/storage');
  }
}

void main() {
  testWidgets('family member sees own disk availability and offline category', (
    tester,
  ) async {
    final api = _MultiDiskStorageApi();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(home: StoragePage(api: api, isAdmin: false)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('已登记的存储位置'), findsOneWidget);
    expect(find.textContaining('磁盘可用 75.0 / 200.0 GiB'), findsWidgets);
    expect(find.textContaining('照片存储盘 · 离线'), findsOneWidget);
    expect(find.textContaining('家庭文件盘 · 100 GiB'), findsOneWidget);
    expect(find.textContaining('照片存储盘 · 100 GiB'), findsOneWidget);
    expect(find.textContaining('额度剩余 90.00 GiB'), findsOneWidget);
    expect(find.textContaining('额度剩余 75.00 GiB'), findsOneWidget);
    expect(find.textContaining('总配额'), findsNothing);
    expect(find.textContaining('尚未计费'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('administrator edits only the selected disk quota', (
    tester,
  ) async {
    final api = _MultiDiskStorageApi();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(home: StoragePage(api: api, isAdmin: true)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '调整额度').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('设置 家庭文件盘 的专属额度'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '60');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(api.lastQuotaWrite, {'quotaBytes': 60 * (1 << 30), 'generation': 3});
    expect(find.textContaining('家庭文件盘 · 60 GiB'), findsOneWidget);
    expect(find.textContaining('照片存储盘 · 100 GiB'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed refresh preserves last known per-disk quotas', (
    tester,
  ) async {
    final api = _MultiDiskStorageApi();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(home: StoragePage(api: api, isAdmin: true)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('家庭文件盘 · 100 GiB'), findsOneWidget);
    api.failNextPolicyRead = true;
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(find.textContaining('保留上次成功读取的信息'), findsOneWidget);
    expect(find.textContaining('家庭文件盘 · 100 GiB'), findsOneWidget);
    expect(find.textContaining('硬盘状态未核实'), findsWidgets);
    expect(find.widgetWithText(TextButton, '调整额度'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'abandoning a removed disk sends bound identity and confirmation',
    (tester) async {
      final api = _MultiDiskStorageApi(legacyRemoved: true);
      addTearDown(api.close);
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(home: StoragePage(api: api, isAdmin: true)),
      );
      await tester.pumpAndSettle();
      expect(find.text('放弃旧空间并重建'), findsOneWidget);
      await tester.tap(find.text('放弃旧空间并重建'));
      await tester.pumpAndSettle();
      expect(api.lastAbandonRequest, isNull);
      await tester.tap(find.text('确认放弃旧绑定'));
      await tester.pumpAndSettle();
      expect(api.lastAbandonRequest, {
        'rootID': 'drive-legacy',
        'generation': 4,
        'confirm': true,
      });
      expect(find.text('已解除旧分类绑定，原硬盘文件未删除。现在可以分配新的空白目录。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'online usage check pins root generation and reports offline disk',
    (tester) async {
      final api = _MultiDiskStorageApi();
      addTearDown(api.close);
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(home: StoragePage(api: api, isAdmin: true)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('核对在线文件占用'));
      await tester.pumpAndSettle();
      expect(api.lastUsageQuery, {'rootGeneration': '3'});
      expect(find.textContaining('未能检查：照片存储盘，结果不完整'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
