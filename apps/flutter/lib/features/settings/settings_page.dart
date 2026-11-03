import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import '../../core/isle_theme.dart';
import '../../core/user_facing_error.dart';
import 'account_security_page.dart';
import 'admin_activity_page.dart';
import 'admin_diagnostics_page.dart';
import 'network_diagnostics_page.dart';
import 'dav_page.dart';
import 'storage_page.dart';
import '../files/file_shares_page.dart';
import '../files/downloads_page.dart';
import '../files/file_destination_dialog.dart';
import '../media/offline_video_store.dart';
import '../media/offline_photo_store.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.api,
    required this.identity,
    required this.onLogout,
    this.pendingUploads,
  });

  final LightIsleApi api;
  final Map<String, dynamic> identity;
  final Future<void> Function() onLogout;

  /// Read on demand to avoid displaying stale counts in an open settings tab.
  final int Function()? pendingUploads;

  void _go(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  Widget _entry(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required String color,
    required VoidCallback onTap,
  }) => IsleGroupTile(
    icon: icon,
    iconBgColor: IslePalette.of(context)[color],
    title: title,
    subtitle: subtitle,
    onTap: onTap,
  );

  Widget _section(
    BuildContext context, {
    required String title,
    required int index,
    required List<Widget> entries,
  }) => IsleAnimatedEntrance(
    delay: Duration(milliseconds: 35 * index),
    child: Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IsleSectionHeader(title: title),
          IsleGroupCard(margin: EdgeInsets.zero, children: entries),
        ],
      ),
    ),
  );

  void _showConnection(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('连接详情'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '当前服务器',
                  style: Theme.of(dialogContext).textTheme.labelMedium,
                ),
                const SizedBox(height: 6),
                SelectableText(api.uri('/').origin),
                const SizedBox(height: 16),
                const Text('登录状态保存在系统安全存储中，不保存密码。'),
                const SizedBox(height: 8),
                const Text('退出登录会清除本机的登录会话，NAS 服务不会停止。'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.pop(dialogContext);
              _go(context, NetworkDiagnosticsPage(api: api));
            },
            icon: const Icon(Icons.speed_rounded),
            label: const Text('测试当前连接'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _identityCard(BuildContext context, bool isAdmin) => IsleSurface(
    radius: 18,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final narrow =
            constraints.maxWidth < 430 ||
            MediaQuery.textScalerOf(context).scale(14) > 19;
        final profile = Row(
          children: [
            IsleSquircleBadge(
              icon: isAdmin
                  ? Icons.admin_panel_settings_rounded
                  : Icons.person_rounded,
              color: IslePalette.of(
                context,
              )[isAdmin ? 'brandIndigo' : 'brandCyan'],
              size: 38,
              iconSize: 21,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    identity['username']?.toString() ?? '当前账号',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    isAdmin ? '家庭管理员 · 可管理成员与存储' : '家庭成员 · 仅管理自己的内容',
                    maxLines: 2,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
        final connection = TextButton.icon(
          onPressed: () => _showConnection(context),
          icon: const Icon(Icons.lan_outlined, size: 18),
          label: const Text('连接详情'),
        );
        return narrow
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  profile,
                  Align(alignment: Alignment.centerRight, child: connection),
                ],
              )
            : Row(
                children: [
                  Expanded(child: profile),
                  const SizedBox(width: 8),
                  connection,
                ],
              );
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final isAdmin = identity['role'] == 'admin';
    return IsleListView(
      maxWidth: IsleLayout.settingsWidth,
      children: [
        IslePageHeader(
          title: '设置',
          subtitle: isAdmin ? '家庭管理、存储权限与服务维护' : '个人空间、连接与账号安全',
          icon: Icons.tune_rounded,
        ),
        _identityCard(context, isAdmin),
        const SizedBox(height: 8),
        if (isAdmin)
          _section(
            context,
            title: '家庭与存储',
            index: 0,
            entries: [
              _entry(
                context,
                icon: Icons.people_alt_rounded,
                title: '账号与目录授权',
                subtitle: '成员、目录与读写权限',
                color: 'brandIndigo',
                onTap: () => _go(
                  context,
                  AccountsPage(
                    api: api,
                    currentUsername: identity['username']?.toString(),
                  ),
                ),
              ),
              _entry(
                context,
                icon: Icons.storage_rounded,
                title: '存储与成员配额',
                subtitle: '逐盘配置空间与容量',
                color: 'brandCyan',
                onTap: () => _go(context, StoragePage(api: api, isAdmin: true)),
              ),
              _entry(
                context,
                icon: Icons.notifications_active_outlined,
                title: '存储与任务通知',
                subtitle: '磁盘、备份与后台任务',
                color: 'warningText',
                onTap: () => _go(
                  context,
                  AdminActivityPage(api: api, kind: AdminActivity.alerts),
                ),
              ),
              _entry(
                context,
                icon: Icons.monitor_heart_outlined,
                title: '设备诊断与 Key 状态',
                subtitle: '性能历史、网卡、磁盘 SMART 和第三方配置状态',
                color: 'brandBlue',
                onTap: () => _go(context, AdminDiagnosticsPage(api: api)),
              ),
            ],
          ),
        if (!isAdmin)
          _section(
            context,
            title: '我的空间',
            index: 0,
            entries: [
              _entry(
                context,
                icon: Icons.storage_rounded,
                title: '我的存储空间',
                subtitle: '查看各硬盘额度及已计用量',
                color: 'brandCyan',
                onTap: () =>
                    _go(context, StoragePage(api: api, isAdmin: false)),
              ),
            ],
          ),
        _section(
          context,
          title: '文件与连接',
          index: 1,
          entries: [
            _entry(
              context,
              icon: Icons.speed_rounded,
              title: '连接测速',
              subtitle: '延迟、上下行速度与 NAS 连接稳定性',
              color: 'brandCyan',
              onTap: () => _go(context, NetworkDiagnosticsPage(api: api)),
            ),
            _entry(
              context,
              icon: Icons.downloading_rounded,
              title: '下载中心',
              subtitle: '离线下载、进度和任务',
              color: 'brandBlue',
              onTap: () => _go(context, DownloadsPage(api: api)),
            ),
            _entry(
              context,
              icon: Icons.link_rounded,
              title: '我的文件分享',
              subtitle: '查看及撤销分享链接',
              color: 'brandCyan',
              onTap: () => _go(context, FileSharesPage(api: api)),
            ),
            _entry(
              context,
              icon: Icons.folder_shared_rounded,
              title: 'WebDAV 访问',
              subtitle: '通过独立密码连接设备',
              color: 'brandViolet',
              onTap: () => _go(
                context,
                DavPage(api: api, accountId: identity['id']?.toString()),
              ),
            ),
          ],
        ),
        _section(
          context,
          title: '账号与安全',
          index: 2,
          entries: [
            _entry(
              context,
              icon: Icons.security_rounded,
              title: '密码与登录会话',
              subtitle: '改密、管理已登录设备',
              color: 'brandIndigo',
              onTap: () => _go(
                context,
                AccountSecurityPage(api: api, onSignedOut: onLogout),
              ),
            ),
            if (isAdmin)
              _entry(
                context,
                icon: Icons.policy_outlined,
                title: '安全审计',
                subtitle: '查看管理员操作记录',
                color: 'brandViolet',
                onTap: () => _go(
                  context,
                  AdminActivityPage(api: api, kind: AdminActivity.audit),
                ),
              ),
            if (isAdmin)
              _entry(
                context,
                icon: Icons.cloud_upload_rounded,
                title: '上传维护',
                subtitle: '处理残留与过期上传',
                color: 'brandBlue',
                onTap: () => _go(context, UploadMaintenancePage(api: api)),
              ),
          ],
        ),
        const IsleHelpDisclosure(
          summary: '关于 LightIsle 客户端与数据',
          details:
              'Mac 原生管理端负责运行 NAS、存储权限和配置恢复。'
              '关闭这个客户端不会停止 NAS；原始文件需要通过 Time Machine 或其他工具备份。',
        ),
        const SizedBox(height: 7),
        OutlinedButton.icon(
          onPressed: () async {
            final userId = identity['id'];
            final canClear = userId is int && userId > 0;
            final choice = await showDialog<String>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: const Text('退出登录'),
                content: Text(
                  '下次连接需要重新输入密码。'
                  '${(pendingUploads?.call() ?? 0) > 0 ? '当前仍有 ${pendingUploads!()} 个上传任务未结束；退出后传输将暂停，重新登录时可尝试断点续传。' : ''}'
                  '${canClear ? '你可以保留离线照片和影片，或清理当前服务器、账号和存储位置的两种本地副本；其他硬盘位置的副本需分别清理。NAS 原始文件不会删除。' : '本客户端无法确认稳定账号 ID，已保存的本地文件不会自动删除。'}',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext, 'keep'),
                    child: const Text('保留离线文件并退出'),
                  ),
                  if (canClear)
                    FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, 'clear'),
                      child: const Text('清理当前离线库并退出'),
                    ),
                ],
              ),
            );
            if (choice == null || !context.mounted) return;
            if (choice == 'clear') {
              try {
                await OfflineVideoStore(
                  api: api,
                  accountName: 'uid:$userId',
                ).clear();
                await OfflinePhotoStore(
                  api: api,
                  accountId: 'uid:$userId',
                ).clear();
              } catch (error) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        '本机离线副本尚未全部清理，已完成部分可能不再存在；未退出，请重新尝试：${userFacingError(error)}',
                      ),
                    ),
                  );
                }
                return;
              }
            }
            await onLogout();
          },
          icon: const Icon(Icons.logout_rounded),
          label: const Text('退出登录 / 切换服务器'),
        ),
        const SizedBox(height: 24),
        Text(
          '轻屿 LightIsle · Flutter 开发预览 0.1.0',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant
                .withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }
}

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
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => const _NewAccountDialog(),
    );
    if (result == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.send('POST', '/api/v2/users', body: result);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
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
      if (mounted) setState(() => _error = e.toString());
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
    appBar: AppBar(
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
            minItemWidth: 320,
            maxColumns: 2,
            spacing: 12,
            runSpacing: 12,
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
                                  palette[isAdmin ? 'brandBlue' : 'brandViolet'],
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
  const _NewAccountDialog();
  @override
  State<_NewAccountDialog> createState() => _NewAccountDialogState();
}

class _NewAccountDialogState extends State<_NewAccountDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(), _password = TextEditingController();
  String _role = 'member';
  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
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
            Navigator.pop(context, {
              'username': _name.text,
              'password': _password.text,
              'role': _role,
            });
          }
        },
        child: const Text('创建账号'),
      ),
    ],
  );
}

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
    // Changing the shared client is safe only while this page owns the
    // foreground route. Do not send an in-flight old-root ACL to a new root.
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
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _error == null) await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('${widget.user['username']} · 目录授权')),
    body: IsleListView(
      children: [
        if (_rootLoadError != null)
          Notice(_rootLoadError!, error: true, onRetry: _loadRoots),
        if (_error != null) Notice(_error!, error: true, onRetry: _load),
        if (_busy) const LinearProgressIndicator(),
        if (_rootsReady)
          DropdownButtonFormField<String>(
            key: ValueKey('grant-root-${_grantRoot?.identity ?? 'default'}'),
            isExpanded: true,
            initialValue: _grantRoot?.identity ?? '',
            decoration: const InputDecoration(
              labelText: '选择要授权的硬盘',
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
                    if (value.isEmpty || next != null) _chooseGrantRoot(next);
                  },
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _busy ? null : _browseGrantFolder,
            icon: const Icon(Icons.folder_open_rounded),
            label: const Text('浏览并选择文件夹'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(
            _path.text.trim().isEmpty
                ? '尚未选择文件夹'
                : '已选择：${_path.text.trim() == '.' ? '根目录（所有文件）' : _path.text.trim()}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        IsleDisclosureCard(
          title: const Text('高级：手动输入共享目录路径'),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '只有了解 NAS 相对路径时才需要使用',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _path,
                    enabled: !_busy,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: '相对目录路径',
                      hintText: '照片/旅行 或 .',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('允许写入'),
          subtitle: const Text('可上传、整理和删除原始文件'),
          value: _write,
          onChanged: _busy ? null : (v) => setState(() => _write = v),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            onPressed: _busy ? null : () => _save(),
            child: const Text('保存授权'),
          ),
        ),
        if (_grants.isNotEmpty)
          IsleResponsiveGrid(
            minItemWidth: 320,
            maxColumns: 2,
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final g in _grants)
                IsleSurface(
                  radius: 16,
                  margin: EdgeInsets.zero,
                  padding: EdgeInsets.zero,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 2,
                    ),
                    leading: IsleSquircleBadge(
                      icon: g['canWrite'] == true
                          ? Icons.edit_note_rounded
                          : Icons.visibility_outlined,
                      color: IslePalette.of(context)['brandIndigo'],
                      size: 36,
                      iconSize: 19,
                    ),
                    title: Text(
                      g['path']?.toString() ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(g['canWrite'] == true ? '读写' : '只读'),
                    trailing: IconButton(
                      tooltip: '撤销授权',
                      onPressed: _busy
                          ? null
                          : () => _save(remove: g['path'].toString()),
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                  ),
                ),
            ],
          )
        else if (!_busy)
          const Notice('尚未创建目录授权。'),
        IsleHelpDisclosure(
          summary: '当前授权范围：${_grantRoot?.name ?? '默认共享目录'}',
          details:
              '当前硬盘：${_grantRoot?.name ?? '默认共享目录'}。'
              '${_grantRoot == null ? '' : '物理根代际：${_grantRoot?.generation}。'}'
              '切换存储位置后请重新进入本页。为成员选择可访问的文件夹，并决定是否允许写入。'
              '授权会影响文件、图库与影视访问。',
        ),
      ],
    ),
  );
}

