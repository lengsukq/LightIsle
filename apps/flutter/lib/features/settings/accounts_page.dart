import 'package:flutter/material.dart';

import '../../core/isle_action_menu.dart';
import '../../core/isle_gallery_layout.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
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
    final result = await showIsleDialog<NewAccountDialogResult>(
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
    final reset = await showIsleDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ResetMemberPasswordDialog(api: widget.api, user: user),
    );
    if (mounted && reset == true) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('密码已重置，该成员需要重新登录。')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = IslePalette(isDark);
    final borderColor = IsleGlass.rimBorderColor(isDark);
    final mineral = palette['brandBlue'];
    final sage = palette['brandSage'];
    final violet = palette['brandViolet'];
    final activeCount = _users.where((u) => u['enabled'] == true).length;
    final memberCount = _users.where((u) => u['role'] != 'admin').length;

    return Scaffold(
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
        maxWidth: IsleLayout.workbenchMaxWidth,
        children: [
          IsleFocalStage(
            icon: Icons.manage_accounts_rounded,
            accent: mineral,
            title: '家庭成员与访问控制',
            metrics: [
              IsleFocalMetric(
                label: '全部账号',
                value: '${_users.length}',
                accent: mineral,
              ),
              IsleFocalMetric(
                label: '家庭成员',
                value: '$memberCount',
                accent: violet,
              ),
              IsleFocalMetric(
                label: '已启用',
                value: '$activeCount',
                accent: sage,
              ),
            ],
            actions: [
              FilledButton.icon(
                onPressed: _busy ? null : _create,
                icon: const Icon(Icons.person_add_outlined, size: 18),
                label: const Text('创建账号'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_error != null) Notice(_error!, error: true, onRetry: _load),
          if (_busy && !_loaded)
            const IsleLoadingState(label: '正在加载账号列表…')
          else if (_busy)
            const LinearProgressIndicator(),
          if (_loaded && _users.isEmpty && !_busy)
            const IsleEmptyStateCard(
              '暂无账号。',
              icon: Icons.people_outline_rounded,
            ),
          if (_users.isNotEmpty) ...[
            IsleSectionHeader(
              title: '账号列表（${_users.length}）',
              accentColor: mineral,
            ),
            IsleResponsiveGrid(
              minItemWidth: 330,
              maxColumns: 3,
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final user in _users)
                  Builder(
                    builder: (context) {
                      final isAdmin = user['role'] == 'admin';
                      final enabled = user['enabled'] == true;
                      final roleColor = isAdmin ? mineral : violet;
                      final canToggle = _canToggle(user);
                      final actions = <Widget>[
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: _busy
                              ? null
                              : () => Navigator.push(
                                  context,
                                  buildIslePageRoute<void>(
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
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: _busy
                                ? null
                                : () => Navigator.push(
                                    context,
                                    buildIslePageRoute<void>(
                                      builder: (_) => GrantsPage(
                                        api: widget.api,
                                        user: user,
                                      ),
                                    ),
                                  ),
                            child: const Text('目录授权'),
                          ),
                        if (user['role'] == 'member' && enabled)
                          OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: _busy
                                ? null
                                : () => _resetPassword(user),
                            child: const Text('重置密码'),
                          ),
                      ];
                      return IsleSurface(
                        radius: IsleRadius.card,
                        tint: roleColor,
                        margin: EdgeInsets.zero,
                        padding: EdgeInsets.zero,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ListTile(
                              contentPadding: const EdgeInsets.fromLTRB(
                                15,
                                4,
                                8,
                                4,
                              ),
                              leading: IsleSquircleBadge(
                                icon: isAdmin
                                    ? Icons.shield_outlined
                                    : Icons.person_outline_rounded,
                                color: roleColor,
                                size: 36,
                                iconSize: 18,
                              ),
                              title: Text(
                                user['username']?.toString() ?? '',
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                              subtitle: Text(
                                isAdmin ? '管理员 · 无限配额' : '成员',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IsleStatusBadge(
                                    label: enabled ? '正常' : '已停用',
                                    color: enabled
                                        ? sage
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                  ),
                                  if (canToggle)
                                    PopupMenuButton<String>(
                                      tooltip: '账号操作',
                                      enabled: !_busy,
                                      icon: const Icon(
                                        Icons.more_horiz_rounded,
                                        size: 18,
                                      ),
                                      style: IconButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      shape: IsleShapes.md(
                                        side: BorderSide(
                                          color: borderColor,
                                          width: 1.0,
                                        ),
                                      ),
                                      onSelected: (_) => _toggle(user),
                                      itemBuilder: (_) => [
                                        isleActionMenuItem(
                                          value: 'toggle',
                                          icon: enabled
                                              ? Icons.block_rounded
                                              : Icons.check_circle_outline,
                                          label: enabled ? '停用账号' : '启用账号',
                                          destructive: enabled,
                                        ),
                                      ],
                                    ),
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(60, 0, 14, 12),
                              child: actions.isNotEmpty
                                  ? Wrap(
                                      spacing: 8,
                                      runSpacing: 6,
                                      children: actions,
                                    )
                                  : Text(
                                      '受保护账号',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
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
}
