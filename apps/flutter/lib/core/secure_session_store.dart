import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// One remembered account, protected by Keychain / Android Keystore.
/// Serializing mutations prevents an old sign-out from deleting a new login.
class SecureSessionStore {
  SecureSessionStore({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('lightisle/session-vault');
  final MethodChannel _channel;
  Future<void> _tail = Future<void>.value();

  Future<Map<String, dynamic>?> read() => _serialize(() async {
    final value = await _channel.invokeMethod<String>('read');
    if (value == null) return null;
    if (value.length > 8192) throw const FormatException('保存的登录状态无效。');
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('保存的登录状态无效。');
    }
    return decoded;
  });

  Future<void> write(Map<String, dynamic> snapshot) => _serialize(() async {
    final value = jsonEncode(snapshot);
    if (value.length > 8192) throw const FormatException('登录状态过大，无法保存。');
    await _channel.invokeMethod<void>('write', {'value': value});
  });

  Future<void> clear() =>
      _serialize(() => _channel.invokeMethod<void>('clear'));

  Future<T> _serialize<T>(Future<T> Function() operation) async {
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
}
