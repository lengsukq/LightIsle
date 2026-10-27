import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Serializes the foreground session changes used to authorize Android's
/// background photo worker. Credentials never leave the method-channel call.
class BackgroundPhotoBackupSession {
  BackgroundPhotoBackupSession({MethodChannel? channel, bool? enabled})
    : _channel = channel ?? const MethodChannel('lightisle/photos-background'),
      _enabled = enabled ?? defaultTargetPlatform == TargetPlatform.android;

  final MethodChannel _channel;
  final bool _enabled;
  String? _activeToken;
  Future<void> _tail = Future<void>.value();

  String? get activeToken => _activeToken;

  Future<String?> replaceSession({
    required String server,
    required String cookie,
    required String username,
  }) async {
    if (!_enabled) return null;
    if (server.isEmpty || cookie.isEmpty || username.trim().isEmpty) {
      throw StateError('无法绑定当前账号的后台备份会话。');
    }
    return _serialize(() async {
      final previous = _activeToken;
      if (previous != null) {
        await _channel.invokeMethod<void>('endSession', {'token': previous});
        _activeToken = null;
      }
      final token = _newToken();
      await _channel.invokeMethod<void>('bindSession', {
        'token': token,
        'server': server,
        'cookie': cookie,
        'username': username,
      });
      _activeToken = token;
      return token;
    });
  }

  /// A stale token is safe to end: native code only clears the matching active
  /// token, and this coordinator only clears its own matching token.
  Future<void> end(String token) async {
    if (!_enabled) return;
    await _serialize(() async {
      await _channel.invokeMethod<void>('endSession', {'token': token});
      if (_activeToken == token) _activeToken = null;
    });
  }

  Future<void> endCurrent() async {
    final token = _activeToken;
    if (token != null) await end(token);
  }

  /// Explicit local sign-out/account switch must also revoke a persisted
  /// background worker from a previous process. Its old in-memory token may
  /// no longer exist after Android killed and recreated the Flutter engine.
  Future<void> forgetLocalSession() async {
    if (!_enabled) return;
    await _serialize(() async {
      await _channel.invokeMethod<void>('forgetSession');
      _activeToken = null;
    });
  }

  Future<T> _serialize<T>(Future<T> Function() operation) async {
    final previous = _tail;
    final completed = Completer<void>();
    _tail = completed.future;
    try {
      await previous;
      return await operation();
    } finally {
      completed.complete();
    }
  }

  String _newToken() {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final value = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${value.substring(0, 8)}-${value.substring(8, 12)}-'
        '${value.substring(12, 16)}-${value.substring(16, 20)}-'
        '${value.substring(20)}';
  }
}
