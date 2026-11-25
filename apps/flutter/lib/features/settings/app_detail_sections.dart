import 'package:flutter/material.dart';

import '../../core/isle_action_menu.dart';
import '../../core/isle_theme.dart';
import '../../core/widgets.dart';
import 'apps_center_helpers.dart';
import 'apps_center_sheets.dart';

const _appDetailCronPresets = [
  ('*/15 * * * *', '每 15 分钟'),
  ('0 * * * *', '每小时'),
  ('0 3 * * *', '每天 03:00'),
];

class AppDetailHeroCard extends StatelessWidget {
  const AppDetailHeroCard({
    super.key,
    required this.app,
    required this.appId,
    required this.draft,
    required this.busy,
    required this.waking,
    required this.onPerformAction,
    required this.onLaunch,
  });

  final Map<String, dynamic> app;
  final String appId;
  final AppConfigDraft draft;
  final bool busy;
  final bool waking;
  final ValueChanged<String> onPerformAction;
  final VoidCallback onLaunch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final category = app['category']?.toString();
    final catColor = appCategoryColor(category, colors);
    final description = app['description']?.toString().trim() ?? '';
    final version = app['version']?.toString().trim() ?? '';
    final webMap = app['web'] is Map ? app['web'] as Map : const {};
    final lastError =
        (app['lastError'] ?? app['validationError'] ?? webMap['lastError'])
            ?.toString()
            .trim() ??
        '';
    final diag = app['diagnostic'] is Map
        ? Map<String, dynamic>.from(app['diagnostic'] as Map)
        : null;
    final (runtimeLabel, runtimeColor) = appRuntimeBadge(app, draft.webMode);
    final isRunning =
        (app['status']?.toString() ?? webMap['status']?.toString()) ==
        'running';

