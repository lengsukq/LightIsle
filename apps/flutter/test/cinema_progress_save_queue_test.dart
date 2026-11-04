import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/features/media/cinema_progress_save_queue.dart';

void main() {
  test(
    'writes are serialized even if an earlier request is still running',
    () async {
      final queue = CinemaProgressSaveQueue();
      final pending = Completer<void>();
      final order = <String>[];
      final first = queue.save(() async {
        order.add('start 1');
        await pending.future;
        order.add('end 1');
      }, force: true);
      final second = queue.save(() async {
        order.add('run 2');
      }, force: true);
      await Future<void>.delayed(Duration.zero);
      expect(order, ['start 1']);
      pending.complete();
      expect(await first, true);
      expect(await second, true);
      expect(order, ['start 1', 'end 1', 'run 2']);
    },
  );

  test(
    'a failed progress checkpoint does not poison the next checkpoint',
    () async {
      final queue = CinemaProgressSaveQueue();
      expect(
        await queue.save(() async => throw StateError('network'), force: true),
        false,
      );
      var saved = false;
      expect(
        await queue.save(() async {
          saved = true;
        }, force: true),
        true,
      );
      expect(saved, true);
    },
  );

  test(
    'nonforced saves are throttled without discarding explicit final save',
    () async {
      final queue = CinemaProgressSaveQueue();
      final start = DateTime.fromMillisecondsSinceEpoch(100000);
      var writes = 0;
      expect(
        await queue.save(() async {
          writes++;
        }, now: start),
        true,
      );
      expect(
        await queue.save(() async {
          writes++;
        }, now: start.add(const Duration(seconds: 2))),
        true,
      );
      expect(writes, 1);
      expect(
        await queue.save(
          () async {
            writes++;
          },
          now: start.add(const Duration(seconds: 2)),
          force: true,
        ),
        true,
      );
      expect(writes, 2);
    },
  );
}
