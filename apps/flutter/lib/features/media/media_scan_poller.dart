import 'dart:async';

import 'media_models.dart';

/// Owns the scan-progress polling lifecycle shared by the photo and film
/// screens. The screens retain responsibility for their individual refreshes
/// and for rejecting stale HTTP responses.
class MediaScanPoller {
  MediaScanPoller({
    required this.onPoll,
    this.interval = const Duration(seconds: 3),
  });

  final void Function() onPoll;
  final Duration interval;
  Timer? _timer;
  bool _active = false;
  bool _scanning = false;
  bool _wasScanning = false;
  int _lastDone = 0;
  bool _disposed = false;

  bool get active => _active;
  bool get polling => _timer?.isActive ?? false;

  /// Returns true only on an actual visibility/lifecycle transition.
  bool setActive(bool value) {
    if (_disposed || _active == value) return false;
    _active = value;
    _syncTimer();
    return true;
  }

  /// Track scan completion independently of the current visible page.
  /// Returns true when the index should be reloaded.
  bool observe(MediaScanStatus status) {
    if (_disposed) return false;
    final completed =
        (_wasScanning && !status.running) ||
        (status.lastDone > 0 && status.lastDone > _lastDone);
    _wasScanning = status.running;
    _scanning = status.running || (status.aiRunning && !status.aiPaused);
    if (status.lastDone > _lastDone) _lastDone = status.lastDone;
    _syncTimer();
    return completed;
  }

  void _syncTimer() {
    if (_disposed || !_active || !_scanning) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(interval, (_) {
      if (!_disposed && _active && _scanning) onPoll();
    });
  }

  void dispose() {
    _disposed = true;
    _active = false;
    _timer?.cancel();
    _timer = null;
  }
}
