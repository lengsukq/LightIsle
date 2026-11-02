import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Coordinates Android Picture-in-Picture across stacked player routes.
///
/// The Android Activity exposes a single method-channel handler. A gallery,
/// local file or cinema page must not clear the previous route's handler when
/// popped. Only the top-most registered session receives native state events.
class AndroidPipSession {
  AndroidPipSession({
    required this.onChanged,
    required this.onTimeout,
    required this.onError,
    required this.onExit,
  });

  static const MethodChannel _channel = MethodChannel('lightisle/pip');
  static final List<AndroidPipSession> _sessions = [];

  final VoidCallback onChanged;
  final VoidCallback onTimeout;
  final void Function(Object? error) onError;
  final VoidCallback onExit;

  Timer? _watchdog;
  bool _registered = false;
  bool _disposed = false;
  bool supported = false;
  bool requested = false;
  bool active = false;

  bool get allowsBackgroundPlayback => requested || active;

  void attach() {
    if (_disposed ||
        _registered ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    _registered = true;
    _sessions.add(this);
    if (_sessions.length == 1) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'state' && _sessions.isNotEmpty) {
          _sessions.last._applyState(call.arguments == true);
        }
      });
    }
    unawaited(_checkSupport());
  }

  Future<void> _checkSupport() async {
    try {
      final available = await _channel.invokeMethod<bool>('supported');
      if (!_disposed && _registered) {
        supported = available == true;
        onChanged();
      }
    } on MissingPluginException {
      // Older native versions use normal foreground video playback.
    } on PlatformException {
      // PiP is optional and must never block the video page itself.
    }
  }

  void _applyState(bool value) {
    if (_disposed) return;
    _watchdog?.cancel();
    active = value;
    requested = value;
    onChanged();
    if (!value) onExit();
  }

  Future<void> enter() async {
    if (_disposed || !_registered || !supported) return;
    requested = true;
    onChanged();
    _watchdog?.cancel();
    _watchdog = Timer(const Duration(seconds: 4), () {
      if (!_disposed && requested && !active) {
        requested = false;
        onChanged();
        onTimeout();
      }
    });
    try {
      final result = await _channel.invokeMethod<bool>('enter');
      if (result != true && !_disposed) _reject(null);
    } catch (error) {
      if (!_disposed) _reject(error);
    }
  }

  void _reject(Object? error) {
    _watchdog?.cancel();
    requested = false;
    onChanged();
    onError(error);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _watchdog?.cancel();
    if (_registered) {
      _sessions.remove(this);
      _registered = false;
      if (_sessions.isEmpty) _channel.setMethodCallHandler(null);
    }
  }
}
