import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
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
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000)
      .toLocal()
      .toString()
      .split('.')
      .first;
}

class AccountSecurityPage extends StatefulWidget {
  const AccountSecurityPage({
    super.key,
    required this.api,
    required this.onSignedOut,
  });
  final LightIsleApi api;
  final Future<void> Function() onSignedOut;

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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(userFacingError(error))));
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
      await widget.api.send(
        'POST',
        '/api/v2/auth/password',
        body: {'currentPassword': _current.text, 'newPassword': _next.text},
      );
      if (!mounted) return;
      _current.clear();
      _next.clear();
      _confirm.clear();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('密码已更新，请重新登录。')));
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

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('密码与登录会话')),
      body: IsleListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (_actionError != null) Notice(_actionError!, error: true),
          if (_notice != null) Notice(_notice!),
          IsleSurface(
            padding: const EdgeInsets.all(20),
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('修改密码', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _current,
                    enabled: !_busy,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '当前密码'),
                    validator: (v) => v == null || v.isEmpty ? '请输入当前密码' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _next,
                    enabled: !_busy,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '新密码',
                      helperText: '12–256 字节，首尾不能有空白字符',
                    ),
                    validator: validateNewPassword,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _confirm,
                    enabled: !_busy,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '再次输入新密码'),
                    validator: (v) => v != _next.text ? '两次输入的密码不一致' : null,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy ? null : _changePassword,
                    icon: const Icon(Icons.lock_reset),
                    label: const Text('更新密码'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('登录会话', style: Theme.of(context).textTheme.titleLarge),
              TextButton.icon(
                onPressed: _loading || _busy ? null : _load,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新会话'),
              ),
              OutlinedButton(
                onPressed: _busy || _loading ? null : () => _revoke(null),
                child: const Text('退出其他会话'),
              ),
            ],
          ),
          const Notice('列表仅显示会话编号、创建及到期时间。当前会话可在设置中退出登录。'),
          if (_loadError != null)
            Notice(_loadError!, error: true, onRetry: _load),
          if (_loading || _busy) const LinearProgressIndicator(),
          if (!_loading && _loadError == null && _sessions.isEmpty)
            const Notice('暂无登录会话。'),
          for (final session in _sessions)
            IsleSurface(
              margin: const EdgeInsets.symmetric(vertical: 6),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    session['current'] == true ? '当前会话' : '其他会话',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '创建：${accountTime(session['createdAt'])}\n到期：${accountTime(session['expiresAt'])}',
                  ),
                  if (session['current'] != true &&
                      session['id'] is String &&
                      (session['id'] as String).isNotEmpty)
                    TextButton(
                      onPressed: _busy || _loading
                          ? null
                          : () => _revoke(session['id'] as String),
                      child: const Text('撤销此会话'),
                    ),
                ],
              ),
            ),
          if (_truncated) const Notice('会话较多，仅显示最近的部分记录。可使用“退出其他会话”统一撤销。'),
        ],
      ),
    ),
  );
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
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
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
                const Text('仅恢复普通成员账号。更新后该成员的所有会话都会失效。'),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _password,
                  enabled: !_busy,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '新密码'),
                  validator: validateNewPassword,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _confirm,
                  enabled: !_busy,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '确认新密码'),
                  validator: (v) => v != _password.text ? '两次输入的密码不一致' : null,
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