    return IsleSurface(
      radius: IsleRadius.hero,
      tint: catColor,
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IsleSquircleBadge(
                icon: appCategoryIcon(category),
                color: catColor,
                size: 42,
                iconSize: 21,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          draft.name,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.3,
                          ),
                        ),
                        IsleStatusBadge(
                          label: appCategoryLabel(category),
                          color: catColor,
                        ),
                        Text(
                          version.isNotEmpty ? '$appId · v$version' : appId,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 11.5,
                            color: colors.onSurfaceVariant,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                    if (description.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 12.5,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 7,
            runSpacing: 5,
            children: [
              IsleStatusBadge(label: runtimeLabel, color: runtimeColor),
              IsleStatusBadge(
                label: app['locationKind'] == 'external'
                    ? '其他盘 · ${app['locationName'] ?? '外置盘'}'
                    : '内置盘 · ${app['locationName'] ?? 'Mac 内置盘'}',
                color: app['locationKind'] == 'external'
                    ? palette['brandSage']
                    : colors.primary,
              ),
              if (app['pendingActivation'] == true)
                IsleStatusBadge(
                  label: '待首次激活',
                  color: palette['brandAmber'],
                ),
              if (draft.hasCron)
                IsleStatusBadge(
                  label: draft.cronEnabled
                      ? '定时 ${draft.cronExpression.isEmpty ? "已开启" : draft.cronExpression}'
                      : '定时已暂停',
                  color: palette['brandBlue'],
                ),
            ],
          ),
          if (diag != null) ...[
            const SizedBox(height: 10),
            AppDiagnosticBanner(diag: diag),
          ] else if (lastError.isNotEmpty) ...[
            const SizedBox(height: 8),
            Notice(lastError, error: true),
          ],
          const Divider(height: 22),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (app['pendingActivation'] == true)
                FilledButton.icon(
                  onPressed: busy ? null : () => onPerformAction('activate'),
                  icon: const Icon(Icons.verified_outlined, size: 16),
                  label: const Text('确认激活'),
                ),
              if (draft.hasWeb && draft.webEnabled)
                FilledButton.tonalIcon(
                  key: const ValueKey('detailLaunchAppButton'),
                  onPressed: waking ? null : onLaunch,
                  icon: Icon(
                    waking
                        ? Icons.hourglass_top_rounded
                        : Icons.open_in_new_rounded,
                    size: 16,
                  ),
                  label: Text(waking ? '正在唤醒…' : '立即打开'),
                ),
              if (draft.hasWeb && draft.webMode != 'static' && !isRunning)
                OutlinedButton.icon(
                  onPressed: busy ? null : () => onPerformAction('start'),
                  icon: const Icon(Icons.play_arrow_rounded, size: 16),
                  label: const Text('启动'),
                ),
              if (draft.hasCron)
                OutlinedButton.icon(
                  onPressed: busy ? null : () => onPerformAction('run_cron'),
                  icon: const Icon(Icons.bolt_rounded, size: 16),
                  label: const Text('立即采集'),
                ),
              if (draft.hasWeb && draft.webMode != 'static' && isRunning)
                PopupMenuButton<String>(
                  tooltip: '进程控制',
                  enabled: !busy,
                  icon: const Icon(Icons.more_horiz_rounded, size: 19),
                  style: IconButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  shape: IsleShapes.md(
                    side: BorderSide(
                      color: IsleGlass.rimBorderColor(isDark),
                      width: 1.0,
                    ),
                  ),
                  onSelected: onPerformAction,
                  itemBuilder: (_) => [
                    isleActionMenuItem(
                      value: 'restart',
                      icon: Icons.restart_alt_rounded,
                      label: '重启进程',
                    ),
                    isleActionMenuItem(
                      value: 'stop',
                      icon: Icons.stop_circle_outlined,
                      label: '停止进程',
                      destructive: true,
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class AppDetailAccessSection extends StatelessWidget {
  const AppDetailAccessSection({
    super.key,
    required this.draft,
    required this.members,
    required this.busy,
    required this.onPolicyChanged,
    required this.onToggleMember,
  });

  final AppConfigDraft draft;
  final List<Map<String, dynamic>> members;
  final bool busy;
  final ValueChanged<String> onPolicyChanged;
  final void Function(int userId, bool allowed) onToggleMember;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IsleSurface(
          margin: EdgeInsets.zero,
          radius: IsleRadius.card,
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < kAppAccessPolicies.length; i++) ...[
                if (i > 0) const SizedBox(height: 6),
                AppSelectOptionCard(
                  key: ValueKey('accessPolicy_${kAppAccessPolicies[i].$1}'),
                  selected: draft.accessPolicy == kAppAccessPolicies[i].$1,
                  icon: kAppAccessPolicies[i].$4,
                  tint: kAppAccessPolicies[i].$5,
                  title: kAppAccessPolicies[i].$2,
                  subtitle: kAppAccessPolicies[i].$3,
                  onTap: busy
                      ? null
                      : () => onPolicyChanged(kAppAccessPolicies[i].$1),
                ),
              ],
            ],
          ),
        ),
        if (draft.accessPolicy == 'selected_members') ...[
          const SizedBox(height: 8),
          if (members.isEmpty)
            IsleSurface(
              margin: EdgeInsets.zero,
              radius: IsleRadius.card,
              padding: const EdgeInsets.all(14),
              child: Text(
                '当前没有可选的家庭成员账号。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            )
          else
            IsleGroupCard(
              children: [for (final m in members) _buildMemberSwitchRow(m)],
            ),
        ],
      ],
    );
  }

  Widget _buildMemberSwitchRow(Map<String, dynamic> member) {
    final rawId = member['id'];
    final id = rawId is num ? rawId.toInt() : int.tryParse('$rawId') ?? 0;
    if (id <= 0) return const SizedBox.shrink();
    final isAdminRole = member['role'] == 'admin';
    final selected = isAdminRole || draft.allowedUserIDs.contains(id);
    return IsleGroupTile(
      icon: isAdminRole ? Icons.verified_user_rounded : Icons.person_rounded,
      title: member['username']?.toString() ?? '成员 #$id',
      subtitle: isAdminRole ? '管理员默认可访问' : null,
      onTap: busy || isAdminRole ? null : () => onToggleMember(id, !selected),
      trailing: Switch.adaptive(
        key: ValueKey('memberAccess_$id'),
        value: selected,
        onChanged: busy || isAdminRole
            ? null
            : (next) => onToggleMember(id, next),
      ),
    );
  }
}

class AppDetailWebSection extends StatelessWidget {
  const AppDetailWebSection({
    super.key,
    required this.draft,
    required this.busy,
    required this.onWebEnabledChanged,
    required this.onAutoRestartChanged,
    required this.onWebModeChanged,
    required this.onIdleTimeoutChanged,
  });

