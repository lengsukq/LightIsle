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
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final Color badgeColor;
    final IconData badgeIcon;
    if (_audit) {
      badgeColor = failed ? colors.error : const Color(0xff6366f1);
      badgeIcon = Icons.shield_outlined;
    } else if (active && !acknowledged) {
      badgeColor = colors.error;
      badgeIcon = Icons.warning_amber_rounded;
    } else if (active && acknowledged) {
      badgeColor = const Color(0xfff59e0b);
      badgeIcon = Icons.error_outline_rounded;
    } else {
      badgeColor = const Color(0xff10b981);
      badgeIcon = Icons.check_circle_outline_rounded;
    }

    final title = _audit
        ? '${_actionLabels[entry['action']] ?? entry['action'] ?? '操作记录'} · 用户 #${entry['actorId']}'
        : entry['message']?.toString() ?? '异常通知';
    final outcome = entry['outcome'] == 'success'
        ? '成功'
        : entry['outcome'] == 'denied'
        ? '被拒绝'
        : '失败';

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: badgeColor.withValues(alpha: isDark ? 0.22 : 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(badgeIcon, color: badgeColor, size: 18),
      ),
      title: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
          height: 1.3,
        ),
      ),
      subtitle: Text(
        _audit
            ? '${accountTime(entry['createdAt'])}\n${entry['target'] ?? ''}'
            : '${active ? (acknowledged ? '已确认，异常仍存在' : '待确认') : '已恢复'}\n发现于 ${accountTime(entry['firstSeen'])}',
        style: TextStyle(
          color: colors.onSurfaceVariant,
          fontSize: 12.5,
          height: 1.45,
        ),
      ),
      isThreeLine: true,
      trailing:
          !_audit && active && !acknowledged
          ? FilledButton.tonal(
              onPressed: _busy != null || _loading
                  ? null
                  : () => _acknowledge(entry),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: const Text('确认已知晓'),
            )
          : IsleBadgePill(
              label: _audit
                  ? outcome
                  : (entry['severity'] == 'critical' ? '严重' : '警告'),
              color: badgeColor,
            ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: IsleAppBar(
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
      children: [
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
          IsleEmptyStateCard(
            _audit ? '暂无需要审计的操作。' : '目前没有${_history ? '历史' : '未恢复的'}异常记录。',
            icon: _audit
                ? Icons.fact_check_outlined
                : Icons.notifications_none_rounded,
          ),
        if (_entries.isNotEmpty)
          IsleResponsiveGrid(
            minItemWidth: 340,
            maxColumns: 2,
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final entry in _entries)
                IsleSurface(
                  radius: 16,
                  margin: EdgeInsets.zero,
                  padding: EdgeInsets.zero,
                  child: _entry(entry),
                ),
            ],
          ),
        if (_audit && _cursor > 0)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: OutlinedButton(
              onPressed: _loading ? null : _load,
              child: const Text('查看更多审计记录'),
            ),
          ),
        IsleHelpDisclosure(
          summary: _audit ? '安全操作记录' : '存储及后台任务告警',
          details: _audit
              ? '可查看最近 90 天最多 20,000 条操作记录，不记录密码、会话令牌、分享密钥或文件内容。'
              : '查看共享盘离线、剩余空间过低、备份和媒体扫描失败。'
                    '确认已知晓不会消除实际故障；有新状态时可以手动刷新。',
        ),
      ],
    ),
  );
}
