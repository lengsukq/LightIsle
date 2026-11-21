import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/files/file_models.dart';
import 'package:lightisle/features/files/files_controller.dart';
import 'package:lightisle/features/files/mobile_photo_backup_controller.dart';
import 'package:lightisle/features/media/cinema_detail_controller.dart';
import 'package:lightisle/features/media/media_models.dart';
import 'package:lightisle/features/media/photos_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Wave 3 Flutter part-cluster decoupling guards', () {
    test('all 4 refactored clusters have 0 part/part-of directives and 0 _updateState hacks', () {
      const clusterRoots = <String, (String dir, String prefix)>{
        'cinema_detail_dialog': ('lib/features/media', 'cinema_detail_'),
        'photos_page': ('lib/features/media', 'photos_'),
        'files_page': ('lib/features/files', 'files_'),
        'mobile_photo_backup_page': ('lib/features/files', 'mobile_photo_backup'),
      };

      for (final entry in clusterRoots.entries) {
        final directory = Directory(entry.value.$1);
        final files = directory
            .listSync()
            .whereType<File>()
            .where((f) {
              final name = f.uri.pathSegments.last;
              return name.startsWith(entry.value.$2) && name.endsWith('.dart');
            })
            .toList();
        expect(
          files,
          isNotEmpty,
          reason: '${entry.key} must contain Dart source files',
        );
        for (final file in files) {
          final lines = file.readAsLinesSync();
          expect(
            lines.length,
            lessThan(800),
            reason: '${file.path} exceeds 800-line limit (${lines.length}L)',
          );
          final hasPart = lines.any(
            (line) => line.startsWith('part ') || line.startsWith('part of '),
          );
          expect(
            hasPart,
            isFalse,
            reason: '${file.path} must not use part/part of directives',
          );
          final hasUpdateState = lines.any((line) => line.contains('_updateState'));
          expect(
            hasUpdateState,
            isFalse,
            reason: '${file.path} must not rely on _updateState closures',
          );
        }
      }
    });

    test('every production Dart file in lib/ is strictly under 800 lines', () {
      final libDir = Directory('lib');
      final offenders = <String>[];
      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final count = entity.readAsLinesSync().length;
        if (count >= 800) {
          offenders.add('${entity.path}: $count lines');
        }
      }
      expect(offenders, isEmpty, reason: 'Files >= 800 lines: $offenders');
    });
  });

  group('Wave 3 standalone ChangeNotifier controllers (no BuildContext)', () {
    test('CinemaDetailController manages subtitles, quality tiers, dock, and disposal cleanly', () {
      final api = LightIsleApi('http://127.0.0.1:8080');
      addTearDown(api.close);
      final film = CinemaFilm.fromJson(const <String, dynamic>{
        'id': 42,
        'title': 'Solaris',
        'path': 'Movies/Solaris.mkv',
        'kind': 'movie',
        'height': 2160,
        'playable': true,
        'browserPlayback': 'direct',
        'probeStatus': 'ready',
      });
      final controller = CinemaDetailController(
        api: api,
        initialFilm: film,
        isAdmin: true,
        onRename: (f) async => f,
        onProgressUpdated: (_) {},
      );
      var notifications = 0;
      controller.addListener(() => notifications++);

      expect(
        controller.qualityOptions().map((o) => o.$1).toList(),
        equals(<String>['source', 'local', '1080', '720', '480']),
      );

      controller.setSubtitleFontSize(21.0);
      expect(controller.subtitles.fontSize, 21.0);
      controller.adjustSubtitleOffset('+0.5');
      expect(controller.subtitles.offsetSeconds, 0.5);
      controller.adjustSubtitleOffset('reset');
      expect(controller.subtitles.offsetSeconds, 0.0);

      controller.updateDockDragOffset(
        const Offset(24, -40),
        const Size(1200, 800),
      );
      expect(controller.chrome.isDockMoved, isTrue);
      controller.collapseDock();
      expect(controller.chrome.dockManuallyCollapsed, isTrue);
      controller.restoreDock();
      expect(controller.chrome.dockManuallyCollapsed, isFalse);
      controller.resetDockDragOffset();
      expect(controller.chrome.isDockMoved, isFalse);
      expect(notifications, greaterThan(0));

      controller.dispose();
      expect(controller.isDisposed, isTrue);
      final countBefore = notifications;
      controller.notify();
      expect(notifications, countBefore);
    });

    test('PhotosController exposes scope, subtitle, and backstack state without BuildContext', () {
      final api = LightIsleApi('http://127.0.0.1:8080');
      addTearDown(api.close);
      final controller = PhotosController(api: api, isAdmin: false);
      expect(controller.canPop, isTrue);
      expect(controller.isFullTimelineSelected, isTrue);

      controller.scope.setCollectionScope(onThisDayView: true);
      expect(controller.headerSubtitle, '那年今天');
      expect(controller.canPop, isFalse);

      controller.selection.selecting = true;
      expect(controller.canPop, isFalse);

      controller.dispose();
      expect(controller.isDisposed, isTrue);
    });

    test('FilesController tracks path segments, permissions, and pop state without BuildContext', () {
      final api = LightIsleApi('http://127.0.0.1:8080');
      addTearDown(api.close);
      final controller = FilesController(
        config: FilesPageConfig(
          api: api,
          isAdmin: false,
          initialPath: 'Users/u2/Files',
        ),
      );
      expect(controller.canPopPage, isTrue);
      expect(
        controller.canWriteItem(
          const FileEntry(
            name: 'doc.txt',
            path: 'Users/u2/Files/doc.txt',
            type: 'file',
            size: 12,
            modified: null,
            canWrite: false,
          ),
        ),
        isFalse,
      );

      controller.dir.path = 'Users/u2/Files/Projects';
      expect(controller.canPopPage, isFalse);
      expect(controller.pathSegments.last.$1, 'Projects');
      expect(controller.pathSegments.last.$2, 'Users/u2/Files/Projects');

      controller.dispose();
      expect(controller.isDisposed, isTrue);
    });

    test('MobilePhotoBackupController isolates platform overrides and destination checks without BuildContext', () {
      final api = LightIsleApi('http://127.0.0.1:8080');
      addTearDown(api.close);
      final controller = MobilePhotoBackupController(
        api: api,
        accountName: 'alice',
        baseDirectory: 'Users/u2/Photos',
        androidPlatformOverride: false,
        iosPlatformOverride: true,
      );
      expect(controller.isIOS, isTrue);
      expect(controller.isAndroid, isFalse);
      expect(controller.isPersonalDestination, isTrue);
      expect(controller.icloudPendingCount, 0);

      controller.progress.failureDetails = [
        {'id': '1', 'reason': 'icloud_not_downloaded'},
        {'id': '2', 'reason': 'source_unreadable'},
      ];
      expect(controller.icloudPendingCount, 1);

      controller.dispose();
    });
  });
}
