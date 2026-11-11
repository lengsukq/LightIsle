import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';

const kAppChannelOptions = [
  ('bark', 'Bark'),
  ('webhook', 'Webhook'),
  ('email', '邮件'),
  ('wecom', '企业微信'),
  ('dingtalk', '钉钉'),
];
const kAppEventOptions = [
  ('failure', '执行失败'),
  ('timeout', '执行超时'),
  ('success', '执行成功'),
];
const kIdleTimeoutOptions = [
  (300, '5分钟'),
  (900, '15分钟'),
  (1800, '30分钟'),
  (3600, '1小时'),
];

class AppConfigDraft {
  AppConfigDraft({
    required this.id,
    required this.name,
    required this.revision,
    required this.accessPolicy,
    required this.allowedUserIDs,
    required this.hasWeb,
    required this.webEnabled,
    required this.webMode,
    required this.idleTimeoutSeconds,
    required this.autoRestart,
    required this.hasCron,
    required this.cronEnabled,
    required this.cronExpression,
    required this.timezone,
    required this.events,
    required this.channels,
  });

  factory AppConfigDraft.fromApp(Map<String, dynamic> app) {
    Map<String, dynamic> asMap(Object? v) =>
        v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};
    final access = asMap(app['access']), web = asMap(app['web']);
    final cron = asMap(app['cron']), schedule = asMap(cron['schedule']);
    final notification = asMap(cron['notification']);
    final hasWeb =
        (app['web'] is Map && web['mode']?.toString() != 'none') ||
        ((app['mode']?.toString().isNotEmpty ?? false) &&
            app['mode']?.toString() != 'none');
    final hasCron = cron['hasCron'] is bool
        ? cron['hasCron'] == true
        : (app['cron'] is Map &&
              ((cron['entry']?.toString().isNotEmpty ?? false) ||
                  (cron['cron']?.toString().isNotEmpty ?? false) ||
                  (schedule['cron']?.toString().isNotEmpty ?? false)));
    final rawAllowed =
        access['allowedUserIDs'] ?? access['allowedUserIds'] ?? const [];
    final allowedIds = <int>{
      if (rawAllowed is List)
        for (final item in rawAllowed)
          if ((item is num ? item.toInt() : int.tryParse('$item') ?? 0) > 0)
            item is num ? item.toInt() : int.parse('$item'),
    };
    Set<String> strSet(Object? raw, List<String> fallback) => {
      for (final e in (raw is List ? raw : fallback))
        if (e.toString().isNotEmpty) e.toString(),
    };
    final idleRaw = web['idleTimeoutSeconds'] ?? app['idleTimeoutSeconds'];
    final idle = idleRaw is num
        ? idleRaw.toInt()
        : int.tryParse('$idleRaw') ?? 900;
    return AppConfigDraft(
      id: app['id']?.toString() ?? '',
      name: app['name']?.toString() ?? app['id']?.toString() ?? '轻应用',
      revision: app['revision']?.toString(),
      accessPolicy:
          access['policy']?.toString() ??
          app['accessPolicy']?.toString() ??
          'admin_only',
      allowedUserIDs: allowedIds,
      hasWeb: hasWeb,
      webEnabled: web['enabled'] != false,
      webMode:
          web['mode']?.toString() ?? app['mode']?.toString() ?? 'on-demand',
      idleTimeoutSeconds: idle > 0 ? idle : 900,
      autoRestart: web['autoRestart'] != false,
      hasCron: hasCron,
      cronEnabled: cron['enabled'] == true,
      cronExpression:
          cron['cron']?.toString() ?? schedule['cron']?.toString() ?? '',
      timezone:
          cron['timezone']?.toString() ??
          schedule['timezone']?.toString() ??
          'Asia/Shanghai',
      events: strSet(cron['events'] ?? notification['events'], const [
        'failure',
        'timeout',
      ]),
      channels: strSet(cron['channels'] ?? notification['channels'], const []),
    );
  }

  final String id, name;
  final String? revision;
  final bool hasWeb, hasCron;
  String accessPolicy, webMode, cronExpression, timezone;
  Set<int> allowedUserIDs;
  bool webEnabled, autoRestart, cronEnabled;
  int idleTimeoutSeconds;
  Set<String> events, channels;

  Map<String, dynamic> toPutBody({required bool isAccessMode}) {
    if (isAccessMode) {
      return {
        if (revision != null && revision!.isNotEmpty) 'revision': revision,
        'access': {
          'policy': accessPolicy,
          'allowedUserIDs': accessPolicy == 'selected_members'
              ? (allowedUserIDs.toList()..sort())
              : const <int>[],
        },
      };
    }
    return {
      if (revision != null && revision!.isNotEmpty) 'revision': revision,
      if (hasWeb)
        'web': {
          'enabled': webEnabled,
          'mode': webMode,
          'idleTimeoutSeconds': idleTimeoutSeconds,
          'autoRestart': autoRestart,
        },
      if (hasCron)
        'cron': {
          'enabled': cronEnabled,
          'cron': cronExpression.trim(),
          'timezone': timezone.trim().isEmpty
              ? 'Asia/Shanghai'
              : timezone.trim(),
          'events': events.toList(growable: false),
          'channels': channels.toList(growable: false),
        },
    };
  }
}

