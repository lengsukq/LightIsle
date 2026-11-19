import 'package:flutter/material.dart';

import '../../core/isle_gallery_layout.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import '../files/file_destination_dialog.dart';

class GrantsPage extends StatefulWidget {
  const GrantsPage({super.key, required this.api, required this.user});
  final LightIsleApi api;
  final Map<String, dynamic> user;
  @override
  State<GrantsPage> createState() => _GrantsPageState();
}

class _GrantsPageState extends State<GrantsPage> {
  List<Map<String, dynamic>> _grants = [];
  final _path = TextEditingController();
  late final LightIsleRoot? _entryRoot;
  LightIsleRoot? _grantRoot;
  List<LightIsleRoot> _availableRoots = const [];
  bool _rootsReady = false;
  String? _rootLoadError;
  bool _write = false, _busy = false;
  String? _error;

  String get _endpoint {
    final userPath = '/users/${widget.user['id']}/file-grants';
    final root = _grantRoot;
    return root == null
        ? '/api/v2$userPath'
        : '/api/v2/roots/${Uri.encodeComponent(root.id)}$userPath';
  }

  Map<String, String>? get _rootQuery {
    final root = _grantRoot;
    return root == null ? null : {'rootGeneration': '${root.generation}'};
  }

  bool get _rootIsCurrent =>
      widget.api.selectedRoot?.identity == _grantRoot?.identity;

  Future<void> _loadRoots() async {
    try {
      final response = await widget.api.get('/api/v2/roots');
      final discovered = (response['roots'] as List)
          .map(
            (row) =>
                LightIsleRoot.fromJson(Map<String, dynamic>.from(row as Map)),
          )
          .where((root) => root.online)
          .toList(growable: false);
      if (!mounted) return;
      setState(() {
        _availableRoots = discovered;
        _rootsReady = true;
        _rootLoadError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _rootsReady = false;
        _rootLoadError = '无法核实可用硬盘，请重试：${userFacingError(error)}';
      });
    }
  }

  Future<void> _chooseGrantRoot(LightIsleRoot? next) async {
    if (_busy || !_rootsReady || !_rootIsCurrent) return;
    if (next != null &&
        !_availableRoots.any(
          (item) => item.identity == next.identity && item.online,
        )) {
      return;
    }
    if (next?.identity == _grantRoot?.identity) return;
    widget.api.selectRoot(next);
    _path.clear();
    setState(() {
      _grantRoot = next;
      _grants = [];
      _error = null;
    });
    await _load();
  }

  Future<void> _browseGrantFolder() async {
    if (!_rootIsCurrent) {
      setState(() => _error = '硬盘已切换，请关闭授权页面后重新进入。');
      return;
    }
    final selection = await showDialog<FileDestinationSelection>(
      context: context,
      builder: (_) => FileDestinationDialog(
        api: widget.api,
        action: 'grant',
        sourceName: '',
        sourcePath: '',
        directoryOnly: true,
      ),
    );
    if (!mounted || selection == null || !_rootIsCurrent) return;
    setState(() => _path.text = selection.path);
  }

