import 'dart:async';

/// Serializes movie progress writes. Scrubbing, lifecycle pause and final
/// close may race; a later checkpoint must never reach the server before an
/// earlier one. The caller owns HTTP authorization and UI updates.
class CinemaProgressSaveQueue {
  static const minimumInterval = Duration(seconds: 10);

  DateTime lastQueuedAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _tail = Future<void>.value();

  Future<bool> save(
    Future<void> Function() operation, {
    bool force = false,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    if (!force && timestamp.difference(lastQueuedAt) < minimumInterval) {
      return Future<bool>.value(true);
    }
    lastQueuedAt = timestamp;
    final result = Completer<bool>();
    _tail = _tail.then((_) async {
      try {
        await operation();
        result.complete(true);
      } catch (_) {
        // A failed request cannot block later progress checkpoints.
        result.complete(false);
      }
    });
    return result.future;
  }
}
