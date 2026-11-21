import 'package:flutter/material.dart';

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
