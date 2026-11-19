import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/isle_action_menu.dart';
import '../../core/isle_gallery_layout.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'apps_center_helpers.dart';
import 'apps_center_sheets.dart';

class AppDetailPage extends StatefulWidget {
  const AppDetailPage({
    super.key,
    required this.api,
    required this.initialApp,
    this.members = const [],
    this.configuredChannels = const {},
    this.onLaunch,
    this.onExportData,
    this.onSnapshotUpdated,
    this.onDeleted,
  });

  final LightIsleApi api;
  final Map<String, dynamic> initialApp;
  final List<Map<String, dynamic>> members;
  final Set<String> configuredChannels;
  final Future<void> Function(Map<String, dynamic> app)? onLaunch;
  final Future<void> Function(Map<String, dynamic> app)? onExportData;
  final ValueChanged<Map<String, dynamic>>? onSnapshotUpdated;
  final ValueChanged<String>? onDeleted;

  @override
  State<AppDetailPage> createState() => _AppDetailPageState();
}

class _AppDetailPageState extends State<AppDetailPage> {
  static const _cronPresets = [
    ('*/15 * * * *', '每 15 分钟'),
    ('0 * * * *', '每小时'),
    ('0 3 * * *', '每天 03:00'),
  ];

  late Map<String, dynamic> _app;
  late AppConfigDraft _baseline;
  late AppConfigDraft _draft;
  late final TextEditingController _cronController;
  late final TextEditingController _tzController;

  bool _busy = false;
  bool _logsLoading = false;
  bool _waking = false;
  String? _error;
  String? _notice;
  String _webOutput = '';
  List<Map<String, dynamic>> _cronRuns = const [];

  String get _appId => _app['id']?.toString() ?? '';

  @override
  void initState() {
    super.initState();
    _app = Map<String, dynamic>.from(widget.initialApp);
    _baseline = AppConfigDraft.fromApp(_app);
    _draft = AppConfigDraft.fromApp(_app);
    _cronController = TextEditingController(text: _draft.cronExpression)
      ..addListener(
        () => setState(() => _draft.cronExpression = _cronController.text),
      );
    _tzController = TextEditingController(text: _draft.timezone)
      ..addListener(
        () => setState(() => _draft.timezone = _tzController.text),
      );
    unawaited(_loadLogs());
  }

  @override
  void dispose() {
    _cronController.dispose();
    _tzController.dispose();
    super.dispose();
  }

  void _syncApp(Map<String, dynamic> nextApp, {bool resetDraft = true}) {
    setState(() {
      _app = Map<String, dynamic>.from(nextApp);
      if (resetDraft) {
        _baseline = AppConfigDraft.fromApp(_app);
        _draft = AppConfigDraft.fromApp(_app);
        if (_cronController.text != _draft.cronExpression) {
          _cronController.text = _draft.cronExpression;
        }
        if (_tzController.text != _draft.timezone) {
          _tzController.text = _draft.timezone;
        }
      }
    });
  }

  void _applySnapshotResponse(Map<String, dynamic> res) {
    widget.onSnapshotUpdated?.call(res);
    final appsList = objectList(res['apps']);
    for (final item in appsList) {
      if (item['id']?.toString() == _appId) {
        _syncApp(item);
        return;
      }
    }
    if (res['app'] is Map) {
      _syncApp(Map<String, dynamic>.from(res['app'] as Map));
    }
  }

  bool get _accessDirty {
    if (_draft.accessPolicy != _baseline.accessPolicy) return true;
    if (_draft.accessPolicy == 'selected_members' &&
        !setEquals(_draft.allowedUserIDs, _baseline.allowedUserIDs)) {
      return true;
    }
    return false;
  }

  bool get _runtimeDirty {
    if (_draft.hasWeb &&
        (_draft.webEnabled != _baseline.webEnabled ||
            _draft.webMode != _baseline.webMode ||
            _draft.idleTimeoutSeconds != _baseline.idleTimeoutSeconds ||
            _draft.autoRestart != _baseline.autoRestart)) {
      return true;
    }
    if (_draft.hasCron &&
        (_draft.cronEnabled != _baseline.cronEnabled ||
            _draft.cronExpression.trim() != _baseline.cronExpression.trim() ||
            _draft.timezone.trim() != _baseline.timezone.trim() ||
            !setEquals(_draft.events, _baseline.events) ||
            !setEquals(_draft.channels, _baseline.channels))) {
      return true;
    }
    return false;
  }