class UploadMaintenancePage extends StatefulWidget {
  const UploadMaintenancePage({super.key, required this.api});
  final LightIsleApi api;
  @override
  State<UploadMaintenancePage> createState() => _UploadMaintenancePageState();
}

class _UploadMaintenancePageState extends State<UploadMaintenancePage> {
  List<Map<String, dynamic>> _items = [];
  String _cursor = '';
  String? _error, _message;
  bool _busy = false, _loaded = false;
  int _days = 30;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.api.get(
        '/api/v2/admin/uploads',
        query: {
          'limit': '20',
          if (more && _cursor.isNotEmpty) 'after': _cursor,
        },
      );
      if (mounted) {
        setState(() {
          _items = [
            ...(more ? _items : <Map<String, dynamic>>[]),
            ...objectList(r['uploads']),
          ];
          _cursor = r['nextCursor']?.toString() ?? '';
          _loaded = true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel(Map<String, dynamic> item) async {
    if (!await confirmAction(
      context,
      '取消上传',
      '将清理 ${item['path']} 的未完成上传，之后需要重新上传。',
      action: '取消并清理',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.send('DELETE', '/api/v2/admin/uploads/${item['id']}');
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _error == null) await _load();
  }

  Future<void> _cleanup() async {
    final days = _days;
    if (!await confirmAction(
      context,
      '清理过期上传',
      '清理至少 $days 天未活动的上传分片，清理后无法续传。不会删除已完成的原始文件。',
      action: '清理分片',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final r = await widget.api.send(
        'POST',
        '/api/v2/admin/uploads/cleanup-expired',
        body: {'inactiveForSeconds': days * 86400},
      );
      if (mounted) {
        setState(
          () => _message =
              '已清理 ${r['removed']} 项，跳过 ${r['skipped']} 项。${r['hasMore'] == true ? '仍有更多，可再次执行清理。' : ''}',
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _error == null) await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('上传维护'),
      actions: [
        IconButton(
          tooltip: '刷新上传',
          onPressed: _busy ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: IsleListView(
      children: [
        if (_message != null) Notice(_message!),
        if (_error != null) Notice(_error!, error: true, onRetry: _load),
        if (_busy) const LinearProgressIndicator(),
        if (_loaded && _items.isEmpty) const Notice('没有待维护的上传。'),
        DropdownButtonFormField<int>(
          initialValue: _days,
          decoration: const InputDecoration(labelText: '未活动时间'),
          items: [7, 30, 90]
              .map((d) => DropdownMenuItem(value: d, child: Text('$d 天')))
              .toList(),
          onChanged: _busy ? null : (v) => setState(() => _days = v!),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: _busy ? null : _cleanup,
            child: const Text('清理过期上传'),
          ),
        ),
        if (_items.isNotEmpty)
          IsleResponsiveGrid(
            minItemWidth: 320,
            maxColumns: 2,
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final item in _items)
                IsleSurface(
                  radius: 16,
                  margin: EdgeInsets.zero,
                  padding: EdgeInsets.zero,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 4,
                    ),
                    leading: IsleSquircleBadge(
                      icon: Icons.cloud_upload_outlined,
                      color: IslePalette.of(context)['brandCyan'],
                      size: 36,
                      iconSize: 19,
                    ),
                    title: Text(
                      item['path']?.toString() ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      '账号：${item['ownerName'] ?? '已删除'} · '
                      '${formatBytes(item['offset'] as num?)} / ${formatBytes(item['size'] as num?)}'
                      '${item['orphan'] == true || item['corrupt'] == true ? '\n上传分片异常' : ''}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    trailing: TextButton(
                      onPressed: _busy ? null : () => _cancel(item),
                      style: TextButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                      child: const Text('取消并清理'),
                    ),
                  ),
                ),
            ],
          ),
        if (!_busy && _cursor.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: OutlinedButton(
                onPressed: () => _load(more: true),
                child: const Text('加载更多'),
              ),
            ),
          ),
      ],
    ),
  );
}
