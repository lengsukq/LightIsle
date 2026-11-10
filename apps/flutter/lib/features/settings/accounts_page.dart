import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import '../../core/isle_theme.dart';
import 'account_security_page.dart';
import 'grants_page.dart';
import 'new_account_dialog.dart';
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
    final result = await showDialog<NewAccountDialogResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => NewAccountDialog(api: widget.api),
    );
    if (result == null || !mounted) return;
    if (result.accountCreated) {
      await _load();
      if (mounted && result.warningMessage != null) {
        setState(() => _error = result.warningMessage);
      }
    }
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
        IsleIntroCard(
          icon: Icons.manage_accounts_rounded,
          title: '家庭成员与访问控制',
          description: '为家人创建独立账号，按需分配专属存储空间配额或共享目录的读写权限。',
          actions: [
            FilledButton.icon(
              onPressed: _busy ? null : _create,
              icon: const Icon(Icons.person_add_outlined, size: 18),
              label: const Text('创建账号'),
            ),
          ],
        ),
        if (_error != null) Notice(_error!, error: true, onRetry: _load),
        if (_busy) const LinearProgressIndicator(),
        if (_loaded && _users.isEmpty)
          const IsleEmptyStateCard(
            '暂无账号。',
            icon: Icons.people_outline_rounded,
          ),
        if (_users.isNotEmpty) ...[
          IsleSectionHeader(title: '账号列表（${_users.length}）'),
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
                      OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => Navigator.push(
                                context,
                                MaterialPageRoute<void>(
                                  builder: (_) => StoragePage(
                                    api: widget.api,
                                    isAdmin: true,
                                    initialUserId: (user['id'] as num?)
                                        ?.toInt(),
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
                              '${isAdmin ? '管理员 · 无限配额' : '成员'} · ${enabled ? '已启用' : '已停用'}',
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
      ],
    ),
  );
}
