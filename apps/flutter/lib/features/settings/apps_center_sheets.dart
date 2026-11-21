import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'app_config_models.dart';

export 'app_config_models.dart';

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
                  onSelected:
                      !_busy &&
                          (widget.configuredChannels.contains(chId) ||
                              draft.channels.contains(chId))
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
