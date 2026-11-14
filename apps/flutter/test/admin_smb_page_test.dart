import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/settings/admin_smb_page.dart';

class _FakeSmbApi extends LightIsleApi {
  _FakeSmbApi() : super('http://127.0.0.1');

  bool serviceEnabled = true;
  final calls = <String>[];
  final shares = <Map<String, dynamic>>[
    {
      'recordName': 'Movies',
      'smbName': '家庭影院',
      'path': '/Volumes/NAS/Movies',
      'shared': true,
      'guestAccess': true,
      'readOnly': true,
      'sealed': false,
      'rootId': 'root-1',
      'rootName': '主存储盘',
      'exposesPersonalDirs': false,
      'pathExists': true,
    },
    {
      'recordName': 'bustv',
      'smbName': 'bustv',
      'path': '/Volumes/External/Download/bustv',
      'shared': true,
      'guestAccess': false,
      'readOnly': false,
      'sealed': false,
      'rootId': null,
      'rootName': null,
      'exposesPersonalDirs': false,
      'pathExists': true,
    },
  ];

  Map<String, dynamic> _snapshot() => {
    'serviceEnabled': serviceEnabled,
    'listening': serviceEnabled,
    'remoteManageReady': true,
    'computerName': 'Family Mac mini',
    'localHostName': 'Family-Mac-mini',
    'bonjourUrl': 'smb://Family-Mac-mini.local',
    'lanUrl': 'smb://192.168.1.88',
    'shares': List<Map<String, dynamic>>.from(shares),
    'candidateRoots': [
      {
        'rootId': 'root-1',
        'name': '主存储盘',
        'path': '/Volumes/NAS',
        'online': true,
        'subdirectories': ['Movies', 'Photos', 'Users'],
      },
    ],
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    calls.add('GET $path');
    if (path == '/api/v2/admin/smb') {
      return _snapshot();
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
    calls.add('$method $path');
    if (method == 'POST' && path == '/api/v2/admin/smb/service') {
      final map = body as Map<String, dynamic>;
      serviceEnabled = map['enabled'] == true;
      return _snapshot();
    }
    if (method == 'POST' && path == '/api/v2/admin/smb/shares') {
      final map = body as Map<String, dynamic>;
      final name = (map['smbName']?.toString() ?? '').isEmpty
          ? '主存储盘'
          : map['smbName'].toString();
      shares.add({
        'recordName': name,
        'smbName': name,
        'path': '/Volumes/NAS',
        'shared': true,
        'guestAccess': map['guestAccess'] == true,
        'readOnly': map['readOnly'] == true,
        'sealed': map['sealed'] == true,
        'rootId': 'root-1',
        'rootName': '主存储盘',
        'exposesPersonalDirs': true,
        'pathExists': true,
      });
      return _snapshot();
    }
    if (method == 'DELETE' && path == '/api/v2/admin/smb/shares/Movies') {
      shares.removeWhere((s) => s['recordName'] == 'Movies');
      return _snapshot();
    }
    throw StateError('unexpected $method $path');
  }
}

void main() {
  testWidgets('AdminSmbPage loads, toggles service, adds and removes shares', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _FakeSmbApi();
    addTearDown(api.close);

    await tester.pumpWidget(MaterialApp(home: AdminSmbPage(api: api)));
    await tester.pumpAndSettle();

    expect(api.calls, contains('GET /api/v2/admin/smb'));
    expect(find.text('smb://Family-Mac-mini.local'), findsOneWidget);
    expect(find.text('家庭影院'), findsOneWidget);

    // Toggle SMB service switch off
    await tester.tap(find.byKey(const ValueKey('smb-service-switch')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('POST /api/v2/admin/smb/service'));
    expect(api.serviceEnabled, isFalse);

    // Add a new share
    await tester.enterText(
      find.byKey(const ValueKey('smb-name-input')),
      '全家共享盘',
    );
    await tester.tap(find.byKey(const ValueKey('smb-add-button')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('POST /api/v2/admin/smb/shares'));
    expect(find.text('全家共享盘'), findsOneWidget);

    // Remove Movies share
    await tester.tap(find.byKey(const ValueKey('smb-remove-Movies')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除共享'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('DELETE /api/v2/admin/smb/shares/Movies'));
    expect(find.text('家庭影院'), findsNothing);

    // Unmanaged local share (rootId == null) is read-only remotely
    expect(find.text('本机其他共享（仅 Mac 端管理）'), findsOneWidget);
    final unmanagedRemove = tester.widget<TextButton>(
      find.byKey(const ValueKey('smb-remove-bustv')),
    );
    expect(unmanagedRemove.onPressed, isNull);
  });
}
