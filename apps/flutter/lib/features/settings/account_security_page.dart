import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/login_history_store.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';

String? validateNewPassword(String? value) {
  if (value == null ||
      utf8.encode(value).length < 12 ||
      utf8.encode(value).length > 256) {
    return '密码需为 12–256 位';
  }
  return value.trim() != value ? '密码首尾不能有空白字符' : null;
}

String accountTime(Object? value) {
  final seconds = value is num ? value.toInt() : 0;
  if (seconds <= 0) return '—';
  return DateTime.fromMillisecondsSinceEpoch(
    seconds * 1000,
  ).toLocal().toString().split('.').first;
}

class AccountSecurityPage extends StatefulWidget {
  const AccountSecurityPage({
    super.key,
    required this.api,
    required this.onSignedOut,
    this.currentUsername,
    this.historyStore,
  });
  final LightIsleApi api;
  final Future<void> Function() onSignedOut;
  final String? currentUsername;
  final LoginHistoryStore? historyStore;

  @override
  State<AccountSecurityPage> createState() => _AccountSecurityPageState();
}

class _AccountSecurityPageState extends State<AccountSecurityPage> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  List<Map<String, dynamic>> _sessions = [];
  bool _loading = false, _busy = false, _truncated = false;
  String? _loadError, _actionError, _notice;

  void _showActionError(Object error) {
    setState(() => _actionError = userFacingError(error));
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final result = await widget.api.get('/api/v2/auth/sessions');
      if (mounted) {
        setState(() {
          _sessions = objectList(result['sessions']);
          _truncated = result['truncated'] == true;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _loadError = userFacingError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _revoke(String? id) async {
    if (_busy ||
        !await confirmAction(
          context,
          '撤销登录会话',
          id == null ? '其他设备将需要重新登录，当前客户端继续保持登录。' : '此会话将立即失效，对应设备需要重新登录。',
          action: '撤销会话',
          isDestructive: true,
        )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _actionError = null;
      _notice = null;
    });
    try {
      await widget.api.send(
        'DELETE',
        '/api/v2/auth/sessions/${id == null ? 'others' : Uri.encodeComponent(id)}',
      );
      if (mounted) {
        setState(() => _notice = '会话已撤销。');
        await _load();
      }
    } catch (error) {
      if (mounted) _showActionError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changePassword() async {
    if (_busy || !_form.currentState!.validate()) return;
    if (!await confirmAction(
      context,
      '修改登录密码',
      '密码更新后，你在所有设备上的会话都会失效，需要重新登录。',
      action: '更新密码',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _actionError = null;
      _notice = null;
    });
    try {
      final newPassword = _next.text;
      await widget.api.send(
        'POST',
        '/api/v2/auth/password',
        body: {'currentPassword': _current.text, 'newPassword': newPassword},
      );
      if (widget.currentUsername != null &&
          widget.currentUsername!.trim().isNotEmpty) {
        try {
          await (widget.historyStore ?? LoginHistoryStore()).updatePassword(
            widget.api.uri('/').origin,
            widget.currentUsername!,
            newPassword,
          );
        } catch (error) {
          debugPrint(
            'AccountSecurityPage: saved password sync skipped: $error',
          );
        }
      }
      if (!mounted) return;
      _current.clear();
      _next.clear();
      _confirm.clear();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('密码已更新，请重新登录。')));
      await widget.onSignedOut();
    } catch (error) {
      if (mounted) _showActionError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Widget _buildPasswordCard(BuildContext context, IslePalette palette) {
    final theme = Theme.of(context);
    final sage = palette['brandSage'];
    return IsleSurface(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(18),
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IsleSquircleBadge(
                  icon: Icons.lock_outline_rounded,
                  color: sage,
                  size: 34,
                  iconSize: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '修改密码',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _current,
              enabled: !_busy,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '当前密码',
                isDense: true,
              ),
              validator: (v) => v == null || v.isEmpty ? '请输入当前密码' : null,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _next,
              enabled: !_busy,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '新密码',
                helperText: '12–256 位',
                isDense: true,
              ),
              validator: validateNewPassword,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _confirm,
              enabled: !_busy,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '再次输入新密码',
                isDense: true,
              ),
              validator: (v) => v != _next.text ? '两次输入的密码不一致' : null,
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _busy ? null : _changePassword,
                icon: const Icon(Icons.lock_reset, size: 18),
                label: const Text('更新密码'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionsSection(BuildContext context, IslePalette palette) {
    final theme = Theme.of(context);
    final sage = palette['brandSage'];
    final mineral = palette['brandBlue'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '登录会话',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              onPressed: _busy || _loading ? null : () => _revoke(null),
              child: const Text('退出其他会话'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (_loadError != null) Notice(_loadError!, error: true, onRetry: _load),
        if (_loading || _busy) const LinearProgressIndicator(),
        if (!_loading && _loadError == null && _sessions.isEmpty)
          const Notice('暂无登录会话。'),
        if (_sessions.isNotEmpty)
          IsleGroupCard(
            margin: EdgeInsets.zero,
            children: [
              for (final session in _sessions)
                Builder(
                  builder: (context) {
                    final isCurrent = session['current'] == true;
                    final colors = theme.colorScheme;
                    final revocable =
                        !isCurrent &&
                        session['id'] is String &&
                        (session['id'] as String).isNotEmpty;
                    return ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 5,
                      ),
                      leading: IsleSquircleBadge(
                        icon: isCurrent
                            ? Icons.phone_iphone_rounded
                            : Icons.devices_rounded,
                        color: isCurrent ? sage : mineral,
                        size: 34,
                        iconSize: 17,
                      ),
                      title: Text(
                        (session['deviceLabel']?.toString().trim().isNotEmpty ??
                                false)
                            ? session['deviceLabel'].toString().trim()
                            : (isCurrent ? '当前设备' : '远程登录设备'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      subtitle: Text(
                        [
                          if ((session['clientIp']
                                  ?.toString()
                                  .trim()
                                  .isNotEmpty ??
                              false))
                            'IP：${session['clientIp']}',
                          '登录：${accountTime(session['createdAt'])}',
                          if (session['lastSeenAt'] is num &&
                              (session['lastSeenAt'] as num) > 0)
                            '活跃：${accountTime(session['lastSeenAt'])}',
                        ].join(' · '),
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      trailing: isCurrent
                          ? IsleBadgePill(
                              label: '本机当前',
                              color: sage,
                              icon: Icons.fiber_manual_record,
                            )
                          : revocable
                          ? TextButton(
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                              onPressed: _busy || _loading
                                  ? null
                                  : () => _revoke(session['id'] as String),
                              child: const Text('远程下线'),
                            )
                          : null,
                    );
                  },
                ),
            ],
          ),
        if (_truncated) const Notice('会话较多，仅显示最近的部分记录。可使用“退出其他会话”统一撤销。'),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    final sage = palette['brandSage'];
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: IsleAppBar(
          title: const Text('密码与登录会话'),
          actions: [
            IconButton(
              tooltip: '刷新会话',
              onPressed: _loading || _busy ? null : _load,
              icon: const Icon(Icons.refresh_rounded),
            ),
            IsleHelpButton(
              title: '密码与会话安全说明',
              accentColor: sage,
              items: const [
                IsleHelpItem(
                  title: '全端会话联动失效',
                  body: '更新账号登录密码后，当前账号在所有手机、平板与电脑上的已登录会话将立即失效，需重新验证登录。',
                ),
                IsleHelpItem(
                  title: 'WebDAV 独立密码隔离',
                  body: '修改主账号登录密码不会影响已为访达或 Infuse 单独生成的 WebDAV 访问密码；如需停用请前往 WebDAV 页面撤销。',
                ),
              ],
            ),
          ],
        ),
        body: IsleListView(
          maxWidth: IsleLayout.workbenchMaxWidth,
          children: [
            IsleFocalStage(
              icon: Icons.security_rounded,
              accent: sage,
              title: '密码与登录会话',
              metrics: [
                IsleFocalMetric(
                  label: '活跃会话',
                  value: '${_sessions.length}',
                  accent: sage,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_actionError != null) Notice(_actionError!, error: true),
            if (_notice != null) Notice(_notice!),
            IsleWorkbenchSplit(
              breakpoint: 720,
              primaryFlex: 5,
              secondaryFlex: 6,
              primary: _buildPasswordCard(context, palette),
              secondary: _buildSessionsSection(context, palette),
            ),
          ],
        ),
      ),
    );
  }
}

class ResetMemberPasswordDialog extends StatefulWidget {
  const ResetMemberPasswordDialog({
    super.key,
    required this.api,
    required this.user,
  });
  final LightIsleApi api;
  final Map<String, dynamic> user;
  @override
  State<ResetMemberPasswordDialog> createState() =>
      _ResetMemberPasswordDialogState();
}

class _ResetMemberPasswordDialogState extends State<ResetMemberPasswordDialog> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController(), _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _reset() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.send(
        'POST',
        '/api/v2/users/${widget.user['id']}/password',
        body: {'password': _password.text},
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() => _error = userFacingError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        shape: IsleShapes.card(
          side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
        ),
        title: Text('重置 ${widget.user['username']} 的密码'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Form(
              key: _form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('更新后该成员的所有会话都会失效。'),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _password,
                    enabled: !_busy,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '新密码',
                      isDense: true,
                    ),
                    validator: validateNewPassword,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _confirm,
                    enabled: !_busy,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '确认新密码',
                      isDense: true,
                    ),
                    validator: (v) =>
                        v != _password.text ? '两次输入的密码不一致' : null,
                  ),
                  if (_error != null) Notice(_error!, error: true),
                  if (_busy) const LinearProgressIndicator(),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _busy ? null : _reset,
            child: const Text('重置密码'),
          ),
        ],
      ),
    );
  }
}
