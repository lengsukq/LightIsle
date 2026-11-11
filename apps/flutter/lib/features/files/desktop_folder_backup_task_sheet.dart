import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/personal_storage_routing.dart';
import '../../core/user_facing_error.dart';
import 'desktop_backup_engine.dart';
import 'desktop_backup_models.dart';
import 'file_name_validation.dart';
import 'isle_folder_picker_sheet.dart';

Future<DesktopBackupTask?> showDesktopBackupTaskDialog(
  BuildContext context, {
  required LightIsleApi api,
  required bool isAdmin,
  required DesktopDirectoryAccess directoryAccess,
  DesktopBackupTask? existing,
}) {
  return showDialog<DesktopBackupTask>(
    context: context,
    builder: (_) => _DesktopBackupTaskDialog(
      api: api,
      isAdmin: isAdmin,
      directoryAccess: directoryAccess,
      existing: existing,
    ),
  );
}

class _DesktopBackupTaskDialog extends StatefulWidget {
  const _DesktopBackupTaskDialog({
    required this.api,
    required this.isAdmin,
    required this.directoryAccess,
    this.existing,
  });

  final LightIsleApi api;
  final bool isAdmin;
  final DesktopDirectoryAccess directoryAccess;
  final DesktopBackupTask? existing;

  @override
  State<_DesktopBackupTaskDialog> createState() =>
      _DesktopBackupTaskDialogState();
}

class _DesktopBackupTaskDialogState extends State<_DesktopBackupTaskDialog> {
  late final TextEditingController _labelController = TextEditingController(
    text: widget.existing?.label ?? '',
  );

  String _localPath = '';
  String? _bookmarkBase64;
  List<LightIsleRoot> _onlineRoots = const <LightIsleRoot>[];
  LightIsleRoot? _selectedRoot;
  String _directory = '.';
  bool _appendFolderName = true;
  DesktopConflictPolicy _conflictPolicy = DesktopConflictPolicy.trashAndReplace;
  bool _ignoreHidden = true;