  final AppConfigDraft draft;
  final bool busy;
  final ValueChanged<bool> onWebEnabledChanged;
  final ValueChanged<bool> onAutoRestartChanged;
  final ValueChanged<String> onWebModeChanged;
  final ValueChanged<int> onIdleTimeoutChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IsleGroupCard(
          children: [
            IsleGroupTile(
              icon: Icons.public_rounded,
              title: '启用 Web 界面入口',
              onTap: busy ? null : () => onWebEnabledChanged(!draft.webEnabled),
              trailing: Switch.adaptive(
                key: const ValueKey('webEnabledSwitch'),
                value: draft.webEnabled,
                onChanged: busy ? null : onWebEnabledChanged,
              ),
            ),
            if (draft.webMode != 'static')
              IsleGroupTile(
                icon: Icons.restart_alt_rounded,
                title: '异常退出自动重启',
                onTap: busy
                    ? null
                    : () => onAutoRestartChanged(!draft.autoRestart),
                trailing: Switch.adaptive(
                  value: draft.autoRestart,
                  onChanged: busy ? null : onAutoRestartChanged,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        IsleSurface(
          margin: EdgeInsets.zero,
          radius: IsleRadius.card,
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '运行模式',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < kAppWebModes.length; i++) ...[
                if (i > 0) const SizedBox(height: 6),
                AppSelectOptionCard(
                  key: ValueKey('webMode_${kAppWebModes[i].$1}'),
                  selected: draft.webMode == kAppWebModes[i].$1,
                  icon: kAppWebModes[i].$4,
                  tint: kAppWebModes[i].$5,
                  title: kAppWebModes[i].$2,
                  subtitle: kAppWebModes[i].$3,
                  onTap: busy
                      ? null
                      : () => onWebModeChanged(kAppWebModes[i].$1),
                ),
              ],
              if (draft.webMode == 'on-demand') ...[
                const SizedBox(height: 12),
                Text(
                  '闲置自动休眠时长',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final (secs, label) in kIdleTimeoutOptions)
                      ChoiceChip(
                        key: ValueKey('idleTimeout_$secs'),
                        visualDensity: VisualDensity.compact,
                        label: Text(label),
                        selected: draft.idleTimeoutSeconds == secs,
                        onSelected: busy
                            ? null
                            : (_) => onIdleTimeoutChanged(secs),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class AppDetailCronSection extends StatelessWidget {
  const AppDetailCronSection({
    super.key,
    required this.draft,
    required this.cronController,
    required this.tzController,
    required this.configuredChannels,
    required this.busy,
    required this.onCronEnabledChanged,
    required this.onToggleEvent,
    required this.onToggleChannel,
  });

  final AppConfigDraft draft;
  final TextEditingController cronController;
  final TextEditingController tzController;
  final Set<String> configuredChannels;
  final bool busy;
  final ValueChanged<bool> onCronEnabledChanged;
  final void Function(String eventId, bool selected) onToggleEvent;
  final void Function(String channelId, bool selected) onToggleChannel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IsleGroupCard(
          children: [
            IsleGroupTile(
              icon: Icons.schedule_rounded,
              title: '启用后台定时任务',
              onTap: busy
                  ? null
                  : () => onCronEnabledChanged(!draft.cronEnabled),
              trailing: Switch.adaptive(
                key: const ValueKey('cronEnableSwitch'),
                value: draft.cronEnabled,
                onChanged: busy ? null : onCronEnabledChanged,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        IsleSurface(
          margin: EdgeInsets.zero,
          radius: IsleRadius.card,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final (expr, label) in _appDetailCronPresets)
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      label: Text('$label ($expr)'),
                      onPressed: busy ? null : () => cronController.text = expr,
                    ),
                ],
              ),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final cronField = TextField(
                    key: const ValueKey('cronExpressionField'),
                    controller: cronController,
                    style: const TextStyle(fontFamily: 'monospace'),
                    decoration: const InputDecoration(
                      labelText: '五段 Cron 表达式',
                      hintText: '*/15 * * * *',
                    ),
                  );
                  final tzField = TextField(
                    key: const ValueKey('cronTimezoneField'),
                    controller: tzController,
                    decoration: const InputDecoration(
                      labelText: '时区',
                      hintText: 'Asia/Shanghai',
                    ),
                  );
                  if (constraints.maxWidth < 420) {
                    return Column(
                      children: [
                        cronField,
                        const SizedBox(height: 10),
                        tzField,
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(flex: 3, child: cronField),
                      const SizedBox(width: 10),
                      Expanded(flex: 2, child: tzField),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              Text(
                '通知事件',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final (evId, evLabel) in kAppEventOptions)
                    FilterChip(
                      visualDensity: VisualDensity.compact,
                      label: Text(evLabel),
                      selected: draft.events.contains(evId),
                      onSelected: busy
                          ? null
                          : (sel) => onToggleEvent(evId, sel),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '通知渠道',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final (chId, chLabel) in kAppChannelOptions)
                    FilterChip(
                      visualDensity: VisualDensity.compact,
                      label: Text(
                        configuredChannels.contains(chId)
                            ? chLabel
                            : '$chLabel（未配置）',
                      ),
                      selected: draft.channels.contains(chId),
                      onSelected:
                          !busy &&
                              (configuredChannels.contains(chId) ||
                                  draft.channels.contains(chId))
                          ? (sel) => onToggleChannel(chId, sel)
                          : null,
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class AppDetailLogsSection extends StatelessWidget {
  const AppDetailLogsSection({
    super.key,
    required this.webOutput,
    required this.cronRuns,
  });

  final String webOutput;
  final List<Map<String, dynamic>> cronRuns;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = IslePalette.of(context);
    final sage = palette['brandSage'];
    final amber = palette['brandAmber'];
    return IsleSurface(
      margin: EdgeInsets.zero,
      radius: IsleRadius.card,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppTerminalLogBox(
            text: webOutput.trim().isNotEmpty
                ? webOutput
                : '（暂无 Web 进程输出，或当前处于休眠/静态状态）',
          ),
          if (cronRuns.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '最近定时执行（${cronRuns.length} 条）',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            IsleGroupCard(
              margin: EdgeInsets.zero,
              children: [
                for (final run in cronRuns)
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
                          ? sage
                          : amber,
                    ),
                    title: Text(
                      run['exitCode'] is int
                          ? '退出码 ${run['exitCode']}'
                          : '查看标准输出',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    trailing: const Icon(Icons.help_outline_rounded, size: 17),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class AppDetailManagementSection extends StatelessWidget {
  const AppDetailManagementSection({
    super.key,
    required this.busy,
    required this.onDelete,
    this.onExportData,
    this.onExportPackage,
  });

  final bool busy;
  final VoidCallback onDelete;
  final VoidCallback? onExportData;
  final VoidCallback? onExportPackage;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IsleGroupCard(
      children: [
        if (onExportPackage != null)
          IsleGroupTile(
            key: const ValueKey('detailExportPackageTile'),
            icon: Icons.inventory_2_outlined,
            title: '导出分享包 (.liapp.zip)',
            onTap: busy ? null : onExportPackage,
          ),
        if (onExportData != null)
          IsleGroupTile(
            key: const ValueKey('detailExportDataTile'),
            icon: Icons.download_rounded,
            title: '导出应用数据 (.tar.gz)',
            onTap: busy ? null : onExportData,
          ),
        IsleGroupTile(
          key: const ValueKey('detailDeleteAppTile'),
          icon: Icons.delete_outline_rounded,
          iconColor: colors.error,
          title: '删除轻应用插件',
          onTap: busy ? null : onDelete,
        ),
      ],
    );
  }
}

class AppDetailSaveBar extends StatelessWidget {
  const AppDetailSaveBar({
    super.key,
    required this.busy,
    required this.onRevert,
    required this.onSave,
  });

  final bool busy;
  final VoidCallback onRevert;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
        child: IsleSurface(
          radius: IsleRadius.card,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.edit_note_rounded, color: colors.primary, size: 19),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '有尚未保存的设置修改',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: busy ? null : onRevert,
                child: const Text('还原'),
              ),
              const SizedBox(width: 6),
              FilledButton(
                key: const ValueKey('saveAppDetailButton'),
                onPressed: busy ? null : onSave,
                child: Text(busy ? '保存中…' : '保存设置'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
