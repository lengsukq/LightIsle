import 'package:flutter/foundation.dart';

import 'lightisle_api.dart';

/// Immutable snapshot of root discovery and personal storage policy owned by
/// `ClientShell` and shared with child pages such as `OverviewPage`.
class ShellStorageSnapshot {
  const ShellStorageSnapshot({
    this.roots = const [],
    this.personalStorage,
    this.rootsError,
    this.loading = false,
    this.hasFetched = false,
  });

  final List<LightIsleRoot> roots;
  final Map<String, dynamic>? personalStorage;
  final String? rootsError;
  final bool loading;
  final bool hasFetched;
}

/// Single-source-of-truth storage state handle owned by `ClientShell`.
class ShellStorageHandle extends ValueNotifier<ShellStorageSnapshot> {
  ShellStorageHandle({required this._onRefresh})
    : super(const ShellStorageSnapshot());

  final Future<void> Function() _onRefresh;

  Future<void> refresh() => _onRefresh();
}
