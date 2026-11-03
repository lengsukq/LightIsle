import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import 'dav_local_password_vault.dart';

class DavCredential {
  const DavCredential({
    required this.id,
    required this.label,
    required this.createdAt,
    required this.lastUsedAt,
    required this.revision,
  });

  final int id;
  final String label;
  final int createdAt;
  final int lastUsedAt;
  final String revision;

  factory DavCredential.fromJson(Map<String, dynamic> json) => DavCredential(
    id: _timestamp(json['id']),
    label: json['label']?.toString() ?? '',
    createdAt: _timestamp(json['createdAt']),
    lastUsedAt: _timestamp(json['lastUsedAt']),
    revision: json['revision']?.toString() ?? '',
  );
}

int _timestamp(Object? value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text) ?? 0,
  _ => 0,
};

/// Self-service WebDAV passwords. The endpoint never accepts the web session
/// cookie, so these credentials are the only way a DAV client can connect.
class DavPage extends StatefulWidget {
  const DavPage({super.key, required this.api, this.accountId});

  final LightIsleApi api;
  final String? accountId;

  @override
  State<DavPage> createState() => _DavPageState();
}

class _DavPageState extends State<DavPage> {
  final DavLocalPasswordVault _vault = DavLocalPasswordVault();
  List<DavCredential> _credentials = const [];
  bool _loading = false;
  bool _busy = false;
  String? _error;
  String? _localVaultNotice;
  String? _accountScope;

  String get _davUrl => '${widget.api.uri('/').origin}/dav/';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<String?> _scope() async {
    if (_accountScope != null) return _accountScope;
    var account = widget.accountId?.trim() ?? '';
    if (account.isEmpty) {
      try {
        final response = await widget.api.get('/api/v2/auth/status');
        account = response['id']?.toString() ?? '';
      } catch (_) {
        return null;
      }
    }
    if (account.isEmpty || account == '0') return null;
    return _accountScope = DavLocalPasswordVault.scope(
      widget.api.uri('/').origin,
      account,
    );
  }

