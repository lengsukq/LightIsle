import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/features/files/files_page_state_models.dart';
import 'package:lightisle/features/files/mobile_photo_backup_state_models.dart';
import 'package:lightisle/features/media/cinema_detail_state_models.dart';
import 'package:lightisle/features/media/cinema_page_state_models.dart';
import 'package:lightisle/features/media/media_models.dart';
import 'package:lightisle/features/media/photo_ai_models.dart';
import 'package:lightisle/features/media/photos_page_state_models.dart';

void main() {
  group('Cinema detail state models', () {
    test('CinemaPlaybackSessionState initializes safe defaults', () {
      final state = CinemaPlaybackSessionState();
      expect(state.loading, isTrue);
      expect(state.playbackSpeed, 1.0);
      expect(state.lastNonZeroVolume, 1.0);
      expect(state.isVideoReady, isFalse);
    });

    test(
      'CinemaPlayerChromeState tracks dock drag threshold and timer reset',
      () {
        final chrome = CinemaPlayerChromeState();
        expect(chrome.isDockMoved, isFalse);

        chrome.dockDragOffset = const Offset(1.5, -1.0);
        expect(chrome.isDockMoved, isFalse);

        chrome.dockDragOffset = const Offset(12.0, -24.0);
        expect(chrome.isDockMoved, isTrue);
        expect(chrome.cancelTimer, returnsNormally);
      },
    );

    test(
      'CinemaMetadataMatchState aggregates busy flags and disposes cleanly',
      () {
        final meta = CinemaMetadataMatchState(initialQuery: '星际穿越');
        expect(meta.tmdbQueryController.text, '星际穿越');
        expect(meta.isAnyBusy, isFalse);

        meta.doubanSearching = true;
        expect(meta.isAnyBusy, isTrue);

        meta.doubanSearching = false;
        meta.tmdbTokenController.text = 'secret-token';
        final initialGen = meta.generation;
        meta.dispose();
        expect(meta.generation, initialGen + 1);
      },
    );
  });

  group('Cinema page state models', () {
    test('CinemaCatalogViewState and secondary views reset cleanly', () {
      final catalog = CinemaCatalogViewState()
        ..query = '流光'
        ..showSearch = true;
      catalog.searchController.text = '流光';
      catalog.resetSearch();
      expect(catalog.query, isEmpty);
      expect(catalog.searchController.text, isEmpty);
      expect(catalog.showSearch, isFalse);

      final subpages = CinemaSecondaryViewsState()
        ..showSeries = true
        ..showHistory = true;
      expect(subpages.isRootView, isFalse);
      subpages.exitSecondaryViews();
      expect(subpages.isRootView, isTrue);

      final selection = CinemaBatchSelectionState()
        ..selecting = true
        ..selectedFilmIds.addAll([10, 20]);
      selection.clear();
      expect(selection.selecting, isFalse);
      expect(selection.selectedFilmIds, isEmpty);

      catalog.dispose();
    });
  });

  group('Photos page state models', () {
    test(
      'PhotosFilterScopeState tracks full timeline selection accurately',
      () {
        final scope = PhotosFilterScopeState();
        expect(scope.isUnscopedCollection, isTrue);
        expect(scope.isFullTimelineSelected, isTrue);

        scope.setCollectionScope(privateAlbumId: 7);
        expect(scope.isUnscopedCollection, isFalse);
        expect(scope.isFullTimelineSelected, isFalse);

        scope.setCollectionScope();
        expect(scope.isFullTimelineSelected, isTrue);

        scope.cameraFilter = 'RICOH GR III';
        expect(scope.isUnscopedCollection, isTrue);
        expect(scope.isFullTimelineSelected, isFalse);

        scope.clearSearchAndFacets(closeSearchBar: true);
        expect(scope.isFullTimelineSelected, isTrue);
        scope.dispose();
      },
    );

    test(
      'PhotosFilterScopeState builds query parameters for scopes and facets',
      () {
        final scope = PhotosFilterScopeState()
          ..setCollectionScope(
            albumId: 3,
            folderPath: 'Trips/2026',
            personId: 9,
            personName: 'Alice',
            favorites: true,
          )
          ..query = '海边'
          ..searchMode = PhotoSearchMode.scene
          ..mediaType = 'photo'
          ..cameraFilter = 'Sony A7C'
          ..locationFilter = '1'
          ..yearFilter = 2025;

        final params = scope.buildQueryParameters(limit: 48, cursor: 96);
        expect(params['limit'], '48');
        expect(params['cursor'], '96');
        expect(params['album'], '3');
        expect(params['directory'], 'Trips/2026');
        expect(params['favorites'], '1');
        expect(params['q'], '海边');
        expect(params['searchMode'], 'scene');
        expect(params['personId'], '9');
        expect(params['type'], 'photo');
        expect(params['camera'], 'Sony A7C');
        expect(params['hasLocation'], '1');
        expect(int.parse(params['takenFrom']!), greaterThan(0));
        expect(
          int.parse(params['takenTo']!),
          greaterThan(int.parse(params['takenFrom']!)),
        );
        scope.dispose();
      },
    );

    test(
      'PhotosAlbumCatalogState resolves shared and private albums by id',
      () {
        final catalog = PhotosAlbumCatalogState()
          ..sharedAlbums = const [
            MediaAlbum(id: 11, name: '家庭旅行', count: 20, coverAssetId: 1),
          ]
          ..privateAlbums = const [
            MediaAlbum(id: 22, name: '个人精选', count: 5, coverAssetId: 2),
          ];

        expect(catalog.findShared(0), isNull);
        expect(catalog.findShared(11)?.name, '家庭旅行');
        expect(catalog.findPrivate(22)?.name, '个人精选');
        expect(catalog.findPrivate(99), isNull);

        catalog.cancelPending();
        expect(catalog.sharedGeneration, 1);
        expect(catalog.privateGeneration, 1);
      },
    );

    test('PhotosSelectionState and PhotosLibraryFeedState reset cleanly', () {
      final selection = PhotosSelectionState()
        ..selecting = true
        ..selectedAssets.addAll([1, 2, 3]);
      selection.clear();
      expect(selection.selecting, isFalse);
      expect(selection.selectedAssets, isEmpty);

      final feed = PhotosLibraryFeedState();
      feed.setActionFeedback('已失败', isError: true);
      expect(feed.actionMessage, '已失败');
      expect(feed.actionIsError, isTrue);

      feed.clearActionFeedback();
      expect(feed.actionMessage, isNull);
      expect(feed.actionIsError, isFalse);
    });
  });

  group('Files & Mobile backup state models', () {
    test(
      'FilesDirectoryState and FilesSearchAndTrashState reset on root switch',
      () {
        final dir =
            FilesDirectoryState(path: 'Users/u2/files', rootIdentity: 'r1:1')
              ..canWrite = true
              ..nextCursor = 'c2'
              ..error = 'stale';
        dir.failedThumbnails.add('a.jpg@1');

        dir.resetForIdentity('.', 'r2:1');
        expect(dir.loadGeneration, 1);
        expect(dir.rootIdentity, 'r2:1');
        expect(dir.path, '.');
        expect(dir.canWrite, isFalse);
        expect(dir.nextCursor, isEmpty);
        expect(dir.error, isNull);
        expect(dir.failedThumbnails, isEmpty);

        final filter = FilesSearchAndTrashState()
          ..showingTrash = true
          ..searching = true
          ..searchKind = 'video';
        filter.searchController.text = 'movie';
        filter.reset();
        expect(filter.showingTrash, isFalse);
        expect(filter.searching, isFalse);
        expect(filter.searchKind, isEmpty);
        expect(filter.searchController.text, isEmpty);
        filter.dispose();
      },
    );

    test('PhotoBackupRunProgressState and PhotoBackupPrepareSessionState reset counters', () {
      final progress = PhotoBackupRunProgressState()
        ..checked = 42
        ..uploaded = 10
        ..failed = 3
        ..nextCursor = '999';
      progress.beginRun();
      expect(progress.busy, isTrue);
      expect(progress.cancel, isFalse);
      expect(progress.checked, 0);
      expect(progress.uploaded, 0);
      expect(progress.failed, 0);
      expect(progress.nextCursor, isEmpty);

      final prepare = PhotoBackupPrepareSessionState();
      final id1 = prepare.nextRequestId('dev1');
      final id2 = prepare.nextRequestId('dev1');
      expect(id1, startsWith('dev1-'));
      expect(id2, isNot(equals(id1)));
    });
  });
}
