import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/core/personal_storage_routing.dart';

void main() {
  const roots = [
    LightIsleRoot(id: 'a', name: '文件盘', generation: 2, online: true),
    LightIsleRoot(id: 'b', name: '照片盘', generation: 3, online: true),
    LightIsleRoot(id: 'c', name: '视频盘', generation: 4, online: true),
  ];
  final policy = <String, dynamic>{
    'userId': 7,
    'locations': [
      {
        'category': 'files',
        'rootID': 'a',
        'rootGeneration': 2,
        'relativePath': 'Users/u7/files',
      },
      {
        'category': 'photos',
        'rootID': 'b',
        'rootGeneration': 3,
        'relativePath': 'Users/u7/photos',
      },
      {
        'category': 'videos',
        'rootID': 'c',
        'rootGeneration': 4,
        'relativePath': 'Users/u7/videos',
      },
    ],
  };
  test('all personal categories resolve to their own bound disk', () {
    expect(resolvePersonalRoute(policy, roots, 'files').path, 'Users/u7/files');
    expect(resolvePersonalRoute(policy, roots, 'photos').root?.id, 'b');
    expect(resolvePersonalRoute(policy, roots, 'cinema').root?.id, 'c');
  });
  test('trusts custom server relativePath without hardcoding Users/uN layout', () {
    final customPolicy = <String, dynamic>{
      'userId': 7,
      'locations': [
        {
          'category': 'photos',
          'rootID': 'b',
          'rootGeneration': 3,
          'relativePath': 'Family/Alice/Photos',
        },
      ],
    };
    final route = resolvePersonalRoute(customPolicy, roots, 'photos');
    expect(route.kind, PersonalRouteKind.personal);
    expect(route.root?.id, 'b');
    expect(route.path, 'Family/Alice/Photos');
  });
  test('offline, replaced disks and forged paths fail closed', () {
    expect(
      resolvePersonalRoute(policy, roots.sublist(1), 'files').kind,
      PersonalRouteKind.offline,
    );
    expect(
      resolvePersonalRoute(policy, [
        const LightIsleRoot(id: 'a', name: 'new', generation: 3, online: true),
      ], 'files').kind,
      PersonalRouteKind.offline,
    );
    expect(
      resolvePersonalRoute({...policy, 'userId': 8}, roots, 'files').kind,
      PersonalRouteKind.offline,
    );
    expect(
      resolvePersonalRoute(
        {
          'userId': 7,
          'locations': [
            {
              'category': 'files',
              'rootID': 'a',
              'rootGeneration': 2,
              'relativePath': '../escape',
            },
          ],
        },
        roots,
        'files',
      ).kind,
      PersonalRouteKind.offline,
    );
  });
  test('no assignment retains manual shared root', () {
    expect(
      resolvePersonalRoute({'userId': 7, 'locations': []}, roots, 'files').kind,
      PersonalRouteKind.shared,
    );
    expect(
      resolvePersonalRoute(policy, roots, 'settings').kind,
      PersonalRouteKind.shared,
    );
  });
}
