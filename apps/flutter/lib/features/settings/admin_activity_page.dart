import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'account_security_page.dart';

enum AdminActivity { alerts, audit }

class AdminActivityPage extends StatefulWidget {
  const AdminActivityPage({super.key, required this.api, required this.kind});
  final LightIsleApi api;
  final AdminActivity kind;
  @override
  State<AdminActivityPage> createState() => _AdminActivityPageState();
}

class _AdminActivityPageState extends State<AdminActivityPage> {
  List<Map<String, dynamic>> _entries = [];
  int _cursor = 0, _generation = 0;
  bool _loading = false, _history = false;
  String? _busy, _error;
  bool get _audit => widget.kind == AdminActivity.audit;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading && !reset) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await widget.api.get(
        _audit ? '/api/v2/audit' : '/api/v2/alerts',
        query: _audit
            ? {'limit': '40', if (!reset && _cursor > 0) 'before': '$_cursor'}
            : {if (_history) 'history': '1'},
      );
      if (!mounted || generation != _generation) return;
      final entries = objectList(response[_audit ? 'events' : 'alerts']);
      setState(() {
        _entries = reset ? entries : [..._entries, ...entries];
        _cursor = (response['nextCursor'] as num?)?.toInt() ?? 0;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = userFacingError(error));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _acknowledge(Map<String, dynamic> alert) async {
    if (_busy != null) return;
    final code = alert['code']?.toString();
    if (code == null || code.isEmpty) return;
    setState(() {
      _busy = code;
      _error = null;
    });
    try {
      await widget.api.send(
        'POST',
        '/api/v2/alerts/${Uri.encodeComponent(code)}/acknowledge',
      );
      if (mounted) await _load(reset: true);
    } catch (error) {
      if (mounted) setState(() => _error = userFacingError(error));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  static const _actionLabels = {
    'account_password_change': '修改账号密码',
    'user_or_grant_change': '账号 / 文件权限修改',
    'file_share_change': '公开分享链接操作',
    'public_share_download': '公开分享下载',
    'file_write': '文件管理操作',
    'upload_write': '文件续传操作',
    'gallery_write': '图库操作',
    'cinema_write': '影视资料操作',
    'alert_acknowledge': '确认异常通知',
  };

  Widget _entry(Map<String, dynamic> entry) {
    final failed = _audit && entry['outcome'] != 'success';
    final active = entry['active'] == true;
    final acknowledged = entry['acknowledged'] == true;
    final color = failed || (!_audit && active && !acknowledged)
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final title = _audit
        ? '${_actionLabels[entry['action']] ?? entry['action'] ?? '操作记录'} · 用户 #${entry['actorId']}'
        : entry['message']?.toString() ?? '异常通知';
    final outcome = entry['outcome'] == 'success'
        ? '成功'
        : entry['outcome'] == 'denied'
        ? '被拒绝'
        : '失败';
    return IsleSurface(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _audit
                    ? Icons.shield_outlined
                    : active && !acknowledged
                    ? Icons.warning_amber_rounded
                    : Icons.check_circle_outline,
                color: color,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _audit
                ? '$outcome · ${accountTime(entry['createdAt'])}\n${entry['target'] ?? ''}'
                : '${entry['severity'] == 'critical' ? '严重' : '警告'} · ${active
                      ? acknowledged
                            ? '已确认，异常仍存在'
                            : '待确认'
                      : '已恢复'}\n发现于 ${accountTime(entry['firstSeen'])}',
            style: TextStyle(color: color, height: 1.5),
          ),
          if (!_audit && active && !acknowledged) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _busy != null || _loading
                  ? null
                  : () => _acknowledge(entry),
              child: const Text('确认已知晓'),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_audit ? '安全审计' : '存储与任务通知'),
      actions: [
        IconButton(
          tooltip: '刷新记录',
          onPressed: _loading || _busy != null
              ? null
              : () => _load(reset: true),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: IsleListView(
      padding: const EdgeInsets.all(20),
      children: [
        Notice(
          _audit
              ? '查看最近 90 天、最多 20,000 条操作记录；不记录密码、会话令牌、分享密钥或文件内容。'
              : '查看共享盘离线、剩余空间过低、备份及媒体扫描失败。确认已知晓不会消除实际故障；新状态可手动刷新。',
        ),
        if (!_audit)
          Align(
            alignment: Alignment.centerLeft,
            child: FilterChip(
              label: const Text('包含已恢复的历史'),
              selected: _history,
              onSelected: _busy != null
                  ? null
                  : (value) {
                      setState(() => _history = value);
                      _load(reset: true);
                    },
            ),
          ),
        if (_loading || _busy != null) const LinearProgressIndicator(),
        if (_error != null)
          Notice(
            _error!,
            error: true,
            onRetry: () => _load(reset: _entries.isEmpty),
          ),
        if (!_loading && _error == null && _entries.isEmpty)
          Notice(
            _audit ? '暂无需要审计的操作。' : '目前没有${_history ? '历史' : '未恢复的'}异常记录。',
          ),
        ..._entries.map(_entry),
        if (_audit && _cursor > 0)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: OutlinedButton(
              onPressed: _loading ? null : _load,
              child: const Text('查看更多审计记录'),
            ),
          ),
      ],
    ),
  );
}
