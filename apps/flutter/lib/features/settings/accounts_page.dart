import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import '../../core/isle_theme.dart';
import 'account_security_page.dart';
import 'grants_page.dart';
import 'storage_page.dart';

class AccountsPage extends StatefulWidget {
  const AccountsPage({super.key, required this.api, this.currentUsername});
  final LightIsleApi api;
  final String? currentUsername;
  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  List<Map<String, dynamic>> _users = [];
  bool _busy = false, _loaded = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.api.get('/api/v2/users');
      if (mounted) {
        setState(() {
          _users = objectList(result['users']);
          _loaded = true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _NewAccountDialog(api: widget.api),
    );
    if (result == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final created = await widget.api.send(
        'POST',
        '/api/v2/users',
        body: {
          'username': result['username'],
          'password': result['password'],
          'role': result['role'],
        },
      );
      final rootId = result['rootID']?.toString() ?? '';
      final generation = result['rootGeneration'];
      final quotaGiB = result['quotaGiB'];
      final categories = result['categories'];
      final createdId = created['id'];
      if (result['role'] == 'member' &&
          rootId.isNotEmpty &&
          generation is int &&
          quotaGiB is int &&
          createdId is num) {
        await widget.api.send(
          'POST',
          '/api/v2/roots/${Uri.encodeComponent(rootId)}/users/${createdId.toInt()}/storage',
          query: {'rootGeneration': '$generation'},
          body: {
            'quotaBytes': quotaGiB * (1 << 30),
            'categories': categories is List<String> ? categories : <String>[],
          },
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _error == null) await _load();
  }

  Future<void> _toggle(Map<String, dynamic> user) async {
    if (!_canToggle(user)) return;
    if (!await confirmAction(
      context,
      user['enabled'] == true ? '停用账号' : '启用账号',
      '确认更改 ${user['username']} 的登录权限？',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.send(
        'PATCH',
        '/api/v2/users/${user['id']}',
        body: {'enabled': user['enabled'] != true},
      );
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _error == null) await _load();
  }

  bool _canToggle(Map<String, dynamic> user) =>
      user['id']?.toString() != '1' &&
      user['username'] != widget.currentUsername &&
      (user['role'] != 'admin' || widget.currentUsername != null);

  Future<void> _resetPassword(Map<String, dynamic> user) async {
    final reset = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ResetMemberPasswordDialog(api: widget.api, user: user),
    );
    if (mounted && reset == true) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('密码已重置，该成员需要重新登录。')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: IsleAppBar(
      title: const Text('账号与目录授权'),
      actions: [
        IconButton(
          tooltip: '刷新账号',
          onPressed: _busy ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: IsleListView(
      children: [
        if (_error != null) Notice(_error!, error: true, onRetry: _load),
        if (_busy) const LinearProgressIndicator(),
        if (_loaded && _users.isEmpty) const Notice('暂无账号。'),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: FilledButton.icon(
              onPressed: _busy ? null : _create,
              icon: const Icon(Icons.person_add_outlined),
              label: const Text('创建账号'),
            ),
          ),
        ),
        if (_users.isNotEmpty)
          IsleResponsiveGrid(
            minItemWidth: 300,
            maxColumns: 3,
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final user in _users)
                Builder(
                  builder: (context) {
                    final isAdmin = user['role'] == 'admin';
                    final enabled = user['enabled'] == true;
                    final palette = IslePalette.of(context);
                    final actions = <Widget>[
                      if (user['role'] != 'admin')
                        OutlinedButton(
                          onPressed: _busy
                              ? null
                              : () => Navigator.push(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) => StoragePage(
                                      api: widget.api,
                                      isAdmin: true,
                                    ),
                                  ),
                                ),
                          child: const Text('存储与配额'),
                        ),
                      if (user['role'] != 'admin')
                        OutlinedButton(
                          onPressed: _busy
                              ? null
                              : () => Navigator.push(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        GrantsPage(api: widget.api, user: user),
                                  ),
                                ),
                          child: const Text('目录授权'),
                        ),
                      if (user['role'] == 'member' && enabled)
                        OutlinedButton(
                          onPressed: _busy ? null : () => _resetPassword(user),
                          child: const Text('重置密码'),
                        ),
                      if (_canToggle(user))
                        TextButton(
                          onPressed: _busy ? null : () => _toggle(user),
                          style: TextButton.styleFrom(
                            foregroundColor: enabled
                                ? Theme.of(context).colorScheme.error
                                : Theme.of(context).colorScheme.primary,
                          ),
                          child: Text(enabled ? '停用账号' : '启用账号'),
                        ),
                    ];
                    return IsleSurface(
                      radius: 16,
                      margin: EdgeInsets.zero,
                      padding: EdgeInsets.zero,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 4,
                            ),
                            leading: IsleSquircleBadge(
                              icon: isAdmin
                                  ? Icons.shield_outlined
                                  : Icons.person_outline_rounded,
                              color:
                                  palette[isAdmin
                                      ? 'brandBlue'
                                      : 'brandViolet'],
                              size: 36,
                              iconSize: 19,
                            ),
                            title: Text(
                              user['username']?.toString() ?? '',
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            subtitle: Text(
                              '${isAdmin ? '管理员' : '成员'} · ${enabled ? '已启用' : '已停用'}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                            trailing: IsleStatusBadge(
                              label: enabled ? '正常' : '已停用',
                              color: enabled
                                  ? const Color(0xff10b981)
                                  : const Color(0xff64748b),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(58, 0, 14, 10),
                            child: actions.isNotEmpty
                                ? Wrap(
                                    spacing: 8,
                                    runSpacing: 4,
                                    children: actions,
                                  )
                                : Text(
                                    '受保护账号',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                  ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
      ],
    ),
  );
}

class _NewAccountDialog extends StatefulWidget {
  const _NewAccountDialog({required this.api});
  final LightIsleApi api;
  @override
  State<_NewAccountDialog> createState() => _NewAccountDialogState();
}

class _NewAccountDialogState extends State<_NewAccountDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(),
      _password = TextEditingController(),
      _quota = TextEditingController(text: '100');
  String _role = 'member';
  List<Map<String, dynamic>> _onlineRoots = [];
  Map<String, dynamic>? _selectedRoot;
  final Set<String> _selectedCategories = {'files', 'photos', 'videos'};
  static const _categoryLabels = {
    'files': '普通文件',
    'photos': '照片',
    'videos': '视频',
  };

  @override
  void initState() {
    super.initState();
    _loadOnlineRoots();
  }

  Future<void> _loadOnlineRoots() async {
    try {
      final response = await widget.api.get('/api/v2/roots');
      final roots = objectList(
        response['roots'],
      ).where((r) => r['online'] == true).toList(growable: false);
      if (mounted && roots.isNotEmpty) {
        setState(() {
          _onlineRoots = roots;
          _selectedRoot = roots.first;
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    _quota.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('创建账号'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: '用户名（3–32 位）'),
                autocorrect: false,
                validator: (v) =>
                    v == null || !RegExp(r'^[A-Za-z0-9_.-]{3,32}$').hasMatch(v)
                    ? '使用 3–32 位字母、数字、点、下划线或短横线'
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码（至少 12 位）'),
                validator: validateNewPassword,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _role,
                decoration: const InputDecoration(labelText: '角色'),
                items: const [
                  DropdownMenuItem(value: 'member', child: Text('成员')),
                  DropdownMenuItem(value: 'admin', child: Text('管理员')),
                ],
                onChanged: (v) => setState(() => _role = v!),
              ),
              if (_role == 'member') ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _quota,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '初始空间限额 (GiB)',
                    helperText: '分配空间时直接配置限额，后续可自由调整',
                  ),
                  validator: (v) {
                    final parsed = int.tryParse((v ?? '').trim());
                    if (parsed == null || parsed < 0 || parsed > 1048576) {
                      return '请输入 0–1048576 GiB 的有效配额';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final preset in const [50, 100, 200, 500, 1024])
                      ActionChip(
                        label: Text('$preset GiB'),
                        onPressed: () => _quota.text = '$preset',
                      ),
                  ],
                ),
                if (_onlineRoots.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedRoot?['rootID']?.toString(),
                    decoration: const InputDecoration(labelText: '初始分配硬盘'),
                    items: [
                      for (final r in _onlineRoots)
                        DropdownMenuItem(
                          value: r['rootID']?.toString(),
                          child: Text(r['name']?.toString() ?? '硬盘'),
                        ),
                    ],
                    onChanged: (next) {
                      for (final r in _onlineRoots) {
                        if (r['rootID']?.toString() == next) {
                          setState(() => _selectedRoot = r);
                          break;
                        }
                      }
                    },
                  ),
                  const SizedBox(height: 10),
                  const Text('初始创建的专属目录（可稍后再加）：'),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final entry in _categoryLabels.entries)
                        FilterChip(
                          label: Text(entry.value),
                          selected: _selectedCategories.contains(entry.key),
                          onSelected: (checked) => setState(() {
                            if (checked) {
                              _selectedCategories.add(entry.key);
                            } else {
                              _selectedCategories.remove(entry.key);
                            }
                          }),
                        ),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(context, <String, dynamic>{
              'username': _name.text,
              'password': _password.text,
              'role': _role,
              if (_role == 'member') ...{
                'quotaGiB': int.parse(_quota.text.trim()),
                'rootID': _selectedRoot?['rootID']?.toString(),
                'rootGeneration': (_selectedRoot?['generation'] as num?)
                    ?.toInt(),
                'categories': _categoryLabels.keys
                    .where(_selectedCategories.contains)
                    .toList(growable: false),
              },
            });
          }
        },
        child: const Text('创建账号'),
      ),
    ],
  );
}