  bool _initializing = true;
  bool _loadingFolder = false;
  bool _canWrite = false;
  String _cursor = '';
  String? _error;
  int _browseGeneration = 0;
  final List<(String, String)> _folders = <(String, String)>[];

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing != null) {
      _localPath = existing.localPath;
      _bookmarkBase64 = existing.bookmarkBase64;
      _appendFolderName = false;
      _conflictPolicy = existing.conflictPolicy;
      _ignoreHidden = existing.ignoreHidden;
    }
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    ++_browseGeneration;
    _labelController.dispose();
    super.dispose();
  }

  String get _localFolderBasename {
    if (_localPath.isEmpty) return '';
    var p = _localPath;
    while (p.length > 1 && (p.endsWith('/') || p.endsWith('\\'))) {
      p = p.substring(0, p.length - 1);
    }
    final idx = max(p.lastIndexOf('/'), p.lastIndexOf('\\'));
    final raw = idx < 0 ? p : p.substring(idx + 1);
    return validateFileName(raw) == null ? raw : '';
  }

  String get _effectiveRemoteBasePath {
    if (!_appendFolderName) return _directory;
    final sub = _localFolderBasename;
    if (sub.isEmpty) return _directory;
    if (_directory == '.') return sub;
    if (_directory == sub || _directory.endsWith('/$sub')) return _directory;
    return '$_directory/$sub';
  }

  String _rootFilesPath(LightIsleRoot root, [String suffix = '']) =>
      '/api/v2/roots/${Uri.encodeComponent(root.id)}/files$suffix';

  Future<void> _bootstrap() async {
    setState(() {
      _initializing = true;
      _error = null;
    });
    try {
      final rootsResp = await widget.api.get('/api/v2/roots');
      final rawRoots = rootsResp['roots'];
      final allRoots = rawRoots is List
          ? rawRoots
                .whereType<Map>()
                .map(
                  (m) => LightIsleRoot.fromJson(Map<String, dynamic>.from(m)),
                )
                .toList(growable: false)
          : const <LightIsleRoot>[];
      final online = allRoots.where((r) => r.online).toList(growable: false);
      final policy = await widget.api.get('/api/v2/me/storage');
      if (!mounted) return;
      if (online.isEmpty) {
        setState(() {
          _onlineRoots = const <LightIsleRoot>[];
          _initializing = false;
          _error = '当前没有在线的 NAS 存储卷，请先连接并启用存储硬盘。';
        });
        return;
      }

      final personalFiles = resolvePersonalRoute(policy, allRoots, 'files');
      LightIsleRoot? chosenRoot;
      var initialDir = '.';

      if (widget.existing != null) {
        chosenRoot = online
            .where((r) => r.id == widget.existing!.rootId)
            .firstOrNull;
        initialDir = widget.existing!.remoteBasePath;
      }
      if (chosenRoot == null &&
          personalFiles.kind == PersonalRouteKind.personal &&
          personalFiles.root != null) {
        chosenRoot = personalFiles.root;
        if (widget.existing == null && personalFiles.path != null) {
          initialDir = personalFiles.path!;
        }
      }
      chosenRoot ??=
          online.where((r) => r.isDefault).firstOrNull ?? online.first;

      setState(() {
        _onlineRoots = online;
        _selectedRoot = chosenRoot;
        _directory = initialDir;
        _initializing = false;
      });
      await _loadDirectory(fallbackToRootOnMissing: true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _initializing = false;
          _error = '加载存储位置失败：${userFacingError(error)}';
        });
      }
    }
  }

  Future<void> _loadDirectory({
    bool more = false,
    bool fallbackToRootOnMissing = false,
  }) async {
    final root = _selectedRoot;
    if (root == null) return;
    final gen = ++_browseGeneration;
    final dir = _directory;
    setState(() {
      _loadingFolder = true;
      _error = null;
    });
    try {
      final data = await widget.api.get(
        _rootFilesPath(root),
        query: <String, String>{
          'rootGeneration': '${root.generation}',
          'path': dir,
          'limit': '100',
          'cursor': more ? _cursor : '',
        },
      );
      if (!mounted || gen != _browseGeneration) return;
      final entries = (data['entries'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map>()
          .where((e) => e['type'] == 'folder')
          .map(
            (e) => (e['name']?.toString() ?? '', e['path']?.toString() ?? ''),
          )
          .where((e) => e.$1.isNotEmpty && e.$2.isNotEmpty)
          .toList(growable: false);
      setState(() {
        if (!more) _folders.clear();
        _folders.addAll(entries);
        _cursor = data['nextCursor']?.toString() ?? '';
        _canWrite = data['canWrite'] == true;
        _loadingFolder = false;
      });
    } on LightIsleApiException catch (error) {
      if (!mounted || gen != _browseGeneration) return;
      if (fallbackToRootOnMissing && error.statusCode == 404 && dir != '.') {
        setState(() => _directory = '.');
        await _loadDirectory();
        return;
      }
      setState(() {
        _loadingFolder = false;
        _error = '目录读取失败：${error.message}';
      });
    } catch (error) {
      if (mounted && gen == _browseGeneration) {
        setState(() {
          _loadingFolder = false;
          _error = '目录读取失败：${userFacingError(error)}';
        });
      }
    }
  }

  Future<void> _browse(String nextDir) async {
    setState(() {
      _directory = nextDir;
      _cursor = '';
      _folders.clear();
      _canWrite = false;
    });
    await _loadDirectory();
  }

  Future<void> _pickLocalFolder() async {
    try {
      final picked = await widget.directoryAccess.pickDirectory();
      if (picked == null || !mounted) return;
      setState(() {
        _localPath = picked.path;
        _bookmarkBase64 = picked.bookmarkBase64;
        if (_labelController.text.trim().isEmpty) {
          final base = _localFolderBasename;
          if (base.isNotEmpty) _labelController.text = base;
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = '选择本机文件夹失败：${userFacingError(error)}');
      }
    }
  }

  Future<void> _createSubfolder() async {
    final root = _selectedRoot;
    if (root == null || !_canWrite || _loadingFolder) return;
    var input = '';
    String? validation;
    final folderName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          void submit() {
            final value = input.trim();
            final issue = validateFileName(value);
            if (issue != null) {
              setDialogState(() => validation = issue);
            } else {
              Navigator.pop(dialogContext, value);
            }
          }

          return AlertDialog(
            title: const Text('新建 NAS 目标子文件夹'),
            content: TextField(
              autofocus: true,
              maxLength: 150,
              onChanged: (v) {
                input = v;
                if (validation != null) setDialogState(() => validation = null);
              },
              onSubmitted: (_) => submit(),
              decoration: InputDecoration(
                labelText: '文件夹名称',
                errorText: validation,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              FilledButton(onPressed: submit, child: const Text('创建')),
            ],
          );
        },
      ),
    );
    if (folderName == null || !mounted) return;
    final targetPath = _directory == '.'
        ? folderName
        : '$_directory/$folderName';
    setState(() {
      _loadingFolder = true;
      _error = null;
    });
    try {
      await widget.api.send(
        'POST',
        _rootFilesPath(root, '/folders'),
        query: <String, String>{'rootGeneration': '${root.generation}'},
        body: <String, Object?>{'path': targetPath},
      );
      if (mounted) {
        setState(() => _appendFolderName = false);
        await _browse(targetPath);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _loadingFolder = false;
          _error = '创建文件夹失败：${userFacingError(error)}';
        });
      }
    }
  }

  String? get _formValidationError {
    if (_localPath.trim().isEmpty) return '请先选择本机源文件夹';
    if (_selectedRoot == null) return '请选择在线的 NAS 存储卷';
    final label = _labelController.text.trim();
    if (label.isEmpty || label.runes.length > 60) {
      return '任务名称需为 1–60 个字符';
    }
    if (!_canWrite) return '当前选择的 NAS 目录无写入权限，请选择可写目录';
    final target = _effectiveRemoteBasePath;
    if (target != '.' && validateRelativePath(target) != null) {
      return validateRelativePath(target);
    }
    return null;
  }

  void _save() {
    final issue = _formValidationError;
    if (issue != null) {
      setState(() => _error = issue);
      return;
    }
    final root = _selectedRoot!;
    final existing = widget.existing;
    final id =
        existing?.id ??
        'task-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 20)}';
    final result = DesktopBackupTask(
      id: id,
      label: _labelController.text.trim(),
      localPath: _localPath.trim(),
      bookmarkBase64: _bookmarkBase64,
      rootId: root.id,
      rootGeneration: root.generation,
      rootName: root.name,
      remoteBasePath: _effectiveRemoteBasePath,
      conflictPolicy: _conflictPolicy,
      ignoreHidden: _ignoreHidden,
      enabled: existing?.enabled ?? true,
      lastRunAtMs: existing?.lastRunAtMs ?? 0,
      lastCompleteAtMs: existing?.lastCompleteAtMs ?? 0,
      lastSummary: existing?.lastSummary,
      lastSkippedSymlinks: existing?.lastSkippedSymlinks ?? 0,
    );
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final parts = _directory == '.' ? <String>[] : _directory.split('/');
    final breadcrumbs = <(String, String)>[('根目录', '.')];
    for (var i = 0; i < parts.length; i++) {
      breadcrumbs.add((parts[i], parts.take(i + 1).join('/')));
    }

    return AlertDialog(
      title: Text(widget.existing == null ? '新建本机文件夹备份' : '编辑备份任务'),
      content: SizedBox(
        width: 540,
        child: _initializing
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 36),
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('pickLocalBackupFolderButton'),
                      onPressed: _pickLocalFolder,
                      icon: const Icon(Icons.folder_open_rounded),
                      label: Text(
                        _localPath.isEmpty ? '选择本机源文件夹…' : '重新选择本机源文件夹',
                      ),
                    ),
                    if (_localPath.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      SelectableText(
                        '本机来源：$_localPath',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: _labelController,
                      maxLength: 60,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: '备份任务名称',
                        hintText: '例如：工作文档 / 桌面项目',
                        counterText: '',
                      ),
                    ),
                    if (widget.isAdmin && _onlineRoots.length > 1) ...[
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: _selectedRoot?.id,
                        decoration: const InputDecoration(
                          labelText: '目标 NAS 存储硬盘',
                        ),
                        items: [
                          for (final root in _onlineRoots)
                            DropdownMenuItem<String>(
                              value: root.id,
                              child: Text(
                                '${root.name} (代数 ${root.generation})',
                              ),
                            ),
                        ],
                        onChanged: (nextId) {
                          final found = _onlineRoots
                              .where((r) => r.id == nextId)
                              .firstOrNull;
                          if (found == null) return;
                          setState(() {
                            _selectedRoot = found;
                            _directory = '.';
                            _cursor = '';
                            _folders.clear();
                          });
                          unawaited(_loadDirectory());
                        },
                      ),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      'NAS 目标位置（仅单向新增与更新，绝不删除 NAS 已有文件）',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 8),
                    IsleFolderBrowserCard(
                      directory: _directory,
                      breadcrumbs: breadcrumbs,
                      folders: _folders,
                      canWrite: _canWrite,
                      loading: _loadingFolder,
                      hasMore: _cursor.isNotEmpty,
                      onBrowse: _browse,
                      onLoadMore: () => _loadDirectory(more: true),
                      onCreateSubfolder: _createSubfolder,
                    ),
                    if (_localFolderBasename.isNotEmpty)
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text('在当前目录下自动归入「$_localFolderBasename」子文件夹'),
                        value: _appendFolderName,
                        onChanged: (v) => setState(() => _appendFolderName = v),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 8),
                      child: Text(
                        '最终写入路径：/${_effectiveRemoteBasePath == '.' ? '' : _effectiveRemoteBasePath}',
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    DropdownButtonFormField<DesktopConflictPolicy>(
                      initialValue: _conflictPolicy,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '同名文件修改策略'),
                      items: [
                        for (final policy in DesktopConflictPolicy.values)
                          DropdownMenuItem<DesktopConflictPolicy>(
                            value: policy,
                            child: Text(
                              policy.label,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _conflictPolicy = v);
                      },
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('忽略以 . 开头的隐藏文件与系统缓存'),
                      value: _ignoreHidden,
                      onChanged: (v) => setState(() => _ignoreHidden = v),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('saveDesktopBackupTaskButton'),
          onPressed:
              _initializing || _loadingFolder || _formValidationError != null
              ? null
              : _save,
          child: const Text('保存任务'),
        ),
      ],
    );
  }
}
