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

  (Color, IconData, String, String, String) _resolveEntryMeta(
    Map<String, dynamic> entry,
    ColorScheme colors,
    IslePalette palette,
  ) {
    final failed = _audit && entry['outcome'] != 'success';
    final active = entry['active'] == true;
    final acknowledged = entry['acknowledged'] == true;

    final Color badgeColor;
    final IconData badgeIcon;
    if (_audit) {
      badgeColor = failed ? colors.error : palette['brandIndigo'];
      badgeIcon = Icons.shield_outlined;
    } else if (active && !acknowledged) {
      badgeColor = colors.error;
      badgeIcon = Icons.warning_amber_rounded;
    } else if (active && acknowledged) {
      badgeColor = palette['brandAmber'];
      badgeIcon = Icons.error_outline_rounded;
    } else {
      badgeColor = palette['brandSage'];
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

    final targetText = entry['target']?.toString().trim() ?? '';
    final subtitleText = _audit
        ? '${accountTime(entry['createdAt'])}${targetText.isNotEmpty ? ' · $targetText' : ''}'
        : '${active ? (acknowledged ? '已确认，异常仍存在' : '待确认') : '已恢复'} · ${accountTime(entry['firstSeen'])}';

    return (badgeColor, badgeIcon, title, subtitleText, outcome);
  }

  Widget _buildListTileEntry(Map<String, dynamic> entry) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette.of(context);
    final active = entry['active'] == true;
    final acknowledged = entry['acknowledged'] == true;
    final (badgeColor, badgeIcon, title, subtitleText, outcome) =
        _resolveEntryMeta(entry, colors, palette);

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: badgeColor.withValues(alpha: isDark ? 0.22 : 0.12),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Icon(badgeIcon, color: badgeColor, size: 17),
      ),
      title: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          height: 1.28,
        ),
      ),
      subtitle: Text(
        subtitleText,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: colors.onSurfaceVariant,
          fontSize: 12,
        ),
      ),
      trailing: !_audit && active && !acknowledged
          ? FilledButton.tonal(
              onPressed: _busy != null || _loading
                  ? null
                  : () => _acknowledge(entry),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
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

  Widget _buildDesktopCardEntry(Map<String, dynamic> entry) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final active = entry['active'] == true;
    final acknowledged = entry['acknowledged'] == true;
    final (badgeColor, badgeIcon, title, subtitleText, outcome) =
        _resolveEntryMeta(entry, colors, palette);

    return IsleSurface(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(14),
      radius: IsleRadius.card,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IsleSquircleBadge(
            icon: badgeIcon,
            color: badgeColor,
            size: 34,
            iconSize: 18,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitleText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          !_audit && active && !acknowledged
              ? FilledButton.tonal(
                  onPressed: _busy != null || _loading
                      ? null
                      : () => _acknowledge(entry),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  child: const Text('确认已知晓'),
                )
              : IsleBadgePill(
                  label: _audit
                      ? outcome
                      : (entry['severity'] == 'critical' ? '严重' : '警告'),
                  color: badgeColor,
                ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    final attentionCount = _audit
        ? _entries.where((e) => e['outcome'] != 'success').length
        : _entries
              .where((e) => e['active'] == true && e['acknowledged'] != true)
              .length;

    return Scaffold(
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
          IsleHelpButton(
            title: _audit ? '安全审计说明' : '异常通知说明',
            accentColor: _audit
                ? palette['brandIndigo']
                : palette['brandAmber'],
            body: _audit
                ? '记录密码修改、目录权限变更、公开分享创建与下载等关键安全事件，便于家庭管理员追溯核查。'
                : '汇总存储离线、后台扫描失败或容量异常等需要管理员留意的系统通知；确认已知晓后通知将归入历史。',
          ),
        ],
      ),
      body: IsleListView(
        maxWidth: IsleLayout.workbenchMaxWidth,
        children: [
          IsleFocalStage(
            icon: _audit
                ? Icons.policy_outlined
                : Icons.notifications_active_outlined,
            accent: _audit ? palette['brandIndigo'] : palette['brandAmber'],
            title: _audit ? '安全审计记录' : '存储与任务异常通知',
            metrics: [
              IsleFocalMetric(
                label: _audit ? '已加载记录' : '当前通知',
                value: '${_entries.length} 条',
                icon: Icons.format_list_bulleted_rounded,
                color: _audit ? palette['brandIndigo'] : palette['brandBlue'],
              ),
              IsleFocalMetric(
                label: _audit ? '异常或拒绝' : '待确认告警',
                value: '$attentionCount 条',
                icon: attentionCount > 0
                    ? Icons.warning_amber_rounded
                    : Icons.verified_outlined,
                color: attentionCount > 0
                    ? Theme.of(context).colorScheme.error
                    : palette['brandSage'],
              ),
            ],
            actions: [
              if (!_audit)
                FilterChip(
                  visualDensity: VisualDensity.compact,
                  label: const Text('包含已恢复的历史'),
                  selected: _history,
                  onSelected: _busy != null
                      ? null
                      : (value) {
                          setState(() => _history = value);
                          _load(reset: true);
                        },
                ),
            ],
          ),
          if (_loading || _busy != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: ClipRRect(
                borderRadius: IsleRadius.brPill,
                child: const LinearProgressIndicator(minHeight: 3),
              ),
            ),
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
            LayoutBuilder(
              builder: (context, constraints) {
                final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
                if (constraints.maxWidth >= 780 && textScale <= 1.35) {
                  return IsleResponsiveGrid(
                    minItemWidth: 360,
                    maxColumns: 2,
                    spacing: 12,
                    runSpacing: 10,
                    children: [
                      for (final entry in _entries)
                        _buildDesktopCardEntry(entry),
                    ],
                  );
                }
                return IsleGroupCard(
                  margin: EdgeInsets.zero,
                  children: [
                    for (final entry in _entries) _buildListTileEntry(entry),
                  ],
                );
              },
            ),
          if (_audit && _cursor > 0)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: OutlinedButton(
                onPressed: _loading ? null : _load,
                child: const Text('查看更多审计记录'),
              ),
            ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
