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
    final inset = IsleLayout.pageInset(MediaQuery.sizeOf(context).width);
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
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: ListView(
            padding: EdgeInsets.fromLTRB(inset, 12, inset, 28),
            children: [
              IsleIntroCard(
                icon: Icons.auto_fix_high_rounded,
                title: '智能最佳照片推荐 · 每组至少保留 1 张原片',
                description:
                    '综合分析连拍时间差、画面特征相似度、清晰度与画质美学评分，自动勾选建议清理的重复废片。$_quotaNote',
              ),
              if (_message != null) ...[
                const SizedBox(height: 10),
                Notice(_message!),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Notice(_error!, error: true, onRetry: _loading ? null : _load),
              ],
              const SizedBox(height: 12),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_groups.isEmpty)
                const IsleSurface(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 28, horizontal: 16),
                    child: Column(
                      children: [
                        Icon(Icons.check_circle_outline_rounded, size: 42),
                        SizedBox(height: 10),
                        Text(
                          '暂未发现需要清理的连拍或高相似照片',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        SizedBox(height: 6),
                        Text(
                          '后台完成离线画面特征提取后，连拍与相似废片会自动汇总到这里供你对比。',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              else
                for (final group in _groups) _buildGroupCard(context, group),
            ],
          ),
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
      padding: const EdgeInsets.only(bottom: 14),
      child: IsleSurface(
        margin: EdgeInsets.zero,
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
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                FilledButton.tonalIcon(
                  onPressed: busy || selectedTrash.isEmpty
                      ? null
                      : () => _trashSelectedInGroup(group),
                  icon: busy
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_outline_rounded, size: 17),
                  label: Text('清理已选 (${selectedTrash.length})'),
                ),
              ],
            ),
            if (group.recommendReason.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                '推荐依据：${group.recommendReason}',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
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
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: 176,
      decoration: BoxDecoration(
        borderRadius: IsleRadius.brItem,
        border: Border.all(
          color: isKeep
              ? const Color(0xFF10B981)
              : isTrash
              ? colors.error
              : colors.outlineVariant,
          width: isKeep || isTrash ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 126,
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
                          fontSize: 11,
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
                  style: Theme.of(context).textTheme.labelMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  '${formatMediaSize(item.size)} · 清晰度 ${(item.sharpness * 100).round()}%',
                  style: Theme.of(context).textTheme.bodySmall,
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
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        child: Text(isKeep ? '保留此张' : '设为保留'),
                      ),
                    ),
                    const SizedBox(width: 6),
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
