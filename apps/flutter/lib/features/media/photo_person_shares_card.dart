import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'photo_ai_models.dart';

/// Per-person read-only family/baby auto-sharing panel for [PhotoPeoplePage].
/// Backed by `/api/v2/photos/person-shares*` with zero original file copying.
class PhotoPersonSharesCard extends StatefulWidget {
  const PhotoPersonSharesCard({
    super.key,
    required this.api,
    required this.persons,
  });

  final LightIsleApi api;
  final List<PersonSummary> persons;

  @override
  State<PhotoPersonSharesCard> createState() => _PhotoPersonSharesCardState();
}

class _PhotoPersonSharesCardState extends State<PhotoPersonSharesCard> {
  List<Map<String, dynamic>> _shares = const [];
  List<Map<String, dynamic>> _members = const [];
  int? _selectedPersonId;
  int? _selectedMemberId;
  final TextEditingController _labelCtl = TextEditingController();
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant PhotoPersonSharesCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final validIds = {for (final p in widget.persons) p.id};
    if (!validIds.contains(_selectedPersonId)) {
      _selectedPersonId = widget.persons.isNotEmpty
          ? widget.persons.first.id
          : null;
    }
  }

  @override
  void dispose() {
    _labelCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await widget.api.get('/api/v2/photos/person-shares');
      if (!mounted) return;
      final shares = objectList(res['shares']);
      final members = objectList(res['members']);
      final validPersons = {for (final p in widget.persons) p.id};
      final validMemberIds = <int>{};
      final dedupedMembers = <Map<String, dynamic>>[];
      for (final m in members) {
        final rawId = m['id'];
        if (rawId is num) {
          final id = rawId.toInt();
          if (id > 0 && validMemberIds.add(id)) {
            dedupedMembers.add(m);
          }
        }
      }
      setState(() {
        _shares = shares;
        _members = dedupedMembers;
        if (!validPersons.contains(_selectedPersonId)) {
          _selectedPersonId = widget.persons.isNotEmpty
              ? widget.persons.first.id
              : null;
        }
        if (!validMemberIds.contains(_selectedMemberId)) {
          _selectedMemberId = dedupedMembers.isNotEmpty
              ? (dedupedMembers.first['id'] as num).toInt()
              : null;
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

  Future<void> _createShare() async {
    final personId = _selectedPersonId;
    final memberId = _selectedMemberId;
    if (personId == null || memberId == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await widget.api.send(
        'POST',
        '/api/v2/photos/person-shares',
        body: {
          'personId': personId,
          'memberUserId': memberId,
          'label': _labelCtl.text.trim(),
        },
      );
      _labelCtl.clear();
      if (!mounted) return;
      setState(() => _notice = '已生成人物自动只读共享视图（新备份的同人物照片会自动同步展示，零原片拷贝）。');
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteShare(Map<String, dynamic> item) async {
    final id = item['id'];
    final label = item['label']?.toString() ?? '人物共享';
    final outgoing = item['direction'] == 'outgoing';
    if (id == null || _busy) return;
    final ok = await confirmAction(
      context,
      outgoing ? '撤销人物共享' : '退出人物共享',
      outgoing ? '确认撤销「$label」吗？对方将立即无法查看，你的原始照片不受影响。' : '确认退出「$label」吗？',
      action: outgoing ? '确认撤销' : '退出',
      isDestructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api.send('DELETE', '/api/v2/photos/person-shares/$id');
      if (mounted) await _load();
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openShareGallery(Map<String, dynamic> item) async {
    final shareId = item['id'];
    final label = item['label']?.toString() ?? '共享人物相册';
    if (shareId == null) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: IsleShapes.sheet(
        side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
      ),
      builder: (_) => _SharedPersonAssetsSheet(
        api: widget.api,
        shareId: shareId is num ? shareId.toInt() : 0,
        title: label,
      ),
    );
  }

  Widget _buildGroupedSharesList(
    BuildContext context, {
    required List<Map<String, dynamic>> items,
    required bool incoming,
    required bool isDark,
    required Color borderColor,
    required ColorScheme colors,
  }) {
    return Container(
      decoration: ShapeDecoration(
        shape: IsleShapes.sm(side: BorderSide(color: borderColor, width: 1.0)),
        color: isDark
            ? Colors.white.withValues(alpha: 0.03)
            : colors.surfaceContainerHighest.withValues(alpha: 0.26),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                indent: 46,
                color: borderColor,
              ),
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 2,
              ),
              leading: IsleSquircleBadge(
                icon: incoming
                    ? Icons.photo_album_outlined
                    : Icons.people_alt_outlined,
                color: colors.primary,
                size: 28,
                iconSize: 15,
              ),
              title: Text(
                items[i]['label']?.toString() ?? '',
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                incoming
                    ? '来自 ${items[i]['ownerUsername'] ?? '家人'} · ${items[i]['photoCount'] ?? 0} 张只读照片'
                    : '共享给 ${items[i]['memberUsername'] ?? '成员'} · ${items[i]['photoCount'] ?? 0} 张 · 零拷贝只读',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: Wrap(
                spacing: 4,
                children: [
                  if (incoming)
                    FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        minimumSize: const Size(0, 28),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      onPressed: () => _openShareGallery(items[i]),
                      child: const Text('浏览', style: TextStyle(fontSize: 12)),
                    )
                  else
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        minimumSize: const Size(0, 28),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      onPressed: () => _openShareGallery(items[i]),
                      child: const Text('预览', style: TextStyle(fontSize: 12)),
                    ),
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: _busy ? null : () => _deleteShare(items[i]),
                    child: Text(
                      incoming ? '退出' : '撤销',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = IsleGlass.rimBorderColor(isDark);
    final incoming = _shares
        .where((s) => s['direction'] == 'incoming')
        .toList(growable: false);
    final outgoing = _shares
        .where((s) => s['direction'] == 'outgoing')
        .toList(growable: false);
    final personIds = {for (final p in widget.persons) p.id};
    final activePersonId = personIds.contains(_selectedPersonId)
        ? _selectedPersonId
        : (widget.persons.isNotEmpty ? widget.persons.first.id : null);
    final memberIds = {
      for (final m in _members)
        if (m['id'] is num) (m['id'] as num).toInt(),
    };
    final activeMemberId = memberIds.contains(_selectedMemberId)
        ? _selectedMemberId
        : (memberIds.isNotEmpty ? memberIds.first : null);

    return IsleSurface(
      margin: EdgeInsets.zero,
      radius: IsleRadius.card,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IsleSquircleBadge(
                icon: Icons.family_restroom_rounded,
                color: colors.primary,
                size: 30,
                iconSize: 16,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '宝宝 / 家人自动只读共享视图',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '刷新人物共享',
                onPressed: _loading || _busy ? null : _load,
                icon: const Icon(Icons.refresh_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '将指定人物聚类只读共享给家庭成员，后续备份的新照片会自动出现，无需手动挑图或复制原片。',
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 12,
              color: colors.onSurfaceVariant,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Notice(_error!, error: true),
          ],
          if (_notice != null) ...[const SizedBox(height: 8), Notice(_notice!)],
          if (widget.persons.isNotEmpty && _members.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 186,
                  child: KeyedSubtree(
                    key: ValueKey('personSharePerson_$activePersonId'),
                    child: DropdownButtonFormField<int>(
                      initialValue: activePersonId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '选择人物',
                        isDense: true,
                      ),
                      items: [
                        for (final p in widget.persons)
                          DropdownMenuItem(
                            value: p.id,
                            child: Text(
                              '${p.displayName} (${p.photoCount})',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) => setState(() => _selectedPersonId = v),
                    ),
                  ),
                ),
                SizedBox(
                  width: 160,
                  child: KeyedSubtree(
                    key: ValueKey('personShareMember_$activeMemberId'),
                    child: DropdownButtonFormField<int>(
                      initialValue: activeMemberId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '共享给成员',
                        isDense: true,
                      ),
                      items: [
                        for (final m in _members)
                          if (m['id'] is num)
                            DropdownMenuItem(
                              value: (m['id'] as num).toInt(),
                              child: Text(
                                m['username']?.toString() ?? '',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                      ],
                      onChanged: (v) => setState(() => _selectedMemberId = v),
                    ),
                  ),
                ),
                SizedBox(
                  width: 186,
                  child: TextField(
                    controller: _labelCtl,
                    maxLength: 40,
                    decoration: const InputDecoration(
                      labelText: '共享名称（如宝宝成长册）',
                      counterText: '',
                      isDense: true,
                    ),
                  ),
                ),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _busy ? null : _createShare,
                  icon: const Icon(Icons.share_outlined, size: 16),
                  label: const Text('生成只读共享'),
                ),
              ],
            ),
          ],
          if (_loading && _shares.isEmpty) ...[
            const SizedBox(height: 10),
            const IsleLoadingState(compact: true, label: '正在加载人物共享…'),
          ] else if (_loading) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(minHeight: 2),
          ],
          if (incoming.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              '家人共享给我的人物相册',
              style: theme.textTheme.labelMedium?.copyWith(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            _buildGroupedSharesList(
              context,
              items: incoming,
              incoming: true,
              isDark: isDark,
              borderColor: borderColor,
              colors: colors,
            ),
          ],
          if (outgoing.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              '我共享给家人的人物视图',
              style: theme.textTheme.labelMedium?.copyWith(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            _buildGroupedSharesList(
              context,
              items: outgoing,
              incoming: false,
              isDark: isDark,
              borderColor: borderColor,
              colors: colors,
            ),
          ],
        ],
      ),
    );
  }
}

class _SharedPersonAssetsSheet extends StatefulWidget {
  const _SharedPersonAssetsSheet({
    required this.api,
    required this.shareId,
    required this.title,
  });

  final LightIsleApi api;
  final int shareId;
  final String title;

  @override
  State<_SharedPersonAssetsSheet> createState() =>
      _SharedPersonAssetsSheetState();
}

class _SharedPersonAssetsSheetState extends State<_SharedPersonAssetsSheet> {
  List<Map<String, dynamic>> _assets = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final res = await widget.api.get(
        '/api/v2/photos/person-shares/${widget.shareId}/assets',
        query: const {'limit': '120'},
      );
      if (!mounted) return;
      setState(() {
        _assets = objectList(res['assets']);
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

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.78,
      maxChildSize: 0.94,
      builder: (context, controller) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '关闭人物照片预览',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Expanded(
                child: IsleLoadingState(compact: true, label: '正在加载照片…'),
              )
            else if (_error != null)
              Notice(_error!, error: true, onRetry: _load)
            else if (_assets.isEmpty)
              const Expanded(child: Center(child: Text('当前时间范围内暂无已识别照片。')))
            else
              Expanded(
                child: GridView.builder(
                  controller: controller,
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 128,
                    mainAxisSpacing: 4,
                    crossAxisSpacing: 4,
                  ),
                  itemCount: _assets.length,
                  itemBuilder: (context, idx) {
                    final item = _assets[idx];
                    final id = item['id'];
                    final isLive =
                        item['liveVideoAssetId'] is num &&
                        (item['liveVideoAssetId'] as num) > 0;
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          AuthenticatedMediaImage(
                            api: widget.api,
                            path:
                                '/api/v2/photos/person-shares/${widget.shareId}/assets/$id/thumbnail',
                            fit: BoxFit.cover,
                          ),
                          if (isLive)
                            Positioned(
                              top: 4,
                              left: 4,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 1.5,
                                  ),
                                  child: Text(
                                    'LIVE',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
