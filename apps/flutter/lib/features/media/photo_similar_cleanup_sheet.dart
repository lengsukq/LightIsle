import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'media_ui.dart';
import 'photo_ai_models.dart';

/// Side-by-side burst & visually similar photo cleanup page with explainable
/// Best-Shot recommendation and keep-at-least-one guardrail.
class PhotoSimilarCleanupPage extends StatefulWidget {
  const PhotoSimilarCleanupPage({required this.api, super.key});

  final LightIsleApi api;

  @override
  State<PhotoSimilarCleanupPage> createState() =>
      _PhotoSimilarCleanupPageState();
}

class _PhotoSimilarCleanupPageState extends State<PhotoSimilarCleanupPage> {
  PhotoAIRepository get _repo => PhotoAIRepository(widget.api);

  List<SimilarPhotoGroup> _groups = const [];
  final Map<String, int> _keepByGroup = <String, int>{};
  final Map<String, Set<int>> _trashByGroup = <String, Set<int>>{};
  String _quotaNote = '移入回收站后可随时恢复；个人空间配额将在从回收站永久删除后释放。';
  bool _loading = true;
  String? _busyGroupId;
  String? _error;
  String? _message;
  bool _didTrashAny = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await _repo.listSimilarGroups(limit: 50);
      if (!mounted) return;
      _keepByGroup.clear();
      _trashByGroup.clear();
      for (final g in res.groups) {
        final keepId = g.recommendedAssetId > 0
            ? g.recommendedAssetId
            : (g.items.isNotEmpty ? g.items.first.assetId : 0);
        _keepByGroup[g.groupId] = keepId;
        _trashByGroup[g.groupId] = selectRecommendedWasteIds(g).toSet();
      }
      setState(() {
        _groups = res.groups;
        if (res.quotaReleaseNote.isNotEmpty) {
          _quotaNote = res.quotaReleaseNote;
        }
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

  void _selectKeep(SimilarPhotoGroup group, int assetId) {
    setState(() {
      _keepByGroup[group.groupId] = assetId;
      final selected = _trashByGroup[group.groupId] ?? <int>{};
      selected.remove(assetId);
      _trashByGroup[group.groupId] = selected;
    });
  }

  void _toggleTrashCandidate(
    SimilarPhotoGroup group,
    SimilarPhotoCandidate item,
  ) {
    final keepId = _keepByGroup[group.groupId] ?? group.recommendedAssetId;
    if (item.assetId == keepId || !item.canTrash) return;
    setState(() {
      final selected = _trashByGroup[group.groupId] ?? <int>{};
      if (!selected.remove(item.assetId)) {
        selected.add(item.assetId);
      }
      _trashByGroup[group.groupId] = selected;
    });
  }

  Future<void> _trashSelectedInGroup(SimilarPhotoGroup group) async {
    final keepId = _keepByGroup[group.groupId] ?? 0;
    final trashIds = (_trashByGroup[group.groupId] ?? const <int>{})
        .where((id) => id != keepId)
        .toList(growable: false);
    if (keepId <= 0 || trashIds.isEmpty) return;

    final confirmed = await confirmAction(
      context,
      '移入回收站确认',
      '将保留所选最佳照片，并把其余 ${trashIds.length} 张相似照片移入回收站（.lightisle-trash）。\n$_quotaNote',
      action: '移入回收站',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _busyGroupId = group.groupId;
      _error = null;
      _message = null;
    });
    try {
      final receipt = await _repo.trashSimilarGroup(
        keepAssetId: keepId,
        trashAssetIds: trashIds,
      );
      _didTrashAny = true;
      if (!mounted) return;
      setState(() {
        _message =
            '已将 ${receipt.trashed} 张相似废片移入回收站（暂存 ${formatMediaSize(receipt.stagedTrashBytes)}）。${receipt.quotaReleaseNote}';
      });
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _busyGroupId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _didTrashAny);
      },
      child: Scaffold(
        appBar: IsleAppBar(
          title: const Text('连拍与相似废片清理'),
          leading: BackButton(
            onPressed: () => Navigator.pop(context, _didTrashAny),
          ),
          actions: [
            IconButton(
              tooltip: '重新检测相似照片',
              onPressed: _loading || _busyGroupId != null ? null : _load,
              icon: const Icon(Icons.refresh_rounded, size: 20),
            ),
          ],
        ),
        body: IsleListView(
          maxWidth: IsleLayout.secondaryPageWidth,
          children: [
            IsleIntroCard(
              icon: Icons.auto_fix_high_rounded,
              title: '智能最佳照片推荐 · 每组至少保留 1 张原片',
              description:
                  '综合分析连拍时间差、画面特征相似度、清晰度与画质美学评分，自动勾选建议清理的重复废片。$_quotaNote',
            ),
            if (_message != null) Notice(_message!),
            if (_error != null)
              Notice(_error!, error: true, onRetry: _loading ? null : _load),
            if (_loading)
              const IsleLoadingState(compact: true, label: '正在检测连拍与相似照片…')
            else if (_groups.isEmpty)
              const IsleEmptyStateCard(
                '后台完成离线画面特征提取后，连拍与相似废片会自动汇总到这里供你对比。',
                title: '暂未发现需要清理的连拍或高相似照片',
                icon: Icons.check_circle_outline_rounded,
              )
            else ...[
              _buildCleanupComparisonCard(context),
              for (final group in _groups) _buildGroupCard(context, group),
            ],
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildCleanupComparisonCard(BuildContext context) {
    final totalPhotos = _groups.fold<int>(0, (s, g) => s + g.items.length);
    final trashCount = _groups.fold<int>(
      0,
      (s, g) => s + (_trashByGroup[g.groupId]?.length ?? 0),
    );
    final keepCount = (totalPhotos - trashCount).clamp(0, totalPhotos);
    final reclaimBytes = _groups.fold<int>(0, (s, g) => s + g.reclaimableBytes);
    final trashRatio = totalPhotos > 0
        ? (trashCount / totalPhotos).clamp(0.0, 1.0)
        : 0.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: IsleSurface(
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            IsleDonutGauge(
              fraction: trashRatio,
              color: const Color(0xFFEF4444),
              size: 42,
              strokeWidth: 4.0,
              centerText: '${(trashRatio * 100).round()}%',
              semanticsLabel:
                  '共 ${_groups.length} 组 $totalPhotos 张，已选清理 $trashCount 张',
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '待整理 ${_groups.length} 组 · 已选清理 $trashCount/$totalPhotos 张'
                    '${reclaimBytes > 0 ? '（约可省 ${formatMediaSize(reclaimBytes)}）' : ''}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  IsleSegmentedBar(
                    height: 7,
                    showPercentInLegend: true,
                    legendGap: 5,
                    legendSpacing: 10,
                    legendRunSpacing: 3,
                    segments: [
                      IsleChartSegment(
                        label: '保留精选',
                        value: keepCount.toDouble(),
                        color: const Color(0xFF10B981),
                        detail: '$keepCount 张',
                      ),
                      IsleChartSegment(
                        label: '待清理冗余',
                        value: trashCount.toDouble(),
                        color: const Color(0xFFEF4444),
                        detail: '$trashCount 张',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupCard(BuildContext context, SimilarPhotoGroup group) {
    final keepId = _keepByGroup[group.groupId] ?? group.recommendedAssetId;
    final selectedTrash = _trashByGroup[group.groupId] ?? const <int>{};
    final busy = _busyGroupId == group.groupId;
    final colors = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: IsleSurface(
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 6,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IsleStatusBadge(
                      label: group.kind == 'burst' ? '手机连拍' : '画面相似',
                      color: IslePalette.of(context)['brandBlue'],
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${group.items.length} 张 · ${formatMediaDate(group.takenAt)}',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: busy || selectedTrash.isEmpty
                      ? null
                      : () => _trashSelectedInGroup(group),
                  icon: busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_outline_rounded, size: 16),
                  label: Text('清理已选 (${selectedTrash.length})'),
                ),
              ],
            ),
            if (group.recommendReason.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '推荐依据：${group.recommendReason}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontSize: 12,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final item in group.items)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: _buildCandidateTile(
                        context,
                        group: group,
                        item: item,
                        isKeep: item.assetId == keepId,
                        isTrash: selectedTrash.contains(item.assetId),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCandidateTile(
    BuildContext context, {
    required SimilarPhotoGroup group,
    required SimilarPhotoCandidate item,
    required bool isKeep,
    required bool isTrash,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      width: 168,
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.03)
            : colors.surfaceContainerHighest.withValues(alpha: 0.25),
        borderRadius: IsleRadius.brMd,
        border: Border.all(
          color: isKeep
              ? const Color(0xFF10B981)
              : isTrash
              ? colors.error
              : IsleGlass.rimBorderColor(isDark),
          width: isKeep || isTrash ? 1.8 : 1.0,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 118,
            child: Stack(
              fit: StackFit.expand,
              children: [
                AuthenticatedMediaImage(
                  api: widget.api,
                  path: '/api/v2/photos/${item.assetId}/thumbnail',
                  fit: BoxFit.cover,
                ),
                if (item.recommended)
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF059669),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        '最佳推荐',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${formatMediaSize(item.size)} · 清晰度 ${(item.sharpness * 100).round()}%',
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: isKeep
                            ? null
                            : () => _selectKeep(group, item.assetId),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          minimumSize: const Size(0, 28),
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        child: Text(
                          isKeep ? '保留此张' : '设为保留',
                          style: const TextStyle(fontSize: 11.5),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Checkbox(
                      visualDensity: VisualDensity.compact,
                      value: isTrash,
                      onChanged: isKeep || !item.canTrash
                          ? null
                          : (_) => _toggleTrashCandidate(group, item),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
