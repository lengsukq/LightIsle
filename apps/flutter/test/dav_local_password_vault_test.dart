import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/features/settings/dav_local_password_vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('DAV device vault isolates accounts and serializes updates', () async {
    const channel = MethodChannel('lightisle/dav-local-test');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? sealed;
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      switch (call.method) {
        case 'dav.read':
          return sealed;
        case 'dav.write':
          sealed = (call.arguments as Map)['value'] as String;
          return null;
        case 'dav.clear':
          sealed = null;
          return null;
        default:
          throw PlatformException(code: 'unexpected_method');
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final vault = DavLocalPasswordVault(channel: channel);
    final alice = DavLocalPasswordVault.scope('https://nas.example', '1');
    final bob = DavLocalPasswordVault.scope('https://nas.example', '2');
    final anotherNas = DavLocalPasswordVault.scope(
      'https://other.example',
      '1',
    );
    expect(alice, isNot(bob));
    expect(alice, isNot(anotherNas));
    expect(DavLocalPasswordVault.revision('alice-secret'), hasLength(24));
    expect(
      DavLocalPasswordVault.revision('alice-secret'),
      isNot(DavLocalPasswordVault.revision('bob-secret')),
    );

    await Future.wait([
      vault.write(alice, 7, 'alice-secret'),
      vault.write(bob, 7, 'bob-secret'),
    ]);
    expect(await vault.read(alice, 7), 'alice-secret');
    expect(await vault.read(bob, 7), 'bob-secret');
    expect(await vault.read(anotherNas, 7), isNull);
    await vault.prune(alice, <int>{});
    expect(await vault.read(alice, 7), isNull);
    expect(await vault.read(bob, 7), 'bob-secret');
    await vault.remove(bob, 7);
    expect(sealed, isNull);
    expect(methods, contains('dav.clear'));
  });

  test(
    'DAV vault rejects malformed secrets rather than inventing values',
    () async {
      const channel = MethodChannel('lightisle/dav-broken-test');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async => '{not-json');
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final vault = DavLocalPasswordVault(channel: channel);
      await expectLater(vault.read('scope', 1), throwsFormatException);
      await expectLater(vault.write('scope', 0, 'secret'), throwsArgumentError);
    },
  );
}
