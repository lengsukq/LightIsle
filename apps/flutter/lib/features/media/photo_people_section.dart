import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_action_menu.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'photo_ai_models.dart';
import 'photo_person_shares_card.dart';

/// Per-user family & baby face clustering view powered by offline macOS Vision.
class PhotoPeoplePage extends StatefulWidget {
  const PhotoPeoplePage({required this.api, super.key});

  final LightIsleApi api;

  @override
  State<PhotoPeoplePage> createState() => _PhotoPeoplePageState();
}

class _PhotoPeoplePageState extends State<PhotoPeoplePage> {
  PhotoAIRepository get _repo => PhotoAIRepository(widget.api);

  List<PersonSummary> _persons = const [];
  bool _loading = true;
  bool _busy = false;
  bool _includeHidden = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _load() async {
    final gen = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _repo.listPersons(includeHidden: _includeHidden);
      if (!mounted || gen != _generation) return;
      setState(() {
        _persons = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _error = userFacingError(e);
        _loading = false;
      });
    }
  }

  Future<void> _renamePerson(PersonSummary person) async {
    final controller = TextEditingController(text: person.name);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final nextName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: IsleShapes.card(
          side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
        ),
        title: const Text('命名人物'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(
            isDense: true,
            labelText: '人物姓名（如「宝宝」「妈妈」）',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (nextName == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _repo.updatePerson(person.id, name: nextName);
      if (mounted) await _load();
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleHidden(PersonSummary person) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _repo.updatePerson(person.id, hidden: !person.hidden);
      if (mounted) await _load();
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _mergePerson(PersonSummary source) async {
    final candidates = _persons
        .where((p) => p.id != source.id)
        .toList(growable: false);
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前没有可合并的其他人物分组。')));
      return;
    }
    int? targetId = candidates.first.id;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: IsleShapes.card(
            side: BorderSide(
              color: IsleGlass.rimBorderColor(isDark),
              width: 1.0,
            ),
          ),
          title: Text('合并「${source.displayName}」'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '将该人物下的所有面孔并入目标人物：',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: targetId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '并入目标人物',
                  ),
                  items: [
                    for (final candidate in candidates)
                      DropdownMenuItem(
                        value: candidate.id,
                        child: Text(
                          '${candidate.displayName}（${candidate.photoCount} 张）',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) => setDialogState(() => targetId = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: targetId == null
                  ? null
                  : () => Navigator.pop(dialogContext, true),
              child: const Text('确认合并'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || targetId == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _repo.mergePerson(
        sourcePersonId: source.id,
        targetPersonId: targetId!,
      );
      if (mounted) await _load();
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _buildAvatar(BuildContext context, PersonSummary person, double size) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = IslePalette.of(context);
    final rose = palette['brandRose'];
    final path = person.coverFaceId > 0
        ? '/api/v2/photos/faces/${person.coverFaceId}/thumbnail'
        : person.coverAssetId > 0
        ? '/api/v2/photos/${person.coverAssetId}/thumbnail'
        : '';
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: person.name.isNotEmpty
              ? rose.withValues(alpha: 0.48)
              : IsleGlass.rimBorderColor(isDark),
          width: 1.3,
        ),
        boxShadow: IsleShadows.subtle(isDark),
      ),
      child: ClipOval(
        child: path.isEmpty
            ? ColoredBox(
                color: palette['cardItemBottom'],
                child: const Icon(Icons.face_retouching_natural, size: 28),
              )
            : AuthenticatedMediaImage(
                api: widget.api,
                path: path,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => ColoredBox(
                  color: palette['cardItemBottom'],
                  child: const Icon(Icons.face_retouching_natural, size: 28),
                ),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette.of(context);
    final borderColor = IsleGlass.rimBorderColor(isDark);
    final rose = palette['brandRose'];
    final namedCount = _persons.where((p) => p.name.trim().isNotEmpty).length;
    final totalAppearances = _persons.fold<int>(
      0,
      (sum, p) => sum + p.photoCount,
    );

    return Scaffold(
      appBar: IsleAppBar(
        title: const Text('人物相册'),
        actions: [
          FilterChip(
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            side: BorderSide(
              color: _includeHidden
                  ? colors.primary.withValues(alpha: 0.45)
                  : borderColor,
              width: 1.0,
            ),
            label: const Text('显示已隐藏', style: TextStyle(fontSize: 12)),
            selected: _includeHidden,
            onSelected: _loading || _busy
                ? null
                : (v) {
                    setState(() => _includeHidden = v);
                    unawaited(_load());
                  },
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: '刷新人物分组',
            onPressed: _loading || _busy ? null : _load,
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
        ],
      ),
      body: IsleListView(
        maxWidth: IsleLayout.workbenchMaxWidth,
        children: [
          IsleFocalStage(
            icon: Icons.face_retouching_natural_rounded,
            accent: rose,
            title: '人物肖像馆',
            metrics: [
              IsleFocalMetric(
                label: '人物分组',
                value: '${_persons.length}',
                accent: rose,
              ),
              IsleFocalMetric(
                label: '已命名',
                value: '$namedCount',
                accent: palette['brandAmber'],
              ),
              IsleFocalMetric(
                label: '累计肖像',
                value: '$totalAppearances',
                accent: palette['brandSage'],
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_error != null)
            Notice(_error!, error: true, onRetry: _loading ? null : _load),
          if (_loading)
            const IsleLoadingState(compact: true, label: '正在读取人物相册…')
          else if (_persons.isEmpty)
            const IsleEmptyStateCard(
              '离线智能索引完成后，常出现的面孔会自动归类到这里。',
              title: '暂未识别到人物分组',
              icon: Icons.people_outline_rounded,
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final avatarSize = constraints.maxWidth >= 720 ? 74.0 : 64.0;
                return IsleResponsiveGrid(
                  minItemWidth: constraints.maxWidth >= 720 ? 168 : 144,
                  maxColumns: 6,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final person in _persons)
                      IsleSurface(
                        margin: EdgeInsets.zero,
                        radius: IsleRadius.card,
                        padding: EdgeInsets.zero,
                        child: Stack(
                          children: [
                            InkWell(
                              borderRadius: IsleRadius.brCard,
                              onTap: _busy
                                  ? null
                                  : () => Navigator.pop(context, person),
                              child: SizedBox(
                                width: double.infinity,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    16,
                                    12,
                                    14,
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _buildAvatar(context, person, avatarSize),
                                      const SizedBox(height: 10),
                                      Text(
                                        person.displayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleSmall
                                            ?.copyWith(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w800,
                                            ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${person.photoCount} 张${person.hidden ? ' · 已隐藏' : ''}',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              fontSize: 11.5,
                                              color: colors.onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              top: 4,
                              right: 4,
                              child: PopupMenuButton<String>(
                                tooltip: '人物操作',
                                enabled: !_busy,
                                icon: Icon(
                                  Icons.more_horiz_rounded,
                                  size: 17,
                                  color: colors.onSurfaceVariant,
                                ),
                                style: IconButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  minimumSize: const Size(28, 28),
                                  padding: EdgeInsets.zero,
                                ),
                                shape: IsleShapes.md(
                                  side: BorderSide(
                                    color: borderColor,
                                    width: 1.0,
                                  ),
                                ),
                                onSelected: (action) {
                                  switch (action) {
                                    case 'rename':
                                      _renamePerson(person);
                                    case 'merge':
                                      _mergePerson(person);
                                    case 'hide':
                                      _toggleHidden(person);
                                  }
                                },
                                itemBuilder: (_) => [
                                  isleActionMenuItem(
                                    value: 'rename',
                                    icon: Icons.edit_outlined,
                                    label: '命名',
                                  ),
                                  if (_persons.length >= 2)
                                    isleActionMenuItem(
                                      value: 'merge',
                                      icon: Icons.merge_type_rounded,
                                      label: '合并到其他人物',
                                    ),
                                  isleActionMenuItem(
                                    value: 'hide',
                                    icon: person.hidden
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                    label: person.hidden ? '取消隐藏' : '隐藏人物',
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
          const SizedBox(height: 16),
          PhotoPersonSharesCard(api: widget.api, persons: _persons),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}
