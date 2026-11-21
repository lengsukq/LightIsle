import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'app_config_models.dart';
import 'app_detail_sections.dart';
import 'apps_center_helpers.dart';

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
  late Map<String, dynamic> _app;
  late AppConfigDraft _baseline;
  late AppConfigDraft _draft;
  late final TextEditingController _cronController;
  late final TextEditingController _tzController;
  bool _syncingControllers = false;

  bool _busy = false;
  bool _logsLoading = false;
  bool _waking = false;
  String? _error;
  String? _notice;
  String _webOutput = '';
  List<Map<String, dynamic>> _cronRuns = const [];

  String get _appId => _app['id']?.toString() ?? '';

  void _onCronTextChanged() {
    if (_syncingControllers || !mounted) return;
    setState(() => _draft.cronExpression = _cronController.text);
  }

  void _onTzTextChanged() {
    if (_syncingControllers || !mounted) return;
    setState(() => _draft.timezone = _tzController.text);
  }

  @override
  void initState() {
    super.initState();
    _app = Map<String, dynamic>.from(widget.initialApp);
    _baseline = AppConfigDraft.fromApp(_app);
    _draft = AppConfigDraft.fromApp(_app);
    _cronController = TextEditingController(text: _draft.cronExpression)
      ..addListener(_onCronTextChanged);
    _tzController = TextEditingController(text: _draft.timezone)
      ..addListener(_onTzTextChanged);
    unawaited(_loadLogs());
  }

  @override
  void dispose() {
    _cronController.removeListener(_onCronTextChanged);
    _tzController.removeListener(_onTzTextChanged);
    _cronController.dispose();
    _tzController.dispose();
    super.dispose();
  }

  void _syncApp(Map<String, dynamic> nextApp, {bool resetDraft = true}) {
    if (!mounted) return;
    final nextBaseline = resetDraft ? AppConfigDraft.fromApp(nextApp) : null;
    final nextDraft = resetDraft ? AppConfigDraft.fromApp(nextApp) : null;
    if (resetDraft && nextDraft != null) {
      _syncingControllers = true;
      try {
        if (_cronController.text != nextDraft.cronExpression) {
          _cronController.text = nextDraft.cronExpression;
        }
        if (_tzController.text != nextDraft.timezone) {
          _tzController.text = nextDraft.timezone;
        }
      } finally {
        _syncingControllers = false;
      }
    }
    setState(() {
      _app = Map<String, dynamic>.from(nextApp);
      if (resetDraft && nextBaseline != null && nextDraft != null) {
        _baseline = nextBaseline;
        _draft = nextDraft;
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
    if (_waking || !mounted) return;
    if (widget.onLaunch != null) {
      await widget.onLaunch!(_app);
      return;
    }
    if (!mounted) return;
    setState(() {
      _waking = true;
      _error = null;
    });
    try {
      await launchLightIsleApp(api: widget.api, appId: _appId);
      if (!mounted) return;
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
    final palette = IslePalette.of(context);
    final violet = palette['brandViolet'];

    final leftColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IsleSectionHeader(title: '成员访问权限', accentColor: violet),
        AppDetailAccessSection(
          draft: _draft,
          members: widget.members,
          busy: _busy,
          onPolicyChanged: (policy) =>
              setState(() => _draft.accessPolicy = policy),
          onToggleMember: (userId, allowed) => setState(
            () => allowed
                ? _draft.allowedUserIDs.add(userId)
                : _draft.allowedUserIDs.remove(userId),
          ),
        ),
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
          AppDetailWebSection(
            draft: _draft,
            busy: _busy,
            onWebEnabledChanged: (v) => setState(() => _draft.webEnabled = v),
            onAutoRestartChanged: (v) => setState(() => _draft.autoRestart = v),
            onWebModeChanged: (v) => setState(() => _draft.webMode = v),
            onIdleTimeoutChanged: (secs) =>
                setState(() => _draft.idleTimeoutSeconds = secs),
          ),
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
          AppDetailCronSection(
            draft: _draft,
            cronController: _cronController,
            tzController: _tzController,
            configuredChannels: widget.configuredChannels,
            busy: _busy,
            onCronEnabledChanged: (v) => setState(() => _draft.cronEnabled = v),
            onToggleEvent: (eventId, selected) => setState(
              () => selected
                  ? _draft.events.add(eventId)
                  : _draft.events.remove(eventId),
            ),
            onToggleChannel: (channelId, selected) => setState(
              () => selected
                  ? _draft.channels.add(channelId)
                  : _draft.channels.remove(channelId),
            ),
          ),
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
        AppDetailLogsSection(webOutput: _webOutput, cronRuns: _cronRuns),
        const SizedBox(height: 8),
        IsleSectionHeader(
          title: '数据与插件管理',
          accentColor: palette['brandAmber'],
        ),
        AppDetailManagementSection(
          busy: _busy,
          onDelete: _handleDelete,
          onExportData: widget.onExportData != null
              ? () => unawaited(widget.onExportData!(_app))
              : null,
        ),
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
      bottomNavigationBar: _isDirty
          ? AppDetailSaveBar(
              busy: _busy,
              onRevert: () => _syncApp(_app),
              onSave: _saveChanges,
            )
          : null,
      body: IsleListView(
        maxWidth: IsleLayout.workbenchMaxWidth,
        children: [
          if (_busy || _waking) const LinearProgressIndicator(),
          if (_error != null) Notice(_error!, error: true, onRetry: _reloadAll),
          if (_notice != null) Notice(_notice!),
          AppDetailHeroCard(
            app: _app,
            appId: _appId,
            draft: _draft,
            busy: _busy,
            waking: _waking,
            onPerformAction: _performAction,
            onLaunch: _handleLaunch,
          ),
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
}
