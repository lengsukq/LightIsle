import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lightisle/core/nas_discovery.dart';
import 'package:lightisle/features/auth/nas_discovery_picker.dart';

// Real Android/iOS NSD smoke: does not require a NAS, credentials or internet.
// A missing NAS must render an empty state, not terminate the app process.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('LAN discovery opens, completes or times out without a process crash',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: NasDiscoveryPicker(
        service: NasDiscoveryService(),
        onSelected: (_) {},
      )),
    ));
    final button = find.byKey(const Key('nasDiscoveryButton'));
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pump();
    expect(find.text('查找局域网 NAS'), findsWidgets);

    for (var attempt = 0; attempt < 135; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      if (find.text('正在搜索当前局域网…').evaluate().isEmpty) break;
    }

    expect(find.text('正在搜索当前局域网…'), findsNothing,
        reason: 'Native discovery must resolve with results or a safe timeout.');
    expect(find.byKey(const Key('nasDiscoveryCancel')), findsOneWidget);
  });
}
