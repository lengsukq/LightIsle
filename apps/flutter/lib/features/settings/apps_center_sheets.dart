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
const kAppAccessPolicies = [
  (
    'admin_only',
    '仅管理员',
    '仅家庭管理员可见与打开（默认安全策略）',
    Icons.lock_outline_rounded,
    Color(0xFF6366F1),
  ),
  (
    'selected_members',
    '指定成员',
    '仅勾选的家庭成员与管理员可在应用中心使用',
    Icons.group_outlined,
    Color(0xFF0EA5E9),
  ),
  (
    'all_members',
    '全员可用',
    '所有家庭成员均可在应用中心免密打开',
    Icons.public_rounded,
    Color(0xFF10B981),
  ),
];
const kAppWebModes = [
  (
    'static',
    '纯静态 0 MB',
    '直接托管 ui/ 静态页面，不启动后台 Web 进程',
    Icons.web_asset_rounded,
    Color(0xFF10B981),
  ),
  (
    'on-demand',
    '按需休眠 0 MB',
    '访问时自动拉起，闲置超时后自动休眠释放内存',
    Icons.bolt_rounded,
    Color(0xFF0A84FF),
  ),
  (
    'persistent',
    '常驻守护',
    '24/7 持续运行并自动重启，适合实时监控服务',
    Icons.all_inclusive_rounded,
    Color(0xFF8B5CF6),
  ),
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

  Map<String, dynamic> toPutBody({required bool isAccessMode}) =>
      toSelectivePutBody(
        includeAccess: isAccessMode,
        includeRuntime: !isAccessMode,
      );

  Map<String, dynamic> toSelectivePutBody({
    required bool includeAccess,
    required bool includeRuntime,
  }) => {
    if (revision != null && revision!.isNotEmpty) 'revision': revision,
    if (includeAccess)
      'access': {
        'policy': accessPolicy,
        'allowedUserIDs': accessPolicy == 'selected_members'
            ? (allowedUserIDs.toList()..sort())
            : const <int>[],
      },
    if (includeRuntime && hasWeb)
      'web': {
        'enabled': webEnabled,
        'mode': webMode,
        'idleTimeoutSeconds': idleTimeoutSeconds,
        'autoRestart': autoRestart,
      },
    if (includeRuntime && hasCron)
      'cron': {
        'enabled': cronEnabled,
        'cron': cronExpression.trim(),
        'timezone': timezone.trim().isEmpty ? 'Asia/Shanghai' : timezone.trim(),
        'events': events.toList(growable: false),
        'channels': channels.toList(growable: false),
      },
  };
}

class AppSelectOptionCard extends StatelessWidget {
  const AppSelectOptionCard({
    super.key,
    required this.selected,
    required this.icon,
    required this.tint,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  final bool selected;
  final IconData icon;
  final Color tint;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = selected
        ? colors.primary
        : IsleGlass.rimBorderColor(isDark);
    final fillColor = selected
        ? colors.primary.withValues(alpha: isDark ? 0.16 : 0.08)
        : (isDark ? Colors.white.withValues(alpha: 0.04) : colors.surface);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: IsleRadius.brMd,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: fillColor,
            borderRadius: IsleRadius.brMd,
            border: Border.all(
              color: borderColor,
              width: selected ? 1.5 : 1.0,
            ),
          ),
          child: Row(
            children: [
              IsleSquircleBadge(
                icon: icon,
                color: selected ? colors.primary : tint,
                size: 36,
                iconSize: 18,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: selected ? colors.primary : colors.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 20,
                color: selected
                    ? colors.primary
                    : colors.onSurfaceVariant.withValues(alpha: 0.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AppTerminalLogBox extends StatelessWidget {
  const AppTerminalLogBox({super.key, required this.text, this.minHeight = 96});

  final String text;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(minHeight: minHeight, maxHeight: 260),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.black.withValues(alpha: 0.28)
            : colors.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : colors.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          text,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            height: 1.48,
            color: colors.onSurface,
          ),
        ),
      ),
    );
  }
}

class AppDiagnosticBanner extends StatelessWidget {
  const AppDiagnosticBanner({super.key, required this.diag});