Widget _radioTile(
  BuildContext context,
  Key key,
  bool selected,
  String title,
  String subtitle,
  VoidCallback? onTap,
) {
  final colors = Theme.of(context).colorScheme;
  return ListTile(
    key: key,
    contentPadding: EdgeInsets.zero,
    onTap: onTap,
    leading: Icon(
      selected
          ? Icons.radio_button_checked_rounded
          : Icons.radio_button_off_rounded,
      color: selected ? colors.primary : colors.onSurfaceVariant,
    ),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
    subtitle: Text(subtitle),
  );
}

Widget _sheetScaffold(
  BuildContext context, {
  required String title,
  String? subtitle,
  String? error,
  required bool busy,
  required Key saveKey,
  required String saveLabel,
  required VoidCallback onSave,
  required List<Widget> children,
}) {
  final theme = Theme.of(context);
  return Padding(
    padding: EdgeInsets.fromLTRB(
      20,
      4,
      20,
      MediaQuery.viewInsetsOf(context).bottom + 20,
    ),
    child: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle, style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: 10),
          if (error != null) Notice(error, error: true),
          ...children,
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: busy ? null : () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: saveKey,
                onPressed: busy ? null : onSave,
                child: Text(busy ? '保存中…' : saveLabel),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

Future<Map<String, dynamic>?> showAppMemberAccessSheet({
  required BuildContext context,
  required LightIsleApi api,
  required Map<String, dynamic> app,
  required List<Map<String, dynamic>> members,
}) => showModalBottomSheet<Map<String, dynamic>>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => _AppConfigSheet(
    api: api,
    draft: AppConfigDraft.fromApp(app),
    members: members,
    isAccessMode: true,
  ),
);

Future<Map<String, dynamic>?> showAppLifecycleCronSheet({
  required BuildContext context,
  required LightIsleApi api,
  required Map<String, dynamic> app,
  required Set<String> configuredChannels,
}) => showModalBottomSheet<Map<String, dynamic>>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => _AppConfigSheet(
    api: api,
    draft: AppConfigDraft.fromApp(app),
    configuredChannels: configuredChannels,
    isAccessMode: false,
  ),
);

class _AppConfigSheet extends StatefulWidget {
  const _AppConfigSheet({
    required this.api,
    required this.draft,
    required this.isAccessMode,
    this.members = const [],
    this.configuredChannels = const {},
  });

  final LightIsleApi api;
  final AppConfigDraft draft;
  final bool isAccessMode;
  final List<Map<String, dynamic>> members;
  final Set<String> configuredChannels;

  @override
  State<_AppConfigSheet> createState() => _AppConfigSheetState();
}

class _AppConfigSheetState extends State<_AppConfigSheet> {
  late final TextEditingController _cronController, _tzController;
  bool _busy = false;
  String? _error;

  static const _policies = [
    ('admin_only', '仅管理员', '仅家庭管理员可见与打开（默认安全策略）'),
    ('selected_members', '指定成员', '仅勾选的家庭成员与管理员可在应用中心使用'),
    ('all_members', '全员可用', '所有家庭成员均可在应用中心免密打开'),
  ];

