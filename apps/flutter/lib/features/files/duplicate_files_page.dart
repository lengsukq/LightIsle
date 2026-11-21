import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import '../media/media_ui.dart';
import '../media/photo_ai_models.dart';

/// Full-disk or subtree duplicate large file scanner & cleanup page.
/// Honors macOS APFS CoW clone physical space semantics and enforces keeping
/// at least 1 file copy per SHA-256 group.
class DuplicateFilesPage extends StatefulWidget {
  const DuplicateFilesPage({
    required this.api,
    this.initialPath = '.',
    super.key,
  });

  final LightIsleApi api;
  final String initialPath;

  @override
  State<DuplicateFilesPage> createState() => _DuplicateFilesPageState();
}

class _DuplicateFilesPageState extends State<DuplicateFilesPage> {
  PhotoAIRepository get _repo => PhotoAIRepository(widget.api);

  static const List<(int, String)> _minSizeOptions = <(int, String)>[
    (1024 * 1024, '≥ 1 MiB（默认）'),
    (10 * 1024 * 1024, '≥ 10 MiB（大文件）'),
    (100 * 1024 * 1024, '≥ 100 MiB（视频/归档）'),
    (500 * 1024 * 1024, '≥ 500 MiB（超大原片）'),
  ];

  int _minSizeBytes = 1024 * 1024;
  DuplicateKeepStrategy _strategy = DuplicateKeepStrategy.shortestPath;
  DuplicateScanSnapshot _snapshot = const DuplicateScanSnapshot();
  final Map<String, String> _keepByGroup = <String, String>{};
  final Map<String, Set<String>> _trashByGroup = <String, Set<String>>{};
  bool _loading = true;
  bool _startingScan = false;
  bool _cancellingScan = false;
  bool _trashing = false;
  String? _error;
  String? _message;
  bool _didTrashAny = false;
  Timer? _pollTimer;

  bool get _scanning => _startingScan || _snapshot.running;

  @override
  void initState() {
    super.initState();
    unawaited(_loadStatus());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _syncPolling(DuplicateScanSnapshot snap) {
    if (snap.running) {
      _pollTimer ??= Timer.periodic(
        const Duration(milliseconds: 800),
        (_) => unawaited(_pollOnce()),
      );
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  Future<void> _pollOnce() async {
    try {
      final snap = await _repo.getDuplicatesStatus();
      if (!mounted) return;
      final wasRunning = _snapshot.running;
      _syncPolling(snap);
      setState(() {
        _snapshot = snap;
        if (!snap.running &&
            snap.lastError.isNotEmpty &&
            snap.lastError != 'cancelled') {
          _error = userFacingError(snap.lastError);
        }
        if (wasRunning && !snap.running) {
          _applyStrategySelection(snap.groups);
        }
      });
    } catch (_) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  void _applyStrategySelection(List<DuplicateFileGroup> groups) {
    _keepByGroup.clear();
    _trashByGroup.clear();
    for (final g in groups) {
      final keepPath = chooseDuplicateKeepPath(g.items, _strategy);
      _keepByGroup[g.groupId] = keepPath;
      _trashByGroup[g.groupId] = g.items
          .where((it) => it.path != keepPath && it.canTrash)
          .map((it) => it.path)
          .toSet();
    }
  }

  Future<void> _loadStatus() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snap = await _repo.getDuplicatesStatus();
      if (!mounted) return;
      _applyStrategySelection(snap.groups);
      _syncPolling(snap);
      setState(() {
        _snapshot = snap;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = userFacingError(e);
        _loading = false;
      });
    }
  }

  Future<void> _runScan() async {
    setState(() {
      _startingScan = true;
      _error = null;
      _message = null;
    });
    try {
      final snap = await _repo.scanDuplicates(
        path: widget.initialPath,
        minSizeBytes: _minSizeBytes,
      );
      if (!mounted) return;
      if (!snap.running) {
        _applyStrategySelection(snap.groups);
      }
      _syncPolling(snap);
      setState(() => _snapshot = snap);
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _startingScan = false);
    }
  }

  Future<void> _cancelScan() async {
    if (_cancellingScan) return;
    setState(() => _cancellingScan = true);
    try {
      await _repo.cancelDuplicateScan();
      _pollTimer?.cancel();
      _pollTimer = null;
      await _loadStatus();
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _cancellingScan = false);
    }
  }

