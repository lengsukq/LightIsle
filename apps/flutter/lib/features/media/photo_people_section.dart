import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'photo_ai_models.dart';

/// Per-user family & baby face clustering view powered by offline macOS Vision.
/// Tapping a person returns that [PersonSummary] so the caller filters the
/// timeline by `personId`.
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
    final nextName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('命名人物'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(
            labelText: '人物姓名（如「宝宝」「妈妈」）',
            border: OutlineInputBorder(),
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
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('当前没有可合并的其他人物分组。')));
      return;
    }
    int? targetId = candidates.first.id;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('合并「${source.displayName}」'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('将该人物下的所有面孔并入目标人物，方便把同一家人的不同角度照片归为一组：'),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: targetId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '并入目标人物',
                  border: OutlineInputBorder(),
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

  Widget _buildAvatar(BuildContext context, PersonSummary person) {
    final path = person.coverFaceId > 0
        ? '/api/v2/photos/faces/${person.coverFaceId}/thumbnail'
        : person.coverAssetId > 0
        ? '/api/v2/photos/${person.coverAssetId}/thumbnail'
        : '';
    return SizedBox(
      width: 76,
      height: 76,
      child: ClipOval(
        child: path.isEmpty
            ? ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Icon(Icons.face_retouching_natural, size: 34),
              )
            : AuthenticatedMediaImage(
                api: widget.api,
                path: path,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.face_retouching_natural, size: 34),
                ),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inset = IsleLayout.pageInset(MediaQuery.sizeOf(context).width);
    return Scaffold(
      appBar: IsleAppBar(
        title: const Text('人物相册'),
        actions: [
          FilterChip(
            label: const Text('显示已隐藏'),
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
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: EdgeInsets.fromLTRB(inset, 12, inset, 28),
          children: [
            const IsleIntroCard(
              icon: Icons.face_retouching_natural_rounded,
              title: '本地离线人物聚类 · 仅当前账号独立管理',
              description: '由 Mac 本机 Vision 框架离线提取面孔特征并自动归类，照片与人脸特征均不会上传云端。点击任意人物即可筛选其时间线照片。',
            ),
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
            else if (_persons.isEmpty)
              const IsleSurface(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 28, horizontal: 16),
                  child: Column(
                    children: [
                      Icon(Icons.people_outline_rounded, size: 42),
                      SizedBox(height: 10),
                      Text(
                        '暂未识别到人物分组',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      SizedBox(height: 6),
                      Text(
                        '后台离线智能索引完成后，出现频率较高的家人与宝宝面孔会自动归类到这里。',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              )
            else
              IsleResponsiveGrid(
                minItemWidth: 168,
                maxColumns: 5,
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final person in _persons)
                    IsleSurface(
                      margin: EdgeInsets.zero,
                      child: InkWell(
                        borderRadius: IsleRadius.brCard,
                        onTap: _busy
                            ? null
                            : () => Navigator.pop(context, person),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 12,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildAvatar(context, person),
                              const SizedBox(height: 10),
                              Text(
                                person.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${person.photoCount} 张照片${person.hidden ? ' · 已隐藏' : ''}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              const SizedBox(height: 6),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    tooltip: '命名',
                                    onPressed: _busy
                                        ? null
                                        : () => _renamePerson(person),
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      size: 18,
                                    ),
                                  ),
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    tooltip: '合并到其他人物',
                                    onPressed: _busy || _persons.length < 2
                                        ? null
                                        : () => _mergePerson(person),
                                    icon: const Icon(
                                      Icons.merge_type_rounded,
                                      size: 18,
                                    ),
                                  ),
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    tooltip: person.hidden ? '取消隐藏' : '隐藏人物',
                                    onPressed: _busy
                                        ? null
                                        : () => _toggleHidden(person),
                                    icon: Icon(
                                      person.hidden
                                          ? Icons.visibility_outlined
                                          : Icons.visibility_off_outlined,
                                      size: 18,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
