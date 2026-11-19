import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/isle_gallery_layout.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
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
  List<LightIsleRoot> _roots = const [];
  bool _loading = false;
  bool _busy = false;
  String? _error;
  String? _mountError;
  String? _localVaultNotice;
  String? _accountScope;

  String _mountUrl(LightIsleRoot root) =>
      '${widget.api.uri('/').origin}/dav-roots/${Uri.encodeComponent(root.id)}/${root.generation}/';

  String _buildTvClientGuide(LightIsleRoot root) {
    final parsed = Uri.parse(_mountUrl(root));
    final isHttps = parsed.scheme == 'https';
    final port = parsed.hasPort ? parsed.port : (isHttps ? 443 : 80);
    return [
      '【轻屿 · Apple TV / Infuse / VidHub WebDAV 大屏配置】',
      '存储盘：${root.name}',
      '协议：${isHttps ? 'WebDAV (HTTPS)' : 'WebDAV (HTTP)'}',
      '地址：${parsed.host}',
      '端口：$port',
      '路径：$parsed.path',
      '完整 URL：$parsed',
      '用户名：（当前轻屿登录用户名）',
      '密码：（使用下方生成的 WebDAV 独立访问密码）',
    ].join('\n');
  }

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
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final mounts = _loadMounts();
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
      if (mounted) {
        setState(() => _error = '读取 WebDAV 密码失败：${userFacingError(error)}');
      }
    } finally {
      await mounts;
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMounts() async {
    try {
      final response = await widget.api.get('/api/v2/roots');
      final roots = objectList(
        response['roots'],
      ).map(LightIsleRoot.fromJson).toList();
      if (mounted) {
        setState(() {
          _roots = roots;
          _mountError = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _mountError = userFacingError(error));
    }
  }

  Future<void> _create() async {
    final label = await _promptLabel();
    if (label == null || !mounted || _busy) return;
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
      if (mounted) await _load();
    } catch (error) {
      if (mounted) {
        setState(() => _error = '创建 WebDAV 密码失败：${userFacingError(error)}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke(DavCredential credential) async {
    if (_busy) return;
    final confirmed = await confirmAction(
      context,
      '撤销 WebDAV 密码',
      '撤销“${credential.label}”？后续请求将无法使用该密码，已开始的传输可能继续到结束。',
      action: '撤销',
      isDestructive: true,
    );
    if (!confirmed || !mounted || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.api.send(
        'DELETE',
        '/api/v2/dav/credentials/${credential.id}',
      );
      if (mounted) await _load();
    } catch (error) {
      if (mounted) {
        setState(() => _error = '撤销失败：${userFacingError(error)}');
      }
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
      password = null;
      if (scope != null) {
        try {
          await _vault.remove(scope, credential.id);
        } catch (_) {}
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
      if (mounted) {
        setState(() => _error = '重新生成密码失败：${userFacingError(error)}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _promptLabel() {
    if (!mounted) return Future.value(null);
    return showDialog<String>(
      context: context,
      builder: (_) => const _DavLabelDialog(),
    );
  }

  Future<void> _showPassword(String label, String password) {
    if (!mounted) return Future.value();
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
              decoration: IsleDecorations.recessedWell(
                dialogContext,
                radius: 10,
              ),
              child: SelectableText(
                password,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
              ),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: password));
              ScaffoldMessenger.of(
                dialogContext,
              ).showSnackBar(const SnackBar(content: Text('密码已复制到剪贴板')));
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
      ? DateTime.fromMillisecondsSinceEpoch(
          unix * 1000,
        ).toLocal().toString().split(' ').first
      : '未使用';

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    final mineral = palette['brandBlue'];
    final violet = palette['brandViolet'];
    final sage = palette['brandSage'];

    final mountsColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IsleSectionHeader(
          title: '已授权挂载地址（${_roots.length}）',
          accentColor: mineral,
        ),
        if (!_loading && _mountError == null && _roots.isEmpty)
          const Notice('当前账号还没有可挂载的硬盘。')
        else if (_roots.isNotEmpty)
          IsleGroupCard(
            margin: EdgeInsets.zero,
            children: [
              for (final root in _roots)
                IsleGroupTile(
                  icon: Icons.link_rounded,
                  iconBgColor: root.online
                      ? mineral
                      : palette['brandAmber'],
                  title: root.name,
                  subtitle: root.online ? _mountUrl(root) : '离线 · 请接回原盘',
                  trailing: root.online
                      ? TextButton.icon(
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () {
                            Clipboard.setData(
                              ClipboardData(text: _buildTvClientGuide(root)),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('已复制 Infuse / VidHub 大屏接入参数'),
                              ),
                            );
                          },
                          icon: const Icon(Icons.tv_rounded, size: 15),
                          label: const Text('Infuse 参数'),
                        )
                      : null,
                  onTap: root.online
                      ? () {
                          Clipboard.setData(
                            ClipboardData(text: _mountUrl(root)),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已复制 WebDAV 连接地址')),
                          );
                        }
                      : null,
                ),
            ],
          ),
      ],
    );

    final credentialsColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IsleSectionHeader(
          title: '访问密码（${_credentials.length}）',
          accentColor: violet,
          helpTitle: '独立访问密码机制',
          helpBody: 'NAS 服务端仅保存密码哈希摘要，不存储明文；在本机生成的密码会加密保存在当前设备安全存储中方便随时复制，换设备后若遗忘可一键重新生成。',
        ),
        if (_loading)
          const IsleLoadingState(compact: true, label: '正在加载 WebDAV 配置…')
        else if (_credentials.isEmpty)
          const IsleEmptyStateCard(
            '点击上方「生成新密码」即可为访达或 Infuse 创建独立密码。',
            icon: Icons.vpn_key_outlined,
          )
        else
          IsleGroupCard(
            margin: EdgeInsets.zero,
            children: [
              for (final credential in _credentials)
                IsleGroupTile(
                  icon: Icons.key_rounded,
                  iconBgColor: violet,
                  title: credential.label,
                  subtitle: '最近使用：${_formatDate(credential.lastUsedAt)}',
                  onTap: _busy ? null : () => unawaited(_manage(credential)),
                ),
            ],
          ),
      ],
    );

    return Scaffold(
      appBar: IsleAppBar(
        title: const Text('WebDAV 访问'),
        actions: [
          IconButton(
            tooltip: '刷新 WebDAV 状态',
            onPressed: _loading || _busy ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IsleHelpButton(
            title: 'WebDAV 挂载指南',
            accentColor: mineral,
            items: const [
              IsleHelpItem(
                title: 'macOS 访达与 iOS 文件 App',
                body: '复制挂载地址后，在 macOS 访达按 ⌘K（前往 → 连接服务器）或 iPhone「文件 → 连接服务器」粘贴地址，输入当前用户名与生成的独立访问密码即可。',
              ),
              IsleHelpItem(
                title: 'Apple TV / Infuse / VidHub',
                body: '点击对应硬盘右侧的「Infuse 参数」即可复制协议、端口与完整路径，在电视端新增 WebDAV 源直接刮削原画播放。',
              ),
            ],
          ),
        ],
      ),
      body: IsleListView(
        maxWidth: IsleLayout.workbenchMaxWidth,
        children: [
          IsleFocalStage(
            icon: Icons.cloud_sync_rounded,
            accent: mineral,
            title: 'WebDAV 挂载与大屏播放',
            metrics: [
              IsleFocalMetric(
                label: '在线盘位',
                value: '${_roots.where((r) => r.online).length}',
                accent: sage,
              ),
              IsleFocalMetric(
                label: '独立密码',
                value: '${_credentials.length}',
                accent: violet,
              ),
            ],
            actions: [
              FilledButton.icon(
                onPressed: _busy ? null : () => unawaited(_create()),
                icon: const Icon(Icons.add_rounded, size: 17),
                label: Text(_busy ? '处理中…' : '生成新密码'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_error != null) Notice(_error!, error: true, onRetry: _load),
          if (_mountError != null)
            Notice(_mountError!, error: true, onRetry: _load),
          if (_localVaultNotice != null) Notice(_localVaultNotice!),
          IsleWorkbenchSplit(
            breakpoint: 860,
            primaryFlex: 6,
            secondaryFlex: 6,
            primary: mountsColumn,
            secondary: credentialsColumn,
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _DavLabelDialog extends StatefulWidget {
  const _DavLabelDialog();

  @override
  State<_DavLabelDialog> createState() => _DavLabelDialogState();
}

class _DavLabelDialogState extends State<_DavLabelDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('生成 WebDAV 密码'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLength: 64,
      decoration: const InputDecoration(
        labelText: '密码标签',
        hintText: '如：iPad Infuse',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text.trim()),
        child: const Text('生成'),
      ),
    ],
  );
}
