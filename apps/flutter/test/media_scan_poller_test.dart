import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/features/media/media_models.dart';
import 'package:lightisle/features/media/media_scan_poller.dart';

void main() {
  test('only requests list refresh on scan completion or newer index', () {
    final poller = MediaScanPoller(onPoll: () {});
    addTearDown(poller.dispose);
    expect(poller.observe(const MediaScanStatus()), false);
    expect(poller.observe(const MediaScanStatus(running: true)), false);
    expect(poller.observe(const MediaScanStatus(running: true)), false);
    expect(poller.observe(const MediaScanStatus(running: false)), true);
    expect(poller.observe(const MediaScanStatus(running: false)), false);
    expect(poller.observe(const MediaScanStatus(lastDone: 100)), true);
    expect(poller.observe(const MediaScanStatus(lastDone: 100)), false);
    expect(poller.observe(const MediaScanStatus(lastDone: 99)), false);
    expect(poller.observe(const MediaScanStatus(lastDone: 101)), true);
  });

  test('polling only runs while scanning and page is visible', () async {
    var ticks = 0;
    final poller = MediaScanPoller(
      interval: const Duration(milliseconds: 15),
      onPoll: () => ticks++,
    );
    addTearDown(poller.dispose);
    expect(poller.setActive(true), true);
    expect(poller.setActive(true), false);
    expect(poller.polling, false);
    poller.observe(const MediaScanStatus(running: true));
    expect(poller.polling, true);
    await Future<void>.delayed(const Duration(milliseconds: 70));
    expect(ticks, greaterThan(0));
    expect(poller.setActive(false), true);
    expect(poller.polling, false);
    final count = ticks;
    await Future<void>.delayed(const Duration(milliseconds: 45));
    expect(ticks, count);
    poller.dispose();
    expect(poller.setActive(true), false);
    expect(poller.polling, false);
  });
}
