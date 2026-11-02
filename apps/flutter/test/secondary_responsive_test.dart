import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/features/files/downloads_page.dart';
import 'package:lightisle/features/files/file_shares_page.dart';
import 'package:lightisle/features/overview/overview_page.dart';
import 'package:lightisle/features/settings/account_security_page.dart';
import 'package:lightisle/features/settings/admin_activity_page.dart';
import 'package:lightisle/features/settings/dav_page.dart';
import 'package:lightisle/features/settings/settings_page.dart';
import 'package:lightisle/features/settings/storage_page.dart';

import 'client_shell_test.dart' show FixtureApi;

void main() {
  final cases = <(String, Widget Function(FixtureApi))>[
    ('Downloads', (api) => DownloadsPage(api: api)),
    ('My shares', (api) => FileSharesPage(api: api)),
    ('Task history', (api) => TaskHistoryPage(api: api)),
    (
      'Account security',
      (api) => AccountSecurityPage(api: api, onSignedOut: () async {}),
    ),
    (
      'Admin alerts',
      (api) => AdminActivityPage(api: api, kind: AdminActivity.alerts),
    ),
    (
      'Admin audit',
      (api) => AdminActivityPage(api: api, kind: AdminActivity.audit),
    ),
    ('WebDAV', (api) => DavPage(api: api)),
    ('Accounts', (api) => AccountsPage(api: api, currentUsername: 'owner')),
    (
      'Grants',
      (api) => GrantsPage(
        api: api,
        user: const {
          'id': 8,
          'username': 'member',
          'role': 'member',
          'enabled': true,
        },
      ),
    ),
    ('Storage', (api) => StoragePage(api: api, isAdmin: true)),
    ('Upload maintenance', (api) => UploadMaintenancePage(api: api)),
  ];

  for (final (name, factory) in cases) {
    for (final (size, scale) in <(Size, double)>[
      (const Size(320, 568), 2),
      (const Size(1024, 700), 1),
    ]) {
      testWidgets('$name lays out at $size and text scale $scale', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final api = FixtureApi();
        addTearDown(api.close);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildIsleTheme(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: true,
              ),
              child: IsleCanvas(child: child!),
            ),
            home: factory(api),
          ),
        );
        await tester.pump(const Duration(milliseconds: 450));
        expect(
          tester.takeException(),
          isNull,
          reason: '$name at $size, $scale',
        );
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