  int get _selectedTrashCount {
    var count = 0;
    for (final g in _snapshot.groups) {
      final keep = _keepByGroup[g.groupId] ?? '';
      final selected = _trashByGroup[g.groupId] ?? const <String>{};
      count += selected.where((p) => p != keep).length;
    }
    return count;
  }

  Future<void> _trashSelected() async {
    final payload = <({String keepPath, List<DuplicateFileItem> trashItems})>[];
    for (final g in _snapshot.groups) {
      final keep = _keepByGroup[g.groupId] ?? '';
      final selected = _trashByGroup[g.groupId] ?? const <String>{};
      if (keep.isEmpty || selected.isEmpty) continue;
      final items = g.items
          .where(
            (it) =>
                it.path != keep && selected.contains(it.path) && it.canTrash,
          )
          .toList(growable: false);
      if (items.isNotEmpty) {
        payload.add((keepPath: keep, trashItems: items));
      }
    }
    if (payload.isEmpty) return;

    final totalFiles = payload.fold<int>(
      0,
      (sum, entry) => sum + entry.trashItems.length,
    );
    final note = _snapshot.quotaReleaseNote.isNotEmpty
        ? _snapshot.quotaReleaseNote
        : '移入回收站后可随时恢复；个人空间配额将在从回收站永久删除后释放。';
    final confirmed = await confirmAction(
      context,
      '清理重复文件确认',
      '每组均保留 1 份原件，其余 $totalFiles 个重复副本将移入回收站（.lightisle-trash），并校验文件身份未发生变化。\n$note',
      action: '移入回收站',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _trashing = true;
      _error = null;
      _message = null;
    });
    try {
      final receipt = await _repo.trashDuplicates(payload.take(50).toList());
      _didTrashAny = true;
      if (!mounted) return;
      setState(() {
        _message =
            '已将 ${receipt.trashed} 个重复文件移入回收站（暂存 ${formatMediaSize(receipt.stagedTrashBytes)}）。${receipt.quotaReleaseNote}';
      });
      await _loadStatus();
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _trashing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    final accent = palette['brandAmber'];
    final sage = palette['brandSage'];

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _didTrashAny);
      },
      child: Scaffold(
        appBar: IsleAppBar(
          title: const Text('重复大文件扫描与清理'),
          leading: BackButton(
            onPressed: () => Navigator.pop(context, _didTrashAny),
          ),
          actions: [
            IsleHelpButton(
              title: '重复检测与空间释放说明',
              accentColor: accent,
              items: const [
                IsleHelpItem(
                  title: 'SHA-256 全量校验与保留原件',
                  body:
                      '先按字节大小初筛再比对全量 SHA-256 哈希，每组强制至少保留 1 份原件，杜绝误删唯一文件。',
                ),
                IsleHelpItem(
                  title: 'APFS 克隆识别与回收站保护',
                  body:
                      '自动识别 macOS APFS 写时复制克隆块（零额外物理占用）；清理操作先移入回收站，可随时恢复，永久清空后释放配额。',
                ),
              ],
            ),
          ],
        ),
        body: IsleListView(
          maxWidth: IsleLayout.workbenchMaxWidth,
          children: [
            IsleFocalStage(
              icon: Icons.file_copy_outlined,
              accent: accent,
              title: '重复文件核验与空间释放',
              metrics: _snapshot.hasResult
                  ? [
                      IsleFocalMetric(
                        label: '已检大文件',
                        value: '${_snapshot.scannedFiles}',
                        accent: palette['brandBlue'],
                      ),
                      IsleFocalMetric(
                        label: '重复分组',
                        value: '${_snapshot.totalGroups}',
                        accent: accent,
                      ),
                      IsleFocalMetric(
                        label: '可释放物理空间',
                        value: formatMediaSize(
                          _snapshot.totalReclaimablePhysicalBytes,
                        ),
                        accent: sage,
                      ),
                    ]
                  : const [],
            ),
            const SizedBox(height: 12),
            IsleSurface(
              margin: EdgeInsets.zero,
              padding: const EdgeInsets.all(15),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: 210,
                        child: DropdownButtonFormField<int>(
                          initialValue: _minSizeBytes,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: '扫描最小体积',
                            isDense: true,
                          ),
                          items: [
                            for (final opt in _minSizeOptions)
                              DropdownMenuItem(
                                value: opt.$1,
                                child: Text(
                                  opt.$2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _scanning || _trashing
                              ? null
                              : (v) {
                                  if (v != null) {
                                    setState(() => _minSizeBytes = v);
                                  }
                                },
                        ),
                      ),
                      SizedBox(
                        width: 196,
                        child: DropdownButtonFormField<DuplicateKeepStrategy>(
                          initialValue: _strategy,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: '默认保留策略',
                            isDense: true,
                          ),
                          items: [
                            for (final s in DuplicateKeepStrategy.values)
                              DropdownMenuItem(
                                value: s,
                                child: Text(
                                  s.label,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _scanning || _trashing
                              ? null
                              : (s) {
                                  if (s == null) return;
                                  setState(() {
                                    _strategy = s;
                                    _applyStrategySelection(_snapshot.groups);
                                  });
                                },
                        ),
                      ),
                      FilledButton.icon(
                        key: const ValueKey('startDuplicateScanButton'),
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: _scanning || _trashing ? null : _runScan,
                        icon: _scanning
                            ? const SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.radar_rounded, size: 17),
                        label: Text(_scanning ? '正在后台扫描…' : '开始扫描重复文件'),
                      ),
                      if (_scanning)
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: _cancellingScan ? null : _cancelScan,
                          icon: const Icon(Icons.cancel_outlined, size: 17),
                          label: Text(_cancellingScan ? '正在取消…' : '取消扫描'),
                        ),
                      if (_selectedTrashCount > 0)
                        FilledButton.tonalIcon(
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: _scanning || _trashing
                              ? null
                              : _trashSelected,
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            size: 17,
                          ),
                          label: Text('移入回收站 ($_selectedTrashCount)'),
                        ),
                    ],
                  ),
                  if (_scanning) ...[
                    const SizedBox(height: 10),
                    Text(
                      '${_snapshot.progressLabel}${_snapshot.progressCurrentPath.isNotEmpty ? " · ${_snapshot.progressCurrentPath}" : ""}',
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ] else if (_snapshot.hasResult && _snapshot.groups.isNotEmpty)
                    _buildSavingsComparison(context, palette),
                ],
              ),
            ),
            if (_message != null) ...[
              const SizedBox(height: 10),
              Notice(_message!),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Notice(_error!, error: true),
            ],
            const SizedBox(height: 12),
            if (_loading)
              const IsleLoadingState(compact: true, label: '正在读取重复扫描状态…')
            else if (!_snapshot.hasResult)
              const IsleEmptyStateCard(
                '点击上方「开始扫描重复文件」按需检查当前空间。',
                icon: Icons.radar_rounded,
              )
            else if (_snapshot.groups.isEmpty)
              const IsleEmptyStateCard(
                '未发现符合体积阈值的重复大文件。',
                icon: Icons.check_circle_outline_rounded,
              )
            else
              IsleAdaptiveBuilder(
                builder: (context, tier, width) {
                  final textScale =
                      MediaQuery.textScalerOf(context).scale(14) / 14;
                  if (tier == IsleViewportTier.expanded &&
                      _snapshot.groups.length > 1 &&
                      textScale <= 1.35) {
                    final cardWidth = (width - 12) / 2;
                    return Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final group in _snapshot.groups)
                          SizedBox(
                            width: cardWidth,
                            child: _buildDuplicateGroup(
                              context,
                              group,
                              palette,
                            ),
                          ),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < _snapshot.groups.length; i++) ...[
                        if (i > 0) const SizedBox(height: 10),
                        _buildDuplicateGroup(
                          context,
                          _snapshot.groups[i],
                          palette,
                        ),
                      ],
                    ],
                  );
                },
              ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildSavingsComparison(BuildContext context, IslePalette palette) {
    final keptBytes = _snapshot.groups.fold<int>(0, (sum, g) => sum + g.size);
    final reclaimBytes = _snapshot.totalReclaimablePhysicalBytes > 0
        ? _snapshot.totalReclaimablePhysicalBytes
        : _snapshot.totalReclaimableBytes;
    final total = keptBytes + reclaimBytes;
    if (total <= 0) return const SizedBox.shrink();
    final saveRatio = (reclaimBytes / total).clamp(0.0, 1.0);
    final sage = palette['brandSage'];
    final mineral = palette['brandBlue'];
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IsleDonutGauge(
            fraction: saveRatio,
            color: sage,
            size: 42,
            strokeWidth: 4.0,
            centerText: '省${(saveRatio * 100).round()}%',
            centerStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            semanticsLabel: '清理重复文件预计可节省 ${(saveRatio * 100).round()}% 空间',
          ),
          const SizedBox(width: 12),
          Expanded(
            child: IsleSegmentedBar(
              height: 7,
              showPercentInLegend: true,
              legendGap: 5,
              legendSpacing: 10,
              legendRunSpacing: 4,
              segments: [
                IsleChartSegment(
                  label: '保留原件',
                  value: keptBytes.toDouble(),
                  color: mineral,
                  detail: formatMediaSize(keptBytes),
                ),
                IsleChartSegment(
                  label: _snapshot.totalReclaimablePhysicalBytes > 0
                      ? '可释放物理冗余'
                      : '逻辑冗余空间',
                  value: reclaimBytes.toDouble(),
                  color: sage,
                  detail: formatMediaSize(reclaimBytes),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDuplicateGroup(
    BuildContext context,
    DuplicateFileGroup group,
    IslePalette palette,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = IsleGlass.rimBorderColor(isDark);
    final keepPath = _keepByGroup[group.groupId] ?? '';
    final selectedTrash = _trashByGroup[group.groupId] ?? const <String>{};
    final sage = palette['brandSage'];
    final amber = palette['brandAmber'];

    return IsleSurface(
      margin: EdgeInsets.zero,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 11, 14, 9),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '单文件 ${formatMediaSize(group.size)} × ${group.count} 份',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (group.allApfsClones)
                  IsleStatusBadge(label: 'APFS 克隆 · 零额外物理占用', color: amber)
                else
                  IsleStatusBadge(
                    label:
                        '可释放物理空间 ${formatMediaSize(group.reclaimablePhysicalBytes)}',
                    color: sage,
                  ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: borderColor),
          for (var i = 0; i < group.items.length; i++) ...[
            if (i > 0)
              Divider(height: 1, thickness: 1, indent: 44, color: borderColor),
            Builder(
              builder: (context) {
                final item = group.items[i];
                final isKeep = item.path == keepPath;
                final isChecked = selectedTrash.contains(item.path);
                return ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 1,
                  ),
                  leading: IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: isKeep ? '当前保留原件' : '设为此组保留原件',
                    onPressed: isKeep
                        ? null
                        : () {
                            setState(() {
                              _keepByGroup[group.groupId] = item.path;
                              final next =
                                  _trashByGroup[group.groupId] ?? <String>{};
                              next.remove(item.path);
                              _trashByGroup[group.groupId] = next;
                            });
                          },
                    icon: Icon(
                      isKeep
                          ? Icons.verified_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 19,
                      color: isKeep ? sage : null,
                    ),
                  ),
                  title: Text(
                    item.path,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    [
                      formatMediaDate(item.modified),
                      if (isKeep) '保留原件',
                      if (item.isApfsClone) 'APFS 克隆',
                      if (!item.canTrash) '只读权限',
                    ].join(' · '),
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  trailing: Checkbox(
                    visualDensity: VisualDensity.compact,
                    value: isChecked && !isKeep,
                    onChanged: isKeep || !item.canTrash
                        ? null
                        : (v) {
                            setState(() {
                              final next =
                                  _trashByGroup[group.groupId] ?? <String>{};
                              if (v == true) {
                                next.add(item.path);
                              } else {
                                next.remove(item.path);
                              }
                              _trashByGroup[group.groupId] = next;
                            });
                          },
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}
