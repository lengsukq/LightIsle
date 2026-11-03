import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// Passwords created *on this device* may be re-shown from Keychain/Keystore.
/// The NAS itself only retains SHA-256 digests. This does not migrate secrets
/// from a different device or recover passwords created before this feature.
class DavLocalPasswordVault {
  DavLocalPasswordVault({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('lightisle/session-vault');

  final MethodChannel _channel;
  Future<void> _tail = Future<void>.value();

  static String scope(String origin, String accountId) =>
      sha256.convert(utf8.encode('$origin|$accountId')).toString();

  /// Match the digest-derived, non-reversible version sent by the NAS.
  /// Rotation on a different device invalidates any stale local copy.
  static String revision(String password) {
    final digest = sha256.convert(utf8.encode(password)).bytes;
    final tag = sha256.convert(digest).bytes.take(12);
    return tag.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<T> _serial<T>(Future<T> Function() operation) async {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    try {
      await previous;
      return await operation();
    } finally {
      done.complete();
    }
  }

  Future<Map<String, String>> _readAll() async {
    final raw = await _channel.invokeMethod<String>('dav.read');
    if (raw == null || raw.isEmpty) return {};
    if (raw.length > 8192) throw const FormatException('本机安全密码库无效');
    final parsed = jsonDecode(raw);
    if (parsed is! Map) throw const FormatException('本机安全密码库无效');
    final values = <String, String>{};
    parsed.forEach((key, value) {
      if (key is String && value is String) values[key] = value;
    });
    return values;
  }

  Future<void> _writeAll(Map<String, String> values) async {
    if (values.isEmpty) {
      await _channel.invokeMethod<void>('dav.clear');
      return;
    }
    final encoded = jsonEncode(values);
    if (encoded.length > 8192) {
      throw const FormatException('本机 WebDAV 密码库已满');
    }
    await _channel.invokeMethod<void>('dav.write', {'value': encoded});
  }

  String _key(String accountScope, int credentialId) =>
      '$accountScope:$credentialId';

  Future<String?> read(String accountScope, int credentialId) =>
      _serial(() async {
        final all = await _readAll();
        return all[_key(accountScope, credentialId)];
      });

  Future<void> write(String accountScope, int credentialId, String password) =>
      _serial(() async {
        if (credentialId <= 0 || password.isEmpty || password.length > 128) {
          throw ArgumentError('WebDAV 密码无效');
        }
        final all = await _readAll();
        all[_key(accountScope, credentialId)] = password;
        await _writeAll(all);
      });

  Future<void> remove(String accountScope, int credentialId) =>
      _serial(() async {
        final all = await _readAll();
        all.remove(_key(accountScope, credentialId));
        await _writeAll(all);
      });

  /// Remove locally cached secrets for revoked server credentials.
  Future<void> prune(String accountScope, Set<int> activeIds) =>
      _serial(() async {
        final all = await _readAll();
        all.removeWhere((key, _) {
          if (!key.startsWith('$accountScope:')) return false;
          final id = int.tryParse(key.substring(accountScope.length + 1));
          return id == null || !activeIds.contains(id);
        });
        await _writeAll(all);
      });
}