  final Map<String, dynamic> diag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    final summary = diag['summary']?.toString().trim() ?? '插件启动或配置异常';
    final reason = diag['reason']?.toString().trim() ?? '';
    final logExcerpt = diag['logExcerpt']?.toString().trim() ?? '';
    final dataSafe = diag['dataSafe']?.toString().trim() ?? '';
    final checks = (diag['checks'] is List)
        ? (diag['checks'] as List)
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList()
        : const <String>[];
    final solutions = (diag['solutions'] is List)
        ? (diag['solutions'] as List)
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList()
        : const <String>[];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.errorContainer.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.error.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 17, color: colors.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  summary,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colors.error,
                  ),
                ),
              ),
            ],
          ),
          if (reason.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(
              '原因：$reason',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurface,
                height: 1.4,
              ),
            ),
          ],
          if (logExcerpt.isNotEmpty) ...[
            const SizedBox(height: 6),
            AppTerminalLogBox(text: logExcerpt, minHeight: 44),
          ],
          if (checks.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '排查：${checks.first}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
          if (solutions.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '解决：${solutions.first}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurface,
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
          ],
          if (dataSafe.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              dataSafe,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
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
  final maxSheetHeight = (MediaQuery.sizeOf(context).height * 0.85).clamp(
    260.0,
    680.0,
  );
  return Padding(
    padding: EdgeInsets.fromLTRB(
      20,
      4,
      20,
      MediaQuery.viewInsetsOf(context).bottom + 20,
    ),
    child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxSheetHeight),
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
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: children,
              ),
            ),
          ),
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
          for (final (val, label, sub, icon, tint) in kAppAccessPolicies) ...[
            AppSelectOptionCard(
              key: ValueKey('accessPolicy_$val'),
              selected: draft.accessPolicy == val,
              icon: icon,
              tint: tint,
              title: label,
              subtitle: sub,
              onTap: _busy
                  ? null
                  : () => setState(() => draft.accessPolicy = val),
            ),
            const SizedBox(height: 8),
          ],
          if (draft.accessPolicy == 'selected_members') ...[
            const SizedBox(height: 6),
            Text('勾选允许访问的家庭成员', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            if (widget.members.isEmpty)
              const Text('当前没有可选的家庭成员账号。')
            else
              IsleGroupCard(
                children: [
                  for (final m in widget.members) _buildMemberCheckbox(m, draft),
                ],
              ),
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
          const SizedBox(height: 8),
          for (final (mode, title, desc, icon, tint) in kAppWebModes) ...[
            AppSelectOptionCard(
              key: ValueKey('webMode_$mode'),
              selected: draft.webMode == mode,
              icon: icon,
              tint: tint,
              title: title,
              subtitle: desc,
              onTap: _busy ? null : () => setState(() => draft.webMode = mode),
            ),
            const SizedBox(height: 8),
          ],
          if (draft.webMode == 'on-demand') ...[
            const SizedBox(height: 4),
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
            const SizedBox(height: 6),
          ],
          IsleGroupCard(
            children: [
              IsleGroupTile(
                icon: Icons.restart_alt_rounded,
                title: '异常退出自动重启',
                trailing: Switch.adaptive(
                  value: draft.autoRestart,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => draft.autoRestart = v),
                ),
              ),
            ],
          ),
        ],
        if (draft.hasCron) ...[
          const SizedBox(height: 8),
          IsleGroupCard(
            children: [
              IsleGroupTile(
                icon: Icons.schedule_rounded,
                title: '启用后台定时任务',
                subtitle: '仅修改调度与通知渠道，保留原脚本与邮件模板',
                trailing: Switch.adaptive(
                  key: const ValueKey('cronEnableSwitch'),
                  value: draft.cronEnabled,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => draft.cronEnabled = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final cronField = TextField(
                key: const ValueKey('cronExpressionField'),
                controller: _cronController,
                decoration: const InputDecoration(
                  labelText: '五段 Cron',
                  hintText: '*/15 * * * *',
                  isDense: true,
                ),
              );
              final tzField = TextField(
                key: const ValueKey('cronTimezoneField'),
                controller: _tzController,
                decoration: const InputDecoration(
                  labelText: '时区',
                  hintText: 'Asia/Shanghai',
                  isDense: true,
                ),
              );
              if (constraints.maxWidth < 380) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [cronField, const SizedBox(height: 8), tzField],
                );
              }
              return Row(
                children: [
                  Expanded(child: cronField),
                  const SizedBox(width: 10),
                  Expanded(child: tzField),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
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
    return IsleGroupTile(
      icon: isAdminRole ? Icons.verified_user_rounded : Icons.person_rounded,
      title: member['username']?.toString() ?? '成员 #$id',
      subtitle: isAdminRole ? '家庭管理员（始终可访问）' : '家庭成员',
      trailing: Switch.adaptive(
        key: ValueKey('memberAccess_$id'),
        value: isAdminRole || draft.allowedUserIDs.contains(id),
        onChanged: _busy || isAdminRole
            ? null
            : (sel) => setState(
                () => sel
                    ? draft.allowedUserIDs.add(id)
                    : draft.allowedUserIDs.remove(id),
              ),
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
    final maxLogsHeight = (MediaQuery.sizeOf(context).height * 0.82).clamp(
      240.0,
      540.0,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxLogsHeight),
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
              AppTerminalLogBox(
                text: _webOutput.trim().isNotEmpty ? _webOutput : '（暂无 Web 进程输出）',
              ),
              const SizedBox(height: 14),
              Text(
                '定时任务记录（${_cronRuns.length}）',
                style: theme.textTheme.labelLarge,
              ),
              const SizedBox(height: 8),
              if (_cronRuns.isEmpty)
                Text(
                  '暂无定时执行记录。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              else
                IsleGroupCard(
                  margin: EdgeInsets.zero,
                  children: [
                    for (final run in _cronRuns)
                      ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 1,
                        ),
                        onTap: () => showAppCronRunDialog(context, run),
                        leading: IsleStatusBadge(
                          label: run['state']?.toString() == 'success'
                              ? '执行成功'
                              : (run['state']?.toString() ?? 'unknown'),
                          color: run['state']?.toString() == 'success'
                              ? const Color(0xFF10B981)
                              : const Color(0xFFD97706),
                        ),
                        title: Text(
                          run['exitCode'] is int
                              ? '退出码 ${run['exitCode']}'
                              : '查看标准输出',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        trailing: const Icon(
                          Icons.help_outline_rounded,
                          size: 17,
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showAppCronRunDialog(
  BuildContext context,
  Map<String, dynamic> run,
) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final stateLabel = run['state']?.toString() == 'success'
      ? '执行成功'
      : (run['state']?.toString() ?? '执行记录');
  final exitLabel = run['exitCode'] is int ? ' · 退出码 ${run['exitCode']}' : '';
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      shape: IsleShapes.card(
        side: BorderSide(color: IsleGlass.rimBorderColor(isDark)),
      ),
      title: Text('$stateLabel$exitLabel'),
      content: SizedBox(
        width: 460,
        child: AppTerminalLogBox(
          minHeight: 72,
          text: (run['output']?.toString().trim().isNotEmpty == true)
              ? run['output'].toString()
              : '（无标准输出）',
        ),
      ),
      actions: [
        FilledButton.tonal(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
