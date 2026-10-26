import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import '../../core/isle_theme.dart';
import 'account_security_page.dart';
import 'admin_activity_page.dart';
import 'dav_page.dart';
import 'storage_page.dart';
import '../files/file_shares_page.dart';
import '../files/downloads_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.api,
    required this.identity,
    required this.onLogout,
  });
  final LightIsleApi api;
  final Map<String, dynamic> identity;
  final Future<void> Function() onLogout;
  @override
  Widget build(BuildContext context) => IsleListView(
    padding: const EdgeInsets.all(20),
    children: [
      const IslePageHeader(
        title: '账号与连接',
        subtitle: '管理你的轻屿空间，让每一次连接都安心。',
        icon: Icons.tune_rounded,
      ),
      IsleAnimatedEntrance(
        delay: const Duration(milliseconds: 20),
        child: IsleGroupCard(
          children: [
            IsleGroupTile(
              icon: Icons.account_circle_rounded,
              iconBgColor: const Color(0xff2563eb),
              iconColor: Colors.white,
              title: identity['username']?.toString() ?? '',
              subtitle: identity['role'] == 'admin' ? '管理员' : '成员',
            ),
            IsleGroupTile(
              icon: Icons.dns_rounded,
              iconBgColor: const Color(0xff7c3aed),
              iconColor: Colors.white,
              title: '当前服务器',
              subtitle: api.uri('/').origin,
            ),
            const IsleGroupTile(
              icon: Icons.lock_outline_rounded,
              iconBgColor: Color(0xff0ea5e9),
              iconColor: Colors.white,
              title: '登录信息',
              subtitle: '密码与会话仅保留在内存。退出应用后需要重新登录。',
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      const IsleAnimatedEntrance(
        delay: Duration(milliseconds: 50),
        child: IsleSectionHeader(title: '数据与安全'),
      ),
      IsleAnimatedEntrance(
        delay: const Duration(milliseconds: 70),
        child: IsleGroupCard(
          children: [
            IsleGroupTile(
              icon: Icons.storage_rounded,
              iconBgColor: const Color(0xff0f766e),
              iconColor: Colors.white,
              title: '我的存储空间',
              subtitle: '总配额及照片、视频和文件存储位置',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => StoragePage(
                    api: api,
                    isAdmin: identity['role'] == 'admin',
                  ),
                ),
              ),
            ),
            IsleGroupTile(
              icon: Icons.downloading_rounded,
              iconBgColor: const Color(0xff0ea5e9),
              iconColor: Colors.white,
              title: '下载中心',
              subtitle: '让 Mac 下载链接中的文件',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => DownloadsPage(api: api),
                ),
              ),
            ),
            IsleGroupTile(
              icon: Icons.link_rounded,
              iconBgColor: const Color(0xff0ea5e9),
              iconColor: Colors.white,
              title: '我的文件分享',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => FileSharesPage(api: api),
                ),
              ),
            ),
            IsleGroupTile(
              icon: Icons.folder_shared_rounded,
              iconBgColor: const Color(0xff0ea5e9),
              iconColor: Colors.white,
              title: 'WebDAV 访问',
              subtitle: '独立密码挂载 Finder / Infuse',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => DavPage(api: api)),
              ),
            ),
            IsleGroupTile(
              icon: Icons.security_rounded,
              iconBgColor: const Color(0xff6366f1),
              iconColor: Colors.white,
              title: '密码与登录会话',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      AccountSecurityPage(api: api, onSignedOut: onLogout),
                ),
              ),
            ),
          ],
        ),
      ),
      if (identity['role'] == 'admin') ...[
        const SizedBox(height: 12),
        const IsleAnimatedEntrance(
          delay: Duration(milliseconds: 90),
          child: IsleSectionHeader(title: '管理与审计'),
        ),
        IsleAnimatedEntrance(
          delay: const Duration(milliseconds: 110),
          child: IsleGroupCard(
            children: [
              IsleGroupTile(
                icon: Icons.folder_copy_rounded,
                iconBgColor: const Color(0xff0d9488),
                iconColor: Colors.white,
                title: '成员存储与配额',
                subtitle: '为账号分配专属存储硬盘和总额度',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => StoragePage(api: api, isAdmin: true),
                  ),
                ),
              ),
              IsleGroupTile(
                icon: Icons.people_alt_rounded,
                iconBgColor: const Color(0xff10b981),
                iconColor: Colors.white,
                title: '账号与目录授权',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => AccountsPage(
                      api: api,
                      currentUsername: identity['username']?.toString(),
                    ),
                  ),
                ),
              ),
              IsleGroupTile(
                icon: Icons.notifications_active_outlined,
                iconBgColor: const Color(0xfff59e0b),
                iconColor: Colors.white,
                title: '存储与任务通知',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        AdminActivityPage(api: api, kind: AdminActivity.alerts),
                  ),
                ),
              ),
              IsleGroupTile(
                icon: Icons.policy_outlined,
                iconBgColor: const Color(0xff8b5cf6),
                iconColor: Colors.white,
                title: '安全审计',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        AdminActivityPage(api: api, kind: AdminActivity.audit),
                  ),
                ),
              ),
              IsleGroupTile(
                icon: Icons.cloud_upload_rounded,
                iconBgColor: const Color(0xffec4899),
                iconColor: Colors.white,
                title: '上传维护',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => UploadMaintenancePage(api: api),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
      const SizedBox(height: 16),
      const Notice(
        'Mac 原生管理端负责启动 NAS、首次管理员设置、存储授权与备份恢复。关闭 Flutter 客户端不会停止 Mac 上的服务。',
      ),
      OutlinedButton.icon(
        onPressed: () async {
          if (await confirmAction(
            context,
            '退出登录',
            '将结束当前会话。下次连接需要重新输入密码。',
            action: '退出登录',
            isDestructive: true,
          )) {
            await onLogout();
          }
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
      final result = await widget.api.get('/api/v1/users');
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
      await widget.api.send('POST', '/api/v1/users', body: result);
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
        '/api/v1/users/${user['id']}',
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
      padding: const EdgeInsets.all(20),
      children: [
        FilledButton.icon(
          onPressed: _busy ? null : _create,
          icon: const Icon(Icons.person_add_outlined),
          label: const Text('创建账号'),
        ),
        if (_error != null) Notice(_error!, error: true, onRetry: _load),
        if (_busy) const LinearProgressIndicator(),
        if (_loaded && _users.isEmpty) const Notice('暂无账号。'),
        ..._users.map(
          (user) => IsleSurface(
            padding: const EdgeInsets.all(16),
            radius: 18,
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color:
                            (user['role'] == 'admin'
                                    ? const Color(0xff2563eb)
                                    : const Color(0xff7c3aed))
                                .withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        user['role'] == 'admin'
                            ? Icons.shield_outlined
                            : Icons.person_outline_rounded,
                        color: user['role'] == 'admin'
                            ? const Color(0xff2563eb)
                            : const Color(0xff7c3aed),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            user['username']?.toString() ?? '',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${user['role'] == 'admin' ? '管理员' : '成员'} · ${user['enabled'] == true ? '已启用' : '已停用'}',
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IsleStatusBadge(
                      label: user['enabled'] == true ? '正常' : '已停用',
                      color: user['enabled'] == true
                          ? const Color(0xff10b981)
                          : const Color(0xff64748b),
                    ),
                  ],
                ),
                ...[
                  const SizedBox(height: 12),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
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
                      if (user['role'] == 'member' && user['enabled'] == true)
                        OutlinedButton(
                          onPressed: _busy ? null : () => _resetPassword(user),
                          child: const Text('重置密码'),
                        ),
                      if (_canToggle(user))
                        TextButton(
                          onPressed: _busy ? null : () => _toggle(user),
                          style: TextButton.styleFrom(
                            foregroundColor: user['enabled'] == true
                                ? Theme.of(context).colorScheme.error
                                : Theme.of(context).colorScheme.primary,
                          ),
                          child: Text(
                            user['enabled'] == true ? '停用账号' : '启用账号',
                          ),
                        ),
                      if (!_canToggle(user)) const Text('受保护账号'),
                    ],
                  ),
                ],
              ],
            ),
          ),
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
  bool _write = false, _busy = false;
  String? _error;
  String get _endpoint => '/api/v1/users/${widget.user['id']}/file-grants';
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
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
      final r = await widget.api.get(_endpoint);
      if (mounted) setState(() => _grants = objectList(r['grants']));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save({String? remove}) async {
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
        await widget.api.send('DELETE', _endpoint, query: {'path': path});
      } else {
        await widget.api.send(
          'PUT',
          _endpoint,
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
      padding: const EdgeInsets.all(20),
      children: [
        const Notice('填写相对共享根目录的路径；“.” 表示整个共享目录。授权会影响文件、图库与影视访问。'),
        TextField(
          controller: _path,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: '目录路径',
            hintText: '照片/旅行 或 .',
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('允许写入'),
          subtitle: const Text('可上传、整理和删除原始文件'),
          value: _write,
          onChanged: _busy ? null : (v) => setState(() => _write = v),
        ),
        FilledButton(
          onPressed: _busy ? null : () => _save(),
          child: const Text('保存授权'),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Notice(_error!, error: true, onRetry: _load),
        ..._grants.map(
          (g) => IsleSurface(
            padding: EdgeInsets.zero,
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: ListTile(
              title: Text(g['path']?.toString() ?? ''),
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
        '/api/v1/admin/uploads',
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
      await widget.api.send('DELETE', '/api/v1/admin/uploads/${item['id']}');
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
        '/api/v1/admin/uploads/cleanup-expired',
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
      padding: const EdgeInsets.all(20),
      children: [
        DropdownButtonFormField<int>(
          initialValue: _days,
          decoration: const InputDecoration(labelText: '未活动时间'),
          items: [7, 30, 90]
              .map((d) => DropdownMenuItem(value: d, child: Text('$d 天')))
              .toList(),
          onChanged: _busy ? null : (v) => setState(() => _days = v!),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _busy ? null : _cleanup,
          child: const Text('清理过期上传'),
        ),
        if (_message != null) Notice(_message!),
        if (_error != null) Notice(_error!, error: true, onRetry: _load),
        if (_busy) const LinearProgressIndicator(),
        if (_loaded && _items.isEmpty) const Notice('没有待维护的上传。'),
        ..._items.map(
          (item) => IsleSurface(
            padding: EdgeInsets.zero,
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item['path']?.toString() ?? '',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    '账号：${item['ownerName'] ?? '已删除'} · ${formatBytes(item['offset'] as num?)} / ${formatBytes(item['size'] as num?)}',
                  ),
                  if (item['orphan'] == true || item['corrupt'] == true)
                    const Text('上传分片异常'),
                  TextButton(
                    onPressed: _busy ? null : () => _cancel(item),
                    child: const Text('取消并清理'),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (!_busy && _cursor.isNotEmpty)
          OutlinedButton(
            onPressed: () => _load(more: true),
            child: const Text('加载更多'),
          ),
      ],
    ),
  );
}