  bool get _isDirty => _accessDirty || _runtimeDirty;

  Future<void> _reloadAll() async {
    if (_appId.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await widget.api.get('/api/v2/apps');
      if (mounted) _applySnapshotResponse(res);
    } catch (e) {
      if (mounted) setState(() => _error = '刷新失败：${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _loadLogs();
  }

  Future<void> _loadLogs() async {
    if (_logsLoading || _appId.isEmpty) return;
    setState(() => _logsLoading = true);
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
      if (mounted) setState(() => _logsLoading = false);
    }
  }

  Future<void> _saveChanges() async {
    if (_busy || !_isDirty) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final res = await widget.api.send(
        'PUT',
        '/api/v2/apps/${Uri.encodeComponent(_appId)}',
        body: _draft.toSelectivePutBody(
          includeAccess: _accessDirty,
          includeRuntime: _runtimeDirty,
        ),
      );
      if (!mounted) return;
      _applySnapshotResponse(res);
      setState(() => _notice = '已保存“${_draft.name}”的配置修改。');
    } catch (e) {
      if (mounted) setState(() => _error = '保存设置失败：${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _performAction(String action) async {
    if (_busy || _appId.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final res = await widget.api.send(
        'POST',
        '/api/v2/apps/${Uri.encodeComponent(_appId)}/action',
        body: {'action': action},
      );
      if (!mounted) return;
      final snap = res['apps'] is List
          ? res
          : await widget.api.get('/api/v2/apps');
      if (!mounted) return;
      _applySnapshotResponse(snap);
      setState(() {
        _notice = switch (action) {
          'activate' => '已激活轻应用“${_draft.name}”。',
          'start' => '已启动 Web 进程。',
          'stop' => '已停止进程并释放内存。',
          'restart' => '已重启 Web 进程。',
          'run_cron' => '已触发定时任务执行。',
          _ => '操作已完成。',
        };
      });
      unawaited(_loadLogs());
    } catch (e) {
      if (mounted) setState(() => _error = '操作失败：${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleLaunch() async {
    if (_waking) return;
    if (widget.onLaunch != null) {
      await widget.onLaunch!(_app);
      return;
    }
    setState(() {
      _waking = true;
      _error = null;
    });
    try {
      await launchLightIsleApp(api: widget.api, appId: _appId);
      await _reloadAll();
    } catch (e) {
      if (mounted) setState(() => _error = '打开应用失败：${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => _waking = false);
    }
  }

  Future<void> _handleDelete() async {
    if (_busy || _appId.isEmpty) return;
    final confirmed = await confirmAction(
      context,
      '删除轻应用插件',
      '确定删除“${_draft.name}”？将移除 plugins/$_appId/ 代码目录；plugin-data/$_appId/ 业务数据目录会保留。',
      action: '删除插件',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await widget.api.send(
        'DELETE',
        '/api/v2/apps/${Uri.encodeComponent(_appId)}',
      );
      if (!mounted) return;
      widget.onSnapshotUpdated?.call(res);
      widget.onDeleted?.call(_appId);
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = '删除失败：${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final violet = palette['brandViolet'];

    final leftColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IsleSectionHeader(title: '成员访问权限', accentColor: violet),
        _buildAccessSection(theme, colors),
        if (_draft.hasWeb) ...[
          const SizedBox(height: 8),
          IsleSectionHeader(
            title: 'Web 服务与生命周期',
            accentColor: palette['brandBlue'],
            helpTitle: 'Web 运行模式说明',
            helpItems: const [
              IsleHelpItem(
                title: '纯静态 0 MB',
                body: '直接托管 ui/ 目录静态页面，不启动后台进程，零常驻内存。',
              ),
              IsleHelpItem(
                title: '按需休眠 0 MB',
                body: '访问时自动拉起子进程，超过闲置时长后自动休眠释放内存。',
              ),
              IsleHelpItem(
                title: '常驻守护',
                body: '全天候后台持续运行，异常退出时可自动拉起重启。',
              ),
            ],
          ),
          _buildWebSection(theme, colors),
        ],
      ],
    );

    final rightColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_draft.hasCron) ...[
          IsleSectionHeader(
            title: '定时任务 (Cron) 与通知',
            accentColor: palette['brandTerracotta'],
          ),
          _buildCronSection(theme, colors),
          const SizedBox(height: 8),
        ],
        IsleSectionHeader(
          title: '运行日志',
          accentColor: palette['brandSage'],
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: _logsLoading ? null : _loadLogs,
                icon: const Icon(Icons.refresh_rounded, size: 15),
                label: Text(_logsLoading ? '读取中…' : '刷新'),
              ),
              if (_webOutput.trim().isNotEmpty)
                IconButton(
                  tooltip: '复制日志',
                  visualDensity: VisualDensity.compact,
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: _webOutput));
                    if (mounted) setState(() => _notice = '已复制控制台日志。');
                  },
                  icon: const Icon(Icons.copy_rounded, size: 15),
                ),
            ],
          ),
        ),
        _buildLogsSection(theme, colors, palette),
        const SizedBox(height: 8),
        IsleSectionHeader(
          title: '数据与插件管理',
          accentColor: palette['brandAmber'],
        ),
        _buildManagementSection(colors),
      ],
    );

    return Scaffold(
      appBar: IsleAppBar(
        title: Text(_draft.name),
        actions: [
          IconButton(
            tooltip: '刷新状态与日志',
            onPressed: _busy ? null : _reloadAll,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IsleHelpButton(
            title: '轻应用目录与数据安全',
            accentColor: violet,
            items: const [
              IsleHelpItem(
                title: '代码与业务数据分离',
                body: '插件代码位于 plugins/<id>/，运行时业务数据独立存放在 plugin-data/<id>/；删除插件不会清除业务数据。',
              ),
              IsleHelpItem(
                title: '单次票据安全鉴权',
                body: '打开应用时通过短效一次性票据换取独立沙盒会话，不共享主站登录凭据。',
              ),
            ],
          ),
        ],
      ),
      bottomNavigationBar: _isDirty ? _buildSaveBar(theme, colors) : null,
      body: IsleListView(
        maxWidth: IsleLayout.workbenchMaxWidth,
        children: [
          if (_busy || _waking) const LinearProgressIndicator(),
          if (_error != null) Notice(_error!, error: true, onRetry: _reloadAll),
          if (_notice != null) Notice(_notice!),
          _buildHeroCard(theme, colors, palette),
          const SizedBox(height: 10),
          IsleWorkbenchSplit(
            breakpoint: 920,
            primaryFlex: 6,
            secondaryFlex: 6,
            primary: leftColumn,
            secondary: rightColumn,
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildHeroCard(
    ThemeData theme,
    ColorScheme colors,
    IslePalette palette,
  ) {
    final isDark = theme.brightness == Brightness.dark;
    final category = _app['category']?.toString();
    final catColor = appCategoryColor(category, colors);
    final description = _app['description']?.toString().trim() ?? '';
    final version = _app['version']?.toString().trim() ?? '';
    final webMap = _app['web'] is Map ? _app['web'] as Map : const {};
    final lastError =
        (_app['lastError'] ?? _app['validationError'] ?? webMap['lastError'])
            ?.toString()
            .trim() ??
        '';
    final diag = _app['diagnostic'] is Map
        ? Map<String, dynamic>.from(_app['diagnostic'] as Map)
        : null;
    final (runtimeLabel, runtimeColor) = appRuntimeBadge(_app, _draft.webMode);
    final isRunning =
        (_app['status']?.toString() ?? webMap['status']?.toString()) ==
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
                          _draft.name,
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
                          version.isNotEmpty ? '$_appId · v$version' : _appId,
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
                label: _app['locationKind'] == 'external'
                    ? '其他盘 · ${_app['locationName'] ?? '外置盘'}'
                    : '内置盘 · ${_app['locationName'] ?? 'Mac 内置盘'}',
                color: _app['locationKind'] == 'external'
                    ? palette['brandSage']
                    : colors.primary,
              ),
              if (_app['pendingActivation'] == true)
                IsleStatusBadge(
                  label: '待首次激活',
                  color: palette['brandAmber'],
                ),
              if (_draft.hasCron)
                IsleStatusBadge(
                  label: _draft.cronEnabled
                      ? '定时 ${_draft.cronExpression.isEmpty ? "已开启" : _draft.cronExpression}'
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
              if (_app['pendingActivation'] == true)
                FilledButton.icon(
                  onPressed: _busy ? null : () => _performAction('activate'),
                  icon: const Icon(Icons.verified_outlined, size: 16),
                  label: const Text('确认激活'),
                ),
              if (_draft.hasWeb && _draft.webEnabled)
                FilledButton.tonalIcon(
                  key: const ValueKey('detailLaunchAppButton'),
                  onPressed: _waking ? null : _handleLaunch,
                  icon: Icon(
                    _waking
                        ? Icons.hourglass_top_rounded
                        : Icons.open_in_new_rounded,
                    size: 16,
                  ),
                  label: Text(_waking ? '正在唤醒…' : '立即打开'),
                ),
              if (_draft.hasWeb && _draft.webMode != 'static' && !isRunning)
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _performAction('start'),
                  icon: const Icon(Icons.play_arrow_rounded, size: 16),
                  label: const Text('启动'),
                ),
              if (_draft.hasCron)
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _performAction('run_cron'),
                  icon: const Icon(Icons.bolt_rounded, size: 16),
                  label: const Text('立即采集'),
                ),
              if (_draft.hasWeb && _draft.webMode != 'static' && isRunning)
                PopupMenuButton<String>(
                  tooltip: '进程控制',
                  enabled: !_busy,
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
                  onSelected: _performAction,
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

  Widget _buildAccessSection(ThemeData theme, ColorScheme colors) {
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
                  selected: _draft.accessPolicy == kAppAccessPolicies[i].$1,
                  icon: kAppAccessPolicies[i].$4,
                  tint: kAppAccessPolicies[i].$5,
                  title: kAppAccessPolicies[i].$2,
                  subtitle: kAppAccessPolicies[i].$3,
                  onTap: _busy
                      ? null
                      : () => setState(
                          () => _draft.accessPolicy = kAppAccessPolicies[i].$1,
                        ),
                ),
              ],
            ],
          ),
        ),
        if (_draft.accessPolicy == 'selected_members') ...[
          const SizedBox(height: 8),
          if (widget.members.isEmpty)
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
              children: [
                for (final m in widget.members) _buildMemberSwitchRow(m),
              ],
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
    final selected = isAdminRole || _draft.allowedUserIDs.contains(id);
    void toggle(bool next) => setState(
      () => next
          ? _draft.allowedUserIDs.add(id)
          : _draft.allowedUserIDs.remove(id),
    );
    return IsleGroupTile(
      icon: isAdminRole ? Icons.verified_user_rounded : Icons.person_rounded,
      title: member['username']?.toString() ?? '成员 #$id',
      subtitle: isAdminRole ? '管理员默认可访问' : null,
      onTap: _busy || isAdminRole ? null : () => toggle(!selected),
      trailing: Switch.adaptive(
        key: ValueKey('memberAccess_$id'),
        value: selected,
        onChanged: _busy || isAdminRole ? null : toggle,
      ),
    );
  }

  Widget _buildWebSection(ThemeData theme, ColorScheme colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IsleGroupCard(
          children: [
            IsleGroupTile(
              icon: Icons.public_rounded,
              title: '启用 Web 界面入口',
              onTap: _busy
                  ? null
                  : () =>
                        setState(() => _draft.webEnabled = !_draft.webEnabled),
              trailing: Switch.adaptive(
                key: const ValueKey('webEnabledSwitch'),
                value: _draft.webEnabled,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _draft.webEnabled = v),
              ),
            ),
            if (_draft.webMode != 'static')
              IsleGroupTile(
                icon: Icons.restart_alt_rounded,
                title: '异常退出自动重启',
                onTap: _busy
                    ? null
                    : () => setState(
                        () => _draft.autoRestart = !_draft.autoRestart,
                      ),
                trailing: Switch.adaptive(
                  value: _draft.autoRestart,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _draft.autoRestart = v),
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
                  selected: _draft.webMode == kAppWebModes[i].$1,
                  icon: kAppWebModes[i].$4,
                  tint: kAppWebModes[i].$5,
                  title: kAppWebModes[i].$2,
                  subtitle: kAppWebModes[i].$3,
                  onTap: _busy
                      ? null
                      : () => setState(() => _draft.webMode = kAppWebModes[i].$1),
                ),
              ],
              if (_draft.webMode == 'on-demand') ...[
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
                        selected: _draft.idleTimeoutSeconds == secs,
                        onSelected: _busy
                            ? null
                            : (_) => setState(
                                () => _draft.idleTimeoutSeconds = secs,
                              ),
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

  Widget _buildCronSection(ThemeData theme, ColorScheme colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IsleGroupCard(
          children: [
            IsleGroupTile(
              icon: Icons.schedule_rounded,
              title: '启用后台定时任务',
              onTap: _busy
                  ? null
                  : () =>
                        setState(() => _draft.cronEnabled = !_draft.cronEnabled),
              trailing: Switch.adaptive(
                key: const ValueKey('cronEnableSwitch'),
                value: _draft.cronEnabled,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _draft.cronEnabled = v),
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
                  for (final (expr, label) in _cronPresets)
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      label: Text('$label ($expr)'),
                      onPressed: _busy
                          ? null
                          : () => _cronController.text = expr,
                    ),
                ],
              ),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final cronField = TextField(
                    key: const ValueKey('cronExpressionField'),
                    controller: _cronController,
                    style: const TextStyle(fontFamily: 'monospace'),
                    decoration: const InputDecoration(
                      labelText: '五段 Cron 表达式',
                      hintText: '*/15 * * * *',
                    ),
                  );
                  final tzField = TextField(
                    key: const ValueKey('cronTimezoneField'),
                    controller: _tzController,
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
                      selected: _draft.events.contains(evId),
                      onSelected: _busy
                          ? null
                          : (sel) => setState(
                              () => sel
                                  ? _draft.events.add(evId)
                                  : _draft.events.remove(evId),
                            ),
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
                        widget.configuredChannels.contains(chId)
                            ? chLabel
                            : '$chLabel（未配置）',
                      ),
                      selected: _draft.channels.contains(chId),
                      onSelected:
                          !_busy && widget.configuredChannels.contains(chId)
                          ? (sel) => setState(
                              () => sel
                                  ? _draft.channels.add(chId)
                                  : _draft.channels.remove(chId),
                            )
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

  Widget _buildLogsSection(
    ThemeData theme,
    ColorScheme colors,
    IslePalette palette,
  ) {
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
            text: _webOutput.trim().isNotEmpty
                ? _webOutput
                : '（暂无 Web 进程输出，或当前处于休眠/静态状态）',
          ),
          if (_cronRuns.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '最近定时执行（${_cronRuns.length} 条）',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
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
                    trailing: const Icon(
                      Icons.help_outline_rounded,
                      size: 17,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildManagementSection(ColorScheme colors) {
    return IsleGroupCard(
      children: [
        if (widget.onExportData != null)
          IsleGroupTile(
            key: const ValueKey('detailExportDataTile'),
            icon: Icons.download_rounded,
            title: '导出应用数据 (.tar.gz)',
            onTap: _busy ? null : () => widget.onExportData!(_app),
          ),
        IsleGroupTile(
          key: const ValueKey('detailDeleteAppTile'),
          icon: Icons.delete_outline_rounded,
          iconColor: colors.error,
          title: '删除轻应用插件',
          onTap: _busy ? null : _handleDelete,
        ),
      ],
    );
  }

  Widget _buildSaveBar(ThemeData theme, ColorScheme colors) {
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
                onPressed: _busy ? null : () => _syncApp(_app),
                child: const Text('还原'),
              ),
              const SizedBox(width: 6),
              FilledButton(
                key: const ValueKey('saveAppDetailButton'),
                onPressed: _busy ? null : _saveChanges,
                child: Text(_busy ? '保存中…' : '保存设置'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
