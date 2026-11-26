import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import 'file_extras_api.dart';
import 'file_models.dart';
import 'file_pins_and_insights_widgets.dart';
import 'files_page_state_models.dart';
import 'offline_file_store.dart';

/// Coordinates file pins, quick-view file insights (large/recent), and offline
/// document vault state on behalf of [FilesController], enforcing root-identity
/// and disposal guards across all async completions.
class FilesExtrasCoordinator {
  FilesExtrasCoordinator({
    required this.dir,
    required this.readApi,
    required this.readOfflineAccountId,
    required this.isDisposed,
    required this.onChanged,
    this.onNoticeMessage,
  });

  final FilesDirectoryState dir;
  final LightIsleApi Function() readApi;
  final String Function() readOfflineAccountId;
  final bool Function() isDisposed;
  final VoidCallback onChanged;
  final ValueChanged<String>? onNoticeMessage;

  List<FilePinEntry> pins = const [];
  bool pinsCollapsed = false;
  bool pinsBusy = false;
  FilesQuickViewMode quickViewMode = FilesQuickViewMode.browse;
  bool insightsLoading = false;
  String? insightsError;
  FileInsightsResponse? insightsResponse;
  int insightMinBytes = 50 << 20;
  int insightRecentDays = 7;
  int _insightsGeneration = 0;
  int offlineFileCount = 0;

  FileExtrasApi get extrasApi => FileExtrasApi(readApi());

  bool isPinned(String path) => pins.any((p) => p.path == path);

  void resetForRootChange() {
    pins = const [];
    pinsBusy = false;
    quickViewMode = FilesQuickViewMode.browse;
    insightsResponse = null;
    insightsError = null;
    insightsLoading = false;
    _insightsGeneration++;
    offlineFileCount = 0;
  }

  Future<void> loadPins() async {
    final rootIdentity = dir.rootIdentity;
    try {
      final fetched = await extrasApi.listPins();
      if (isDisposed() || dir.rootIdentity != rootIdentity) return;
      pins = fetched;
      onChanged();
    } catch (_) {
      // Optional endpoint: never disturb directory listing when unavailable.
    }
  }

  void togglePinsCollapsed() {
    pinsCollapsed = !pinsCollapsed;
    onChanged();
  }

  Future<void> togglePin(FileEntry item) async {
    if (pinsBusy) return;
    final rootIdentity = dir.rootIdentity;
    final wasPinned = isPinned(item.path);
    pinsBusy = true;
    onChanged();
    try {
      if (wasPinned) {
        await extrasApi.removePin(item.path);
        if (isDisposed() || dir.rootIdentity != rootIdentity) return;
        pins = pins.where((p) => p.path != item.path).toList();
        onNoticeMessage?.call('已取消置顶“${item.name}”。');
      } else {
        final added = await extrasApi.addPin(path: item.path, label: item.name);
        if (isDisposed() || dir.rootIdentity != rootIdentity) return;
        pins = [added, ...pins.where((p) => p.path != added.path)];
        onNoticeMessage?.call('已置顶“${item.name}”到常用区。');
      }
    } catch (error) {
      if (!isDisposed() && dir.rootIdentity == rootIdentity) {
        onNoticeMessage?.call('置顶操作失败：${userFacingError(error)}');
      }
    } finally {
      if (!isDisposed() && dir.rootIdentity == rootIdentity) {
        pinsBusy = false;
        onChanged();
      }
    }
  }

  Future<void> removePinEntry(FilePinEntry pin) async {
    if (pinsBusy) return;
    final rootIdentity = dir.rootIdentity;
    pinsBusy = true;
    onChanged();
    try {
      await extrasApi.removePin(pin.path);
      if (isDisposed() || dir.rootIdentity != rootIdentity) return;
      pins = pins.where((p) => p.path != pin.path).toList();
      onNoticeMessage?.call('已取消置顶“${pin.displayName}”。');
    } catch (error) {
      if (!isDisposed() && dir.rootIdentity == rootIdentity) {
        onNoticeMessage?.call('取消置顶失败：${userFacingError(error)}');
      }
    } finally {
      if (!isDisposed() && dir.rootIdentity == rootIdentity) {
        pinsBusy = false;
        onChanged();
      }
    }
  }

  void setQuickViewMode(FilesQuickViewMode mode) {
    if (quickViewMode == mode) return;
    quickViewMode = mode;
    if (mode == FilesQuickViewMode.browse) {
      insightsError = null;
      onChanged();
    } else {
      unawaited(loadInsights());
    }
  }

  void setInsightMinBytes(int bytes) {
    if (insightMinBytes == bytes) return;
    insightMinBytes = bytes;
    unawaited(loadInsights());
  }

  void setInsightRecentDays(int days) {
    if (insightRecentDays == days) return;
    insightRecentDays = days;
    unawaited(loadInsights());
  }

  Future<void> loadInsights() async {
    if (quickViewMode == FilesQuickViewMode.browse) return;
    final gen = ++_insightsGeneration;
    final rootIdentity = dir.rootIdentity;
    final modeStr = quickViewMode == FilesQuickViewMode.large
        ? 'large'
        : 'recent';
    insightsLoading = true;
    insightsError = null;
    onChanged();
    try {
      final res = await extrasApi.fetchInsights(
        mode: modeStr,
        path: dir.path,
        minBytes: modeStr == 'large' ? insightMinBytes : null,
        days: modeStr == 'recent' ? insightRecentDays : null,
      );
      if (isDisposed() ||
          gen != _insightsGeneration ||
          dir.rootIdentity != rootIdentity) {
        return;
      }
      insightsResponse = res;
    } catch (error) {
      if (!isDisposed() &&
          gen == _insightsGeneration &&
          dir.rootIdentity == rootIdentity) {
        insightsError = '加载快筛失败：${userFacingError(error)}';
      }
    } finally {
      if (!isDisposed() &&
          gen == _insightsGeneration &&
          dir.rootIdentity == rootIdentity) {
        insightsLoading = false;
        onChanged();
      }
    }
  }

  Future<void> refreshOfflineFileCount() async {
    final account = readOfflineAccountId();
    if (account.isEmpty) return;
    final rootIdentity = dir.rootIdentity;
    try {
      final stat = await OfflineFileStore(
        api: readApi(),
        accountIdentity: account,
      ).stats();
      if (!isDisposed() &&
          dir.rootIdentity == rootIdentity &&
          offlineFileCount != stat.count) {
        offlineFileCount = stat.count;
        onChanged();
      }
    } catch (_) {}
  }

  Future<OfflineFileEntry?> saveFileOffline(FileEntry item) async {
    final account = readOfflineAccountId();
    if (account.isEmpty) {
      onNoticeMessage?.call('无法确认当前账号，请重新登录后再保存到离线文件箱。');
      return null;
    }
    final rootIdentity = dir.rootIdentity;
    try {
      final entry = await OfflineFileStore(
        api: readApi(),
        accountIdentity: account,
      ).save(item);
      if (isDisposed() || dir.rootIdentity != rootIdentity) return entry;
      await refreshOfflineFileCount();
      if (!isDisposed() && dir.rootIdentity == rootIdentity) {
        onNoticeMessage?.call('已将“${item.name}”保存到离线文件箱，断网亦可直接打开。');
      }
      return entry;
    } catch (error) {
      if (!isDisposed() && dir.rootIdentity == rootIdentity) {
        onNoticeMessage?.call('保存到离线文件箱失败：${userFacingError(error)}');
      }
      return null;
    }
  }
}
