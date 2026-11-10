import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/settings/storage_page.dart';

class _MultiDiskStorageApi extends LightIsleApi {
  _MultiDiskStorageApi({
    this.legacyRemoved = false,
    this.driveTwoOnline = false,
    this.requireSwitchStepUp = false,
    this.secondUserFails = false,
  }) : super('http://127.0.0.1');
  final bool legacyRemoved;
  final bool driveTwoOnline;
  final bool requireSwitchStepUp;
  final bool secondUserFails;
  Map<String, dynamic>? lastQuotaWrite;
  Map<String, dynamic>? lastAbandonRequest;
  Map<String, dynamic>? lastAllocationRequest;
  final List<Map<String, dynamic>> switchRequests = [];
  String? lastAssignedCategoryPath;
  Map<String, String>? lastUsageQuery;
  bool abandoned = false;
  bool videosAdded = false;
  bool failNextPolicyRead = false;
  String filesRootID = 'drive-one';
  int filesRootGen = 3;
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
          if (secondUserFails) {'id': 8, 'username': '长辈'},
        ],
      };
    }
    if (path == '/api/v2/users/8/storage') {
      throw StateError('读取长辈空间超时');
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
            'rootID': filesRootID,
            'rootGeneration': filesRootGen,
            'relativePath': 'Users/u7/files',
          },
          {
            'category': 'photos',
            'rootID': 'drive-two',
            'rootGeneration': 6,
            'relativePath': 'Users/u7/photos',
          },
          if (videosAdded)
            {
              'category': 'videos',
              'rootID': 'drive-one',
              'rootGeneration': 3,
              'relativePath': 'Users/u7/videos',
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
            'online': driveTwoOnline,
            if (driveTwoOnline) 'filesystemTotalBytes': 500 * (1 << 30),
            if (driveTwoOnline) 'filesystemAvailableBytes': 400 * (1 << 30),
          },
        ],
      };
    }
    throw StateError('unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> assignStorageRoot(
    String path,
    int rootGeneration,
  ) async {
    lastAssignedCategoryPath = '$path@$rootGeneration';
    videosAdded = true;
    return {'ok': true};
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
    if (method == 'POST' &&
        path == '/api/v2/roots/drive-one/users/7/storage') {
      lastAllocationRequest = {
        ...Map<String, dynamic>.from(body! as Map),
        'query': query,
      };
      if (lastAllocationRequest!['quotaBytes'] is num) {
        diskAQuota = (lastAllocationRequest!['quotaBytes'] as num).toInt();
      }
      final cats = lastAllocationRequest!['categories'];
      if (cats is List && cats.contains('videos')) {
        videosAdded = true;
      }
      return {'policy': await get('/api/v2/users/7/storage')};
    }
    if (method == 'POST' && path == '/api/v2/users/7/storage/switch-root') {
      final req = Map<String, dynamic>.from(body! as Map);
      switchRequests.add(req);
      if (requireSwitchStepUp && req['phase'] != 'status') {
        final pass = req['confirmationPassword']?.toString() ?? '';
        final token = req['confirmationToken']?.toString() ?? '';
        if (pass != 'admin-secret-123' && token != 'step-up-token-abc') {
          throw const LightIsleApiException(
            code: 'admin_confirmation_required',
            message: '需要管理员密码确认',
            statusCode: 403,
          );
        }
      }
      if (req['phase'] == 'copy_and_verify') {
        return {
          'taskID': req['taskID'],
          'phase': 'queued',
          'mode': 'migrate',
          if (requireSwitchStepUp) 'confirmationToken': 'step-up-token-abc',
        };
      }
      if (req['phase'] == 'status') {
        return {
          'taskID': req['taskID'],
          'phase': 'verified',
          'mode': 'migrate',
          'verifiedFiles': 3,
          'totalFiles': 3,
          'copiedBytes': 1024,
          'totalBytes': 1024,
        };
      }
      final start = switchRequests.firstWhere(
        (r) => r['phase'] == 'copy_and_verify',
      );
      filesRootID = start['targetRootID'].toString();
      filesRootGen = (start['targetGeneration'] as num).toInt();
      return {
        'taskID': req['taskID'],
        'phase': 'completed',
        'mode': 'migrate',
        'policy': await get('/api/v2/users/7/storage'),
      };
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

  testWidgets(
    'administrator allocates space with quota and adds directories or subdirectories',
    (tester) async {
      final api = _MultiDiskStorageApi();
      addTearDown(api.close);
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(home: StoragePage(api: api, isAdmin: true)),
      );
      await tester.pumpAndSettle();

      // 1. Add unassigned category ('视频') directly onto an allocated online disk.
      expect(find.text('+ 添加视频目录'), findsOneWidget);
      await tester.tap(find.text('+ 添加视频目录'));
      await tester.pumpAndSettle();
      expect(
        api.lastAssignedCategoryPath,
        '/api/v2/roots/drive-one/users/7/storage/videos@3',
      );

      // 2. Allocate space & configure quota via '分配空间与限额' dialog with 200 GiB preset.
      await tester.tap(find.text('分配空间与限额'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ActionChip, '200 GiB'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '确认分配'));
      await tester.pumpAndSettle();
      expect(api.lastAllocationRequest?['quotaBytes'], 200 * (1 << 30));
      expect(find.textContaining('家庭文件盘 · 200 GiB'), findsOneWidget);

      // 3. Create a custom subdirectory on the allocated disk.
      await tester.tap(find.text('+ 新建子目录'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'files/家庭文档');
      await tester.tap(find.widgetWithText(FilledButton, '创建'));
      await tester.pumpAndSettle();
      expect(api.lastAllocationRequest?['subdirectories'], ['files/家庭文档']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'administrator switches category root across disks with two-phase migrate',
    (tester) async {
      final api = _MultiDiskStorageApi(driveTwoOnline: true);
      addTearDown(api.close);
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(home: StoragePage(api: api, isAdmin: true)),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextButton, '更换硬盘'), findsWidgets);
      await tester.tap(find.widgetWithText(TextButton, '更换硬盘').first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('复制并核验后删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '开始复制并核验'));
      await tester.pump();
      for (var frame = 0;
          frame < 6 && find.text('已核验，确认切换硬盘？').evaluate().isEmpty;
          frame++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pump(const Duration(milliseconds: 300));

      expect(api.switchRequests.length, 2);
      expect(api.switchRequests.first['mode'], 'migrate');
      expect(api.switchRequests.first['phase'], 'copy_and_verify');
      expect(find.text('已核验，确认切换硬盘？'), findsOneWidget);

      await tester.tap(find.text('确认切换并回收源文件'));
      await tester.pumpAndSettle();

      expect(api.switchRequests.length, 3);
      expect(api.switchRequests.last['phase'], 'confirm_cleanup');
      expect(api.switchRequests.last['taskID'], api.switchRequests.first['taskID']);
      expect(find.text('已切换到目标盘，源文件可在旧盘的回收站恢复。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'step-up confirmation token from copy_and_verify avoids second password prompt on confirm_cleanup',
    (tester) async {
      final api = _MultiDiskStorageApi(
        driveTwoOnline: true,
        requireSwitchStepUp: true,
      );
      addTearDown(api.close);
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(home: StoragePage(api: api, isAdmin: true)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, '更换硬盘').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '开始复制并核验'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // Prompted once for admin password on copy_and_verify
      expect(find.text('管理员身份确认'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'admin-secret-123');
      await tester.tap(find.widgetWithText(FilledButton, '确认'));
      await tester.pump();
      for (var frame = 0;
          frame < 6 && find.text('已核验，确认切换硬盘？').evaluate().isEmpty;
          frame++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('已核验，确认切换硬盘？'), findsOneWidget);

      // Tapping confirm_cleanup reuses confirmationToken without a 2nd password prompt
      await tester.tap(find.text('确认切换并回收源文件'));
      await tester.pumpAndSettle();
      expect(find.text('管理员身份确认'), findsNothing);
      expect(api.switchRequests.last['confirmationToken'], 'step-up-token-abc');
      expect(find.text('已切换到目标盘，源文件可在旧盘的回收站恢复。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'single user policy failure isolates error card without failing healthy users or rootsKnown',
    (tester) async {
      final api = _MultiDiskStorageApi(secondUserFails: true);
      addTearDown(api.close);
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(home: StoragePage(api: api, isAdmin: true)),
      );
      await tester.pumpAndSettle();

      // Healthy user #7 still renders with verified roots (can adjust quota)
      expect(find.textContaining('家庭文件盘 · 100 GiB'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '调整额度'), findsWidgets);
      // Failed user #8 renders an isolated error notice
      expect(find.textContaining('该成员空间信息读取失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