  Future<void> _remember(int id, String password) async {
    final scope = await _scope();
    if (scope == null) {
      if (mounted) setState(() => _localVaultNotice = '无法识别当前账号，请手动复制密码。');
      return;
    }
    try {
      await _vault.write(scope, id, password);
      if (mounted) setState(() => _localVaultNotice = null);
    } catch (_) {
      if (mounted) {
        setState(
          () => _localVaultNotice = '系统 Keychain / Keystore 暂不可用，请立即复制保存。',
        );
      }
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await widget.api.get('/api/v2/dav/credentials');
      if (!mounted) return;
      final credentials = objectList(response['credentials'])
          .map(DavCredential.fromJson)
          .toList(growable: false);
      setState(() {
        _credentials = credentials;
      });
      if (_accountScope != null) {
        try {
          await _vault.prune(
            _accountScope!,
            credentials.map((c) => c.id).toSet(),
          );
        } catch (_) {
          if (mounted) {
            setState(() => _localVaultNotice = '本机安全存储暂不可用，请手动保存连接密码。');
          }
        }
      }
    } catch (error) {
      if (mounted) setState(() => _error = '读取 WebDAV 密码失败：$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _create() async {
    final label = await _promptLabel();
    if (label == null || _busy) return;
    setState(() => _busy = true);
    try {
      final response = await widget.api.send(
        'POST',
        '/api/v2/dav/credentials',
        body: {'label': label},
      );
      final password = response['password']?.toString() ?? '';
      final credential = response['credential'];
      final id = credential is Map ? _timestamp(credential['id']) : 0;
      if (id > 0 && password.isNotEmpty) await _remember(id, password);
      if (!mounted) return;
      await _showPassword(label, password);
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = '创建 WebDAV 密码失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke(DavCredential credential) async {
    if (_busy) return;
    final confirmed = await confirmAction(
      context,
      '撤销 WebDAV 密码',
      '撤销“${credential.label}”？正在使用该密码的客户端会立即失去连接。',
      action: '撤销',
      isDestructive: true,
    );
    if (!confirmed) return;
    setState(() => _busy = true);
    try {
      await widget.api.send(
        'DELETE',
        '/api/v2/dav/credentials/${credential.id}',
      );
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = '撤销失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _manage(DavCredential credential) async {
    if (_busy) return;
    String? password;
    final scope = await _scope();
    if (scope != null) {
      try {
        password = await _vault.read(scope, credential.id);
      } catch (_) {
        if (mounted) setState(() => _localVaultNotice = '无法解锁本机安全存储。');
      }
    }
    if (!mounted) return;
    if (password != null &&
        (credential.revision.isEmpty ||
            DavLocalPasswordVault.revision(password) != credential.revision)) {
      // Another device may have replaced the secret, or the older NAS does
      // not advertise a revision. Never display a possibly invalid password.
      password = null;
      if (scope != null) {
        try {
          await _vault.remove(scope, credential.id);
        } catch (_) {
          // Suppress cleanup failures; the stale value is not shown.
        }
      }
    }
    if (!mounted) return;
    if (password != null && password.isNotEmpty) {
      await _showPassword(credential.label, password);
      return;
    }
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(credential.label),
        content: const Text(
          '此密码未保存在当前设备，NAS 只保存摘要，无法恢复旧密码。'
          '可重新生成密码，但旧密码将立即失效，已连接的客户端需更新。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'revoke'),
            child: const Text('撤销'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'rotate'),
            child: const Text('重新生成密码'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'revoke') {
      await _revoke(credential);
    } else if (action == 'rotate') {
      await _rotate(credential);
    }
  }

  Future<void> _rotate(DavCredential credential) async {
    final confirmed = await confirmAction(
      context,
      '重新生成 WebDAV 密码',
      '旧密码将立即失效，正在使用它的 Finder、Infuse 等客户端需要更新。确认继续？',
      action: '重新生成',
      isDestructive: true,
    );
    if (!confirmed || !mounted || _busy) return;
    setState(() => _busy = true);
    try {
      final response = await widget.api.send(
        'POST',
        '/api/v2/dav/credentials/${credential.id}/rotate',
      );
      final password = response['password']?.toString() ?? '';
      if (password.isEmpty) throw const FormatException('服务器未返回新密码');
      await _remember(credential.id, password);
      if (mounted) await _showPassword(credential.label, password);
      if (mounted) await _load();
    } catch (error) {
      if (mounted) setState(() => _error = '重新生成密码失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _promptLabel() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('生成 WebDAV 密码'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 64,
          decoration: const InputDecoration(
            labelText: '密码标签',
            hintText: '如：iPad Infuse',
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
            child: const Text('生成'),
          ),
        ],
      ),
    );
  }

  Future<void> _showPassword(String label, String password) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('WebDAV 连接密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('「$label」的连接密码（本设备安全存储可再次查看）：'),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(dialogContext)
                    .colorScheme
                    .surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                password,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
              ),
            ),
            const SizedBox(height: 10),
            Text('连接地址：$_davUrl', style: const TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: password));
              ScaffoldMessenger.of(dialogContext)
                  .showSnackBar(const SnackBar(content: Text('密码已复制到剪贴板')));
            },
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('复制密码'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  String _formatDate(int unix) => unix > 0
      ? DateTime.fromMillisecondsSinceEpoch(unix * 1000)
            .toLocal()
            .toString()
            .split(' ')
            .first
      : '从未';

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('WebDAV 访问')),
    body: IsleListView(
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 16),
          child: Text('用独立访问密码连接 Finder、Windows 或 Infuse。'),
        ),
        IsleGroupCard(
          children: [
            IsleGroupTile(
              icon: Icons.link_rounded,
              iconBgColor: const Color(0xff0ea5e9),
              title: '连接地址',
              subtitle: _davUrl,
              trailing: const Icon(Icons.copy_rounded, size: 16),
              onTap: () {
                Clipboard.setData(ClipboardData(text: _davUrl));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制 WebDAV 连接地址')),
                );
              },
            ),
            IsleGroupTile(
              icon: Icons.add_circle_outline_rounded,
              iconBgColor: const Color(0xff10b981),
              title: _busy ? '处理中…' : '生成新密码',
              subtitle: '新密码可保存在当前设备的系统安全存储中',
              onTap: _busy ? null : () => unawaited(_create()),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_localVaultNotice != null) Notice(_localVaultNotice!),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (_credentials.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                '还没有 WebDAV 密码，生成一个即可连接。',
                style: TextStyle(fontSize: 13),
              ),
            ),
          )
        else
          IsleGroupCard(
            children: [
              for (final credential in _credentials)
                IsleGroupTile(
                  icon: Icons.key_rounded,
                  iconBgColor: const Color(0xff6366f1),
                  title: credential.label,
                  subtitle:
                      '创建于 ${_formatDate(credential.createdAt)} · 最近使用 ${_formatDate(credential.lastUsedAt)} · 点按撤销',
                  onTap: _busy ? null : () => unawaited(_manage(credential)),
                ),
            ],
          ),
        const SizedBox(height: 12),
        const Notice(
          'WebDAV 密码与网页登录密码相互独立；撤销后已连接的客户端立即失效。'
          '本设备新保存的密码可反复查看。旧密码和其他设备创建的密码无法反查，可确认后重新生成。'
          '目录权限与管理端一致，删除的文件会进入轻屿回收站。',
        ),
      ],
    ),
  );
}
