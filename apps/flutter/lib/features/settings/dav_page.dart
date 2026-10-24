import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';

class DavCredential {
  const DavCredential({
    required this.id,
    required this.label,
    required this.createdAt,
    required this.lastUsedAt,
  });

  final int id;
  final String label;
  final int createdAt;
  final int lastUsedAt;

  factory DavCredential.fromJson(Map<String, dynamic> json) => DavCredential(
    id: _timestamp(json['id']),
    label: json['label']?.toString() ?? '',
    createdAt: _timestamp(json['createdAt']),
    lastUsedAt: _timestamp(json['lastUsedAt']),
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
  const DavPage({super.key, required this.api});

  final LightIsleApi api;

  @override
  State<DavPage> createState() => _DavPageState();
}

class _DavPageState extends State<DavPage> {
  List<DavCredential> _credentials = const [];
  bool _loading = false;
  bool _busy = false;
  String? _error;

  String get _davUrl => '${widget.api.uri('/').origin}/dav/';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await widget.api.get('/api/v1/dav/credentials');
      if (!mounted) return;
      setState(() {
        _credentials = objectList(response['credentials'])
            .map(DavCredential.fromJson)
            .toList(growable: false);
      });
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
        '/api/v1/dav/credentials',
        body: {'label': label},
      );
      final password = response['password']?.toString() ?? '';
      if (!mounted) return;
      await _showFreshPassword(label, password);
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
        '/api/v1/dav/credentials/${credential.id}',
      );
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = '撤销失败：$error');
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

  Future<void> _showFreshPassword(String label, String password) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('请立即保存密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('「$label」的 WebDAV 密码只显示这一次：'),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(dialogContext).colorScheme.surfaceContainerHighest,
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
              ScaffoldMessenger.of(dialogContext).showSnackBar(
                const SnackBar(content: Text('密码已复制到剪贴板')),
              );
            },
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('复制密码'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('我已保存'),
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
      padding: const EdgeInsets.all(20),
      children: [
        IslePageHeader(
          title: 'WebDAV 访问',
          subtitle: '用独立密码把私人文件挂载到 Finder、Windows 或 Infuse。',
          icon: Icons.folder_shared_rounded,
        ),
        IsleGroupCard(
          children: [
            IsleGroupTile(
              icon: Icons.link_rounded,
              iconBgColor: const Color(0xff0ea5e9),
              iconColor: Colors.white,
              title: '连接地址',
              subtitle: _davUrl,
            ),
            IsleGroupTile(
              icon: Icons.add_circle_outline_rounded,
              iconBgColor: const Color(0xff10b981),
              iconColor: Colors.white,
              title: _busy ? '处理中…' : '生成新密码',
              subtitle: '密码仅显示一次，可随时撤销',
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
                  icon: Icons.password_rounded,
                  iconBgColor: const Color(0xff6366f1),
                  iconColor: Colors.white,
                  title: credential.label,
                  subtitle:
                      '创建于 ${_formatDate(credential.createdAt)} · 最近使用 ${_formatDate(credential.lastUsedAt)} · 点按撤销',
                  onTap: _busy ? null : () => unawaited(_revoke(credential)),
                ),
            ],
          ),
        const SizedBox(height: 12),
        const Notice(
          'WebDAV 密码与网页登录密码相互独立；撤销后已连接的客户端立即失效。'
          '目录权限与管理端一致，删除的文件会进入轻屿回收站。',
        ),
      ],
    ),
  );
}