  Future<void> _promptManualPath() async {
    if (_busy) return;
    final temp = TextEditingController(text: _path.text);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final submitted = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: IsleShapes.card(
          side: BorderSide(color: IsleGlass.rimBorderColor(isDark)),
        ),
        title: const Text('输入相对目录路径'),
        content: TextField(
          controller: temp,
          autofocus: true,
          decoration: const InputDecoration(
            isDense: true,
            labelText: '相对目录路径',
            hintText: '如：照片/旅行，或填 . 代表整盘根目录',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(temp.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    temp.dispose();
    if (submitted == null || !mounted) return;
    setState(() => _path.text = submitted);
  }

  @override
  void initState() {
    super.initState();
    _grantRoot = widget.api.selectedRoot;
    _entryRoot = _grantRoot;
    _load();
    _loadRoots();
  }

  @override
  void dispose() {
    if (_rootIsCurrent) widget.api.selectRoot(_entryRoot);
    _path.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!_rootIsCurrent) throw StateError('硬盘已切换，请重新进入授权页面。');
      final r = await widget.api.get(_endpoint, query: _rootQuery);
      if (mounted && _rootIsCurrent) {
        setState(() => _grants = objectList(r['grants']));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = userFacingError(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save({String? remove}) async {
    if (!_rootIsCurrent) {
      setState(() => _error = '硬盘已切换，请重新进入授权页面。');
      return;
    }
    final path = remove ?? _path.text.trim();
    if (path.isEmpty) {
      setState(() => _error = '请输入相对共享目录的路径，全部目录填 .');
      return;
    }
    if (remove != null &&
        !await confirmAction(
          context,
          '撤销目录授权',
          '撤销对 $path 的访问权限？',
          action: '撤销',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (remove != null) {
        await widget.api.send(
          'DELETE',
          _endpoint,
          query: {...?_rootQuery, 'path': path},
        );
      } else {
        await widget.api.send(
          'PUT',
          _endpoint,
          query: _rootQuery,
          body: {'path': path, 'canWrite': _write},
        );
        _path.clear();
      }
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _error == null) await _load();
  }

  Widget _buildConfigCard(BuildContext context, IslePalette palette) {
    final amber = palette['brandAmber'];
    return IsleSurface(
      tint: amber,
      radius: IsleRadius.hero,
      padding: const EdgeInsets.all(18),
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IsleSquircleBadge(
                icon: Icons.folder_shared_rounded,
                color: amber,
                size: 36,
                iconSize: 18,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '新增目录授权',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      '当前授权范围：${_grantRoot?.name ?? "默认共享目录"}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_rootsReady) ...[
            DropdownButtonFormField<String>(
              key: ValueKey('grant-root-${_grantRoot?.identity ?? 'default'}'),
              isExpanded: true,
              initialValue: _grantRoot?.identity ?? '',
              decoration: const InputDecoration(
                labelText: '目标硬盘',
                prefixIcon: Icon(Icons.storage_rounded),
              ),
              items: [
                const DropdownMenuItem(
                  value: '',
                  child: Text(
                    '默认共享目录',
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                for (final root in _availableRoots)
                  DropdownMenuItem(
                    value: root.identity,
                    child: Text(
                      root.name,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                if (_grantRoot != null &&
                    !_availableRoots.any(
                      (r) => r.identity == _grantRoot!.identity,
                    ))
                  DropdownMenuItem(
                    value: _grantRoot!.identity,
                    enabled: false,
                    child: Text(
                      '${_grantRoot!.name}（当前不可用）',
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (value) {
                      if (value == null) return;
                      final next = _availableRoots
                          .where((r) => r.identity == value)
                          .firstOrNull;
                      if (value.isEmpty || next != null) {
                        _chooseGrantRoot(next);
                      }
                    },
            ),
            const SizedBox(height: 12),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _browseGrantFolder,
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: const Text('浏览并选择文件夹'),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: _busy ? null : _promptManualPath,
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('手动输入路径'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          IsleCodePill(
            _path.text.trim().isEmpty
                ? '尚未选择文件夹'
                : '已选择：${_path.text.trim() == '.' ? '根目录（所有文件）' : _path.text.trim()}',
            icon: Icons.subdirectory_arrow_right_rounded,
          ),
          const SizedBox(height: 6),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('允许写入'),
            value: _write,
            onChanged: _busy ? null : (v) => setState(() => _write = v),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: _busy ? null : () => _save(),
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('保存授权'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGrantsColumn(BuildContext context, IslePalette palette) {
    final mineral = palette['brandBlue'];
    final sage = palette['brandSage'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IsleSectionHeader(
          title: '已生效授权（${_grants.length}）',
          accentColor: mineral,
        ),
        if (_grants.isNotEmpty)
          IsleGroupCard(
            margin: EdgeInsets.zero,
            children: [
              for (final g in _grants)
                ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 3,
                  ),
                  leading: IsleSquircleBadge(
                    icon: g['canWrite'] == true
                        ? Icons.edit_note_rounded
                        : Icons.visibility_outlined,
                    color: g['canWrite'] == true ? sage : mineral,
                    size: 32,
                    iconSize: 17,
                  ),
                  title: Text(
                    g['path']?.toString() ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(g['canWrite'] == true ? '读写' : '只读'),
                  trailing: IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '撤销授权',
                    onPressed: _busy
                        ? null
                        : () => _save(remove: g['path'].toString()),
                    icon: const Icon(Icons.remove_circle_outline, size: 19),
                  ),
                ),
            ],
          )
        else if (!_busy)
          const IsleEmptyStateCard(
            '尚未创建目录授权。',
            icon: Icons.folder_off_outlined,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    return Scaffold(
      appBar: IsleAppBar(
        title: Text('${widget.user['username']} · 目录授权'),
        actions: [
          IsleHelpButton(
            title: '目录授权边界说明',
            accentColor: palette['brandAmber'],
            items: const [
              IsleHelpItem(
                title: '路径继承与整盘授权',
                body: '授权某个文件夹后，该成员即可访问其中的子目录；填入 . 代表授权当前所选硬盘的整个共享根目录。',
              ),
              IsleHelpItem(
                title: '成员私人空间隔离',
                body: '每位成员已分配的个人专属存储空间默认受系统隔离保护，无需通过公共目录授权单独开放。',
              ),
            ],
          ),
        ],
      ),
      body: IsleListView(
        maxWidth: IsleLayout.workbenchMaxWidth,
        children: [
          if (_rootLoadError != null)
            Notice(_rootLoadError!, error: true, onRetry: _loadRoots),
          if (_error != null) Notice(_error!, error: true, onRetry: _load),
          if (_busy) const LinearProgressIndicator(),
          IsleWorkbenchSplit(
            breakpoint: 860,
            primaryFlex: 6,
            secondaryFlex: 6,
            primary: _buildConfigCard(context, palette),
            secondary: _buildGrantsColumn(context, palette),
          ),
        ],
      ),
    );
  }
}