  static const _modes = [
    ('static', '纯静态 0 MB', '直接托管 ui/ 静态页面，不启动后台 Web 进程'),
    ('on-demand', '按需休眠 0 MB', '访问时自动拉起，闲置超时后自动休眠释放内存'),
    ('persistent', '常驻守护', '24/7 持续运行并自动重启，适合实时监控服务'),
  ];

  @override
  void initState() {
    super.initState();
    _cronController = TextEditingController(text: widget.draft.cronExpression);
    _tzController = TextEditingController(text: widget.draft.timezone);
  }

  @override
  void dispose() {
    _cronController.dispose();
    _tzController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    if (!widget.isAccessMode) {
      widget.draft.cronExpression = _cronController.text.trim();
      widget.draft.timezone = _tzController.text.trim();
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await widget.api.send(
        'PUT',
        '/api/v2/apps/${Uri.encodeComponent(widget.draft.id)}',
        body: widget.draft.toPutBody(isAccessMode: widget.isAccessMode),
      );
      if (mounted) Navigator.of(context).pop(res);
    } catch (e) {
      if (mounted) setState(() => _error = '保存失败：${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    if (widget.isAccessMode) {
      return _sheetScaffold(
        context,
        title: '成员访问权限 · ${draft.name}',
        subtitle: '控制哪些家庭成员可以在 Web 与客户端「应用中心」看到并打开此应用。',
        error: _error,
        busy: _busy,
        saveKey: const ValueKey('saveMemberAccessButton'),
        saveLabel: '保存权限',
        onSave: _save,
        children: [
          for (final (val, label, sub) in _policies)
            _radioTile(
              context,
              ValueKey('accessPolicy_$val'),
              draft.accessPolicy == val,
              label,
              sub,
              _busy ? null : () => setState(() => draft.accessPolicy = val),
            ),
          if (draft.accessPolicy == 'selected_members') ...[
            const Divider(height: 20),
            Text('勾选允许访问的家庭成员', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            if (widget.members.isEmpty)
              const Text('当前没有可选的家庭成员账号。')
            else
              for (final m in widget.members) _buildMemberCheckbox(m, draft),
          ],
        ],
      );
    }
    final labelStyle = Theme.of(context).textTheme.labelLarge;
    return _sheetScaffold(
      context,
      title: '运行模式与定时设置 · ${draft.name}',
      error: _error,
      busy: _busy,
      saveKey: const ValueKey('saveLifecycleCronButton'),
      saveLabel: '保存设置',
      onSave: _save,
      children: [
        if (draft.hasWeb) ...[
          Text('Web 运行模式', style: labelStyle),
          for (final (mode, title, desc) in _modes)
            _radioTile(
              context,
              ValueKey('webMode_$mode'),
              draft.webMode == mode,
              title,
              desc,
              _busy ? null : () => setState(() => draft.webMode = mode),
            ),
          if (draft.webMode == 'on-demand') ...[
            Text('闲置自动休眠时长', style: labelStyle),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final (secs, label) in kIdleTimeoutOptions)
                  ChoiceChip(
                    key: ValueKey('idleTimeout_$secs'),
                    label: Text(label),
                    selected: draft.idleTimeoutSeconds == secs,
                    onSelected: _busy
                        ? null
                        : (_) =>
                              setState(() => draft.idleTimeoutSeconds = secs),
                  ),
              ],
            ),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('异常退出自动重启'),
            value: draft.autoRestart,
            onChanged: _busy
                ? null
                : (v) => setState(() => draft.autoRestart = v),
          ),
        ],
        if (draft.hasWeb && draft.hasCron) const Divider(height: 20),
        if (draft.hasCron) ...[
          SwitchListTile(
            key: const ValueKey('cronEnableSwitch'),
            contentPadding: EdgeInsets.zero,
            title: const Text('启用后台定时任务 (run-cron.sh)'),
            subtitle: const Text('仅修改调度与通知渠道，保留原脚本与邮件模板设置'),
            value: draft.cronEnabled,
            onChanged: _busy
                ? null
                : (v) => setState(() => draft.cronEnabled = v),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('cronExpressionField'),
                  controller: _cronController,
                  decoration: const InputDecoration(
                    labelText: '五段 Cron',
                    hintText: '*/15 * * * *',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  key: const ValueKey('cronTimezoneField'),
                  controller: _tzController,
                  decoration: const InputDecoration(
                    labelText: '时区',
                    hintText: 'Asia/Shanghai',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text('通知事件', style: labelStyle),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final (evId, evLabel) in kAppEventOptions)
                FilterChip(
                  label: Text(evLabel),
                  selected: draft.events.contains(evId),
                  onSelected: _busy
                      ? null
                      : (sel) => setState(
                          () => sel
                              ? draft.events.add(evId)
                              : draft.events.remove(evId),
                        ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text('通知渠道', style: labelStyle),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final (chId, chLabel) in kAppChannelOptions)
                FilterChip(
                  label: Text(
                    widget.configuredChannels.contains(chId)
                        ? chLabel
                        : '$chLabel（未配置）',
                  ),
                  selected: draft.channels.contains(chId),
                  onSelected: !_busy && widget.configuredChannels.contains(chId)
                      ? (sel) => setState(
                          () => sel
                              ? draft.channels.add(chId)
                              : draft.channels.remove(chId),
                        )
                      : null,
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildMemberCheckbox(
    Map<String, dynamic> member,
    AppConfigDraft draft,
  ) {
    final rawId = member['id'];
    final id = rawId is num ? rawId.toInt() : int.tryParse('$rawId') ?? 0;
    if (id <= 0) return const SizedBox.shrink();
    final isAdminRole = member['role'] == 'admin';
    return CheckboxListTile(
      key: ValueKey('memberAccess_$id'),
      contentPadding: EdgeInsets.zero,
      value: isAdminRole || draft.allowedUserIDs.contains(id),
      title: Text(member['username']?.toString() ?? '成员 #$id'),
      subtitle: Text(isAdminRole ? '家庭管理员（始终可访问）' : '家庭成员'),
      onChanged: _busy || isAdminRole
          ? null
          : (sel) => setState(
              () => sel == true
                  ? draft.allowedUserIDs.add(id)
                  : draft.allowedUserIDs.remove(id),
            ),
    );
  }
}

Future<void> showAppLogsSheet({
  required BuildContext context,
  required LightIsleApi api,
  required Map<String, dynamic> app,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => _AppLogsSheet(api: api, app: app),
);

class _AppLogsSheet extends StatefulWidget {
  const _AppLogsSheet({required this.api, required this.app});
  final LightIsleApi api;
  final Map<String, dynamic> app;
  @override
  State<_AppLogsSheet> createState() => _AppLogsSheetState();
}

class _AppLogsSheetState extends State<_AppLogsSheet> {
  bool _busy = false;
  String? _error;
  String _webOutput = '';
  List<Map<String, dynamic>> _cronRuns = const [];

  String get _appId => widget.app['id']?.toString() ?? '';
  String get _appName => widget.app['name']?.toString() ?? _appId;

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    if (_busy || _appId.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await widget.api.get(
        '/api/v2/apps/${Uri.encodeComponent(_appId)}/logs',
      );
      if (!mounted) return;
      setState(() {
        _webOutput = res['webOutput']?.toString() ?? '';
        _cronRuns = objectList(res['cronRuns']);
      });
    } catch (e) {
      if (mounted) setState(() => _error = '读取日志失败：${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 540),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '运行日志 · $_appName',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新日志',
                    onPressed: _busy ? null : _loadLogs,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Notice(_error!, error: true, onRetry: _loadLogs),
              const SizedBox(height: 8),
              Text('Web 子进程输出', style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              _monoBox(
                _webOutput.trim().isNotEmpty ? _webOutput : '（暂无 Web 进程输出）',
              ),
              const SizedBox(height: 14),
              Text(
                '定时任务记录（${_cronRuns.length}）',
                style: theme.textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              if (_cronRuns.isEmpty)
                const Text('暂无定时执行记录。')
              else
                for (final run in _cronRuns)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text(
                      '${run['state'] ?? 'unknown'}${run['exitCode'] is int ? ' · 退出码 ${run['exitCode']}' : ''}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    children: [
                      _monoBox(
                        (run['output']?.toString().trim().isNotEmpty == true)
                            ? run['output'].toString()
                            : '（无标准输出）',
                      ),
                    ],
                  ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _monoBox(String text) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(10),
    ),
    child: SelectableText(
      text,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
    ),
  );
}
