import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/isle_action_menu.dart';
import '../../core/isle_gallery_layout.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'apps_center_sheets.dart' show AppTerminalLogBox;

const String _agentPrompt =
    '你是用户本地使用的外部 AI Agent，请在当前 Mac 上为 LightIsle 创建或修改自动化脚本。先确认 LightIsle 实际 data-dir，不要猜测路径。\n'
    '一个任务目录为 automation/scripts/<task-id>/，其中 task.json 需要：\n'
    '{"schemaVersion":1,"id":"daily-report","name":"日报","enabled":false,"entry":"run.sh","args":[],"envFile":"env.json","schedule":{"cron":"0 8 * * *","timezone":"Asia/Shanghai"},"timeoutSeconds":600,"notification":{"events":["failure","timeout"],"channels":["email"],"email":{"mode":"content","file":"email.html","subject":"轻屿自动化报告"}}}\n'
    '请按实际需求改写 ID、Cron、名称和脚本（首行正确 Shebang，脚本 chmod 700）。依赖和解释器用户自行准备，LightIsle 不安装依赖或提供代码编辑器。\n'
    '邮件支持 mode=builtin（品牌边框模板，不需要 file）、mode=content（自定义 HTML 片段替换内置边框中间内容）和 mode=custom（自定义完整 HTML 邮件，彻底替换内置模板）。content/custom 的 HTML 由 Agent 写到任务目录 email.html，task.json 用 notification.email.file 引用。\n'
    'HTML 安全占位符只有 {{task.name}}、{{task.id}}、{{run.state}}、{{run.message}}、{{run.finishedAt}}、{{run.exitCode}}。请不要输出密钥。env.json 可包含环境变量但应 chmod 600；通知 SMTP、企业微信、钉钉、Bark 和 Webhook 凭据只在 Mac 管理端 Keychain 配置，不可写入 task.json。\n'
    '脚本执行退出码 0 表示成功；其他表示失败。默认 enabled=false，最后告诉用户到自动化页面点击刷新并手动启用。请只改本地任务文件，不修改 LightIsle 源代码，也不调用 Agent 插件或任务注册 API。';

class AutomationPage extends StatefulWidget {
  const AutomationPage({super.key, required this.api});

  final LightIsleApi api;

  @override
  State<AutomationPage> createState() => _AutomationPageState();
}

class _AutomationPageState extends State<AutomationPage> {
  static const List<(String, String)> _channelOptions = [
    ('bark', 'Bark'),
    ('webhook', 'Webhook'),
    ('email', '邮件'),
    ('wecom', '企业微信'),
    ('dingtalk', '钉钉'),
  ];

  static const List<(String, String)> _eventOptions = [
    ('failure', '执行失败'),
    ('timeout', '执行超时'),
    ('success', '执行成功'),
  ];

  List<Map<String, dynamic>> _tasks = const [];
  Set<String> _configuredChannels = const {};
  bool _busy = false;
  bool _loaded = false;
  String? _error;
  String? _notice;

  String? _editingTaskId;
  String? _editingRevision;
  final TextEditingController _cronController = TextEditingController();
  final TextEditingController _timezoneController = TextEditingController();
  bool _editingEnabled = false;
  Set<String> _editingEvents = <String>{};
  Set<String> _editingChannels = <String>{};

  String? _selectedRunsTaskId;
  List<Map<String, dynamic>> _runs = const [];
  bool _runsBusy = false;

  @override
  void initState() {
    super.initState();
    _reload(refresh: true);
  }

  @override
  void dispose() {
    _cronController.dispose();
    _timezoneController.dispose();
    super.dispose();
  }

  Future<void> _reload({bool refresh = true}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final response = refresh
          ? await widget.api.send('POST', '/api/v2/automation/refresh')
          : await widget.api.get('/api/v2/automation/tasks');
      final channelsRes = await widget.api.get('/api/v2/automation/channels');
      if (!mounted) return;
      final channelList =
          (channelsRes['channels'] as List<dynamic>? ?? const [])
              .map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toSet();
      setState(() {
        _tasks = objectList(response['tasks']);
        _configuredChannels = channelList;
        _loaded = true;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = '读取脚本失败：${userFacingError(e)}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyAgentPrompt() async {
    await Clipboard.setData(const ClipboardData(text: _agentPrompt));
    if (!mounted) return;
    setState(() {
      _notice = '已复制任务目录、JSON 协议和 HTML 邮件模板指令，请粘贴给你本地使用的 AI Agent。';
    });
  }

  void _startEdit(Map<String, dynamic> task) {
    final schedule = task['schedule'] is Map
        ? Map<String, dynamic>.from(task['schedule'] as Map)
        : const <String, dynamic>{};
    final notification = task['notification'] is Map
        ? Map<String, dynamic>.from(task['notification'] as Map)
        : const <String, dynamic>{};
    final events =
        (notification['events'] as List<dynamic>? ??
                const ['failure', 'timeout'])
            .map((e) => e.toString())
            .toSet();
    final channels = (notification['channels'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toSet();
    setState(() {
      _editingTaskId = task['id']?.toString();
      _editingRevision = task['revision']?.toString();
      _cronController.text = schedule['cron']?.toString() ?? '';
      _timezoneController.text =
          schedule['timezone']?.toString() ?? 'Asia/Shanghai';
      _editingEnabled = task['enabled'] == true;
      _editingEvents = events;
      _editingChannels = channels;
    });
  }

  Future<void> _reloadEditingTask(String taskId) async {
    await _reload(refresh: true);
    if (!mounted) return;
    for (final task in _tasks) {
      if (task['id']?.toString() == taskId) {
        _startEdit(task);
        setState(() {
          _notice = '已加载本地最新任务配置，请确认后再次保存。';
        });
        return;
      }
    }
  }

  Future<void> _saveEdit() async {
    final id = _editingTaskId;
    if (id == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final response = await widget.api.send(
        'PUT',
        '/api/v2/automation/tasks/${Uri.encodeComponent(id)}',
        body: {
          'enabled': _editingEnabled,
          'revision': ?_editingRevision,
          'schedule': {
            'cron': _cronController.text.trim(),
            'timezone': _timezoneController.text.trim(),
          },
          'notification': {
            'events': _editingEvents.toList(growable: false),
            'channels': _editingChannels.toList(growable: false),
          },
        },
      );
      if (!mounted) return;
      setState(() {
        _tasks = objectList(response['tasks']);
        _editingTaskId = null;
        _editingRevision = null;
        _notice = '任务设置已保存；脚本代码、环境变量和邮件模板配置均保留原样。';
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = '保存失败：${userFacingError(e)}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleTask(Map<String, dynamic> task) async {
    if (_busy) return;
    final id = task['id']?.toString() ?? '';
    if (id.isEmpty) return;
    final schedule = task['schedule'] is Map
        ? Map<String, dynamic>.from(task['schedule'] as Map)
        : const <String, dynamic>{};
    final notification = task['notification'] is Map
        ? Map<String, dynamic>.from(task['notification'] as Map)
        : const <String, dynamic>{};
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final response = await widget.api.send(
        'PUT',
        '/api/v2/automation/tasks/${Uri.encodeComponent(id)}',
        body: {
          'enabled': task['enabled'] != true,
          if (task['revision'] case final String revision) 'revision': revision,
          'schedule': {
            'cron': schedule['cron']?.toString() ?? '',
            'timezone': schedule['timezone']?.toString() ?? '',
          },
          'notification': {
            'events': (notification['events'] as List<dynamic>? ?? const [])
                .map((e) => e.toString())
                .toList(growable: false),
            'channels': (notification['channels'] as List<dynamic>? ?? const [])
                .map((e) => e.toString())
                .toList(growable: false),
          },
        },
      );
      if (!mounted) return;
      setState(() {
        _tasks = objectList(response['tasks']);
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = userFacingError(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteTask(Map<String, dynamic> task) async {
    if (_busy) return;
    final id = task['id']?.toString() ?? '';
    final name = task['name']?.toString() ?? id;
    if (!await confirmAction(
      context,
      '删除自动化任务',
      '确定删除“$name”？将永久删除 Mac 上的 automation/scripts/$id/ 及其中的文件。',
      action: '删除脚本目录',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await widget.api.send(
        'DELETE',
        '/api/v2/automation/tasks/${Uri.encodeComponent(id)}',
      );
      if (!mounted) return;
      setState(() {
        _tasks = _tasks.where((t) => t['id']?.toString() != id).toList();
        if (_selectedRunsTaskId == id) {
          _selectedRunsTaskId = null;
          _runs = const [];
        }
        _notice = '脚本目录已删除。';
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = '删除失败：${userFacingError(e)}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadRuns(String id) async {
    setState(() {
      _selectedRunsTaskId = id;
      _runs = const [];
      _runsBusy = true;
      _error = null;
    });
    try {
      final response = await widget.api.get(
        '/api/v2/automation/tasks/${Uri.encodeComponent(id)}/runs',
      );
      if (!mounted || _selectedRunsTaskId != id) return;
      setState(() {
        _runs = objectList(response['runs']);
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = '无法读取日志：${userFacingError(e)}');
      }
    } finally {
      if (mounted) setState(() => _runsBusy = false);
    }
  }

  Future<void> _showRunOutputDialog(
    BuildContext context,
    Map<String, dynamic> run,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final deliveries = _deliveryLines(run['deliveries']).toList();
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: IsleShapes.card(
          side: BorderSide(color: IsleGlass.rimBorderColor(isDark)),
        ),
        title: Text(
          '${_runState(run['state'])} · ${_formatEpoch(run['startedAt'])}',
        ),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (run['exitCode'] is int && run['exitCode'] >= 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('退出码：${run['exitCode']}'),
                  ),
                if (deliveries.isNotEmpty) ...[
                  ...deliveries,
                  const SizedBox(height: 8),
                ],
                AppTerminalLogBox(
                  minHeight: 72,
                  text: (run['output']?.toString().trim().isNotEmpty == true)
                      ? run['output'].toString()
                      : '（没有标准输出）',
                ),
              ],
            ),
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

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    final terracotta = palette['brandTerracotta'];
    final sage = palette['brandSage'];
    final enabledCount = _tasks.where((t) => t['enabled'] == true).length;

    return Scaffold(
      appBar: IsleAppBar(
        title: const Text('本机脚本自动化'),
        actions: [
          IconButton(
            key: const ValueKey('refreshAutomationTasks'),
            tooltip: '刷新脚本目录',
            onPressed: _busy ? null : () => _reload(refresh: true),
            icon: const Icon(Icons.refresh_rounded),
          ),
          IsleHelpButton(
            title: '本机脚本与安全说明',
            accentColor: terracotta,
            items: const [
              IsleHelpItem(
                title: '任务目录与文件结构',
                body:
                    '每个自动化任务位于 Mac 数据目录 automation/scripts/<task-id>/ 下，由 task.json 定义入口脚本、Cron 表达式与通知事件；退出码 0 视为执行成功。',
              ),
              IsleHelpItem(
                title: '凭据与源码隔离',
                body:
                    '客户端仅修改启用开关、Cron 计划与通知渠道，不覆写脚本代码与环境变量；SMTP、Bark、Webhook 等通知密钥仅保存在 Mac 端钥匙串中。',
              ),
            ],
          ),
        ],
      ),
      body: IsleListView(
        maxWidth: IsleLayout.workbenchMaxWidth,
        children: [
          IsleFocalStage(
            icon: Icons.terminal_rounded,
            accent: terracotta,
            title: '本地外部脚本与 Agent 调度',
            metrics: [
              IsleFocalMetric(
                label: '已发现任务',
                value: '${_tasks.length}',
                accent: terracotta,
              ),
              IsleFocalMetric(
                label: '已启用',
                value: '$enabledCount',
                accent: sage,
              ),
              IsleFocalMetric(
                label: '通知渠道',
                value: '${_configuredChannels.length}',
                accent: palette['brandBlue'],
              ),
            ],
            actions: [
              FilledButton.tonalIcon(
                key: const ValueKey('copyAutomationAgentPrompt'),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: _copyAgentPrompt,
                icon: const Icon(Icons.copy_all_rounded, size: 17),
                label: const Text('复制 Agent 脚本规范'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_error != null)
            Notice(_error!, error: true, onRetry: () => _reload(refresh: true)),
          if (_notice != null) Notice(_notice!),
          if (_busy && !_loaded)
            const IsleLoadingState(label: '正在扫描本地脚本…')
          else if (_busy)
            const LinearProgressIndicator(),
          if (_loaded && _tasks.isEmpty && !_busy)
            const IsleEmptyStateCard(
              '在本机 automation/scripts/ 下创建任务后，点击右上角刷新即可发现。',
              title: '暂无本地脚本任务',
              icon: Icons.auto_mode_rounded,
            ),
          if (_tasks.isNotEmpty) ...[
            IsleSectionHeader(
              title: '已发现任务（${_tasks.length}）',
              accentColor: terracotta,
            ),
            IsleResponsiveGrid(
              minItemWidth: 340,
              maxColumns: 2,
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final task in _tasks)
                  _buildTaskCard(context, task, palette),
              ],
            ),
          ],
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildTaskHeader(
    BuildContext context,
    Map<String, dynamic> task,
    ColorScheme colors,
    IslePalette palette,
  ) {
    final id = task['id']?.toString() ?? '';
    final name = task['name']?.toString() ?? id;
    final entry = task['entry']?.toString() ?? '';
    final enabled = task['enabled'] == true;
    final running = task['running'] == true;
    final lastError = task['lastError']?.toString() ?? '';
    final schedule = task['schedule'] is Map
        ? Map<String, dynamic>.from(task['schedule'] as Map)
        : const <String, dynamic>{};
    final cron = schedule['cron']?.toString() ?? '无 Cron';
    final tz = schedule['timezone']?.toString() ?? '未设置时区';
    final lastRun = task['lastRun'];
    final nextRun = task['nextRun'];
    final terracotta = palette['brandTerracotta'];
    final sage = palette['brandSage'];
    final mineral = palette['brandBlue'];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IsleSquircleBadge(
          icon: Icons.terminal_rounded,
          color: terracotta,
          size: 38,
          iconSize: 19,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      name,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IsleStatusBadge(
                    label: running ? '运行中' : (enabled ? '已启用' : '已暂停'),
                    color: running
                        ? mineral
                        : enabled
                        ? sage
                        : colors.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                '$id · $entry · $cron ($tz)',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
              if (nextRun is num && nextRun > 0)
                Text(
                  '下次执行 ${_formatEpoch(nextRun)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (lastRun is Map)
                Text(
                  '上次结果 ${_runState(lastRun['state'])} · ${_formatEpoch(lastRun['finishedAt'])}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (lastError.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  lastError,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: colors.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTaskActions(
    BuildContext context,
    Map<String, dynamic> task,
    ColorScheme colors,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final id = task['id']?.toString() ?? '';
    final enabled = task['enabled'] == true;
    final running = task['running'] == true;
    final lastError = task['lastError']?.toString() ?? '';
    return Row(
      children: [
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: _busy || lastError.isNotEmpty
                    ? null
                    : () => _toggleTask(task),
                icon: Icon(
                  enabled ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 16,
                ),
                label: Text(enabled ? '关闭' : '启用'),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: _busy || lastError.isNotEmpty
                    ? null
                    : () => _startEdit(task),
                icon: const Icon(Icons.schedule_rounded, size: 16),
                label: const Text('Cron 与通知'),
              ),
            ],
          ),
        ),
        PopupMenuButton<String>(
          tooltip: '更多任务操作',
          enabled: !_busy,
          icon: Icon(
            Icons.more_horiz_rounded,
            size: 19,
            color: colors.onSurfaceVariant,
          ),
          style: IconButton.styleFrom(visualDensity: VisualDensity.compact),
          shape: IsleShapes.md(
            side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1),
          ),
          onSelected: (action) {
            if (action == 'logs') {
              _loadRuns(id);
            } else if (action == 'delete') {
              _deleteTask(task);
            }
          },
          itemBuilder: (_) => [
            isleActionMenuItem(
              value: 'logs',
              icon: Icons.receipt_long_rounded,
              label: '查看执行日志',
            ),
            isleActionMenuItem(
              value: 'delete',
              enabled: !running,
              icon: Icons.delete_outline_rounded,
              label: '删除任务目录',
              destructive: true,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTaskInlineEditor(
    BuildContext context,
    String id,
    ColorScheme colors,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 22),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final (expr, label) in const [
              ('*/15 * * * *', '每 15 分钟'),
              ('0 * * * *', '每小时'),
              ('0 2 * * *', '每天 02:00'),
            ])
              ActionChip(
                visualDensity: VisualDensity.compact,
                label: Text('$label ($expr)'),
                onPressed: () => _cronController.text = expr,
              ),
          ],
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final cronField = TextField(
              controller: _cronController,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(
                labelText: '五段 Cron',
                hintText: '0 8 * * *',
                isDense: true,
              ),
            );
            final tzField = TextField(
              controller: _timezoneController,
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
        const SizedBox(height: 10),
        IsleGroupCard(
          children: [
            IsleGroupTile(
              icon: Icons.schedule_rounded,
              title: '启用此定时任务',
              onTap: () => setState(() => _editingEnabled = !_editingEnabled),
              trailing: Switch.adaptive(
                value: _editingEnabled,
                onChanged: (v) => setState(() => _editingEnabled = v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('通知事件', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final (evId, evLabel) in _eventOptions)
              FilterChip(
                visualDensity: VisualDensity.compact,
                label: Text(evLabel),
                selected: _editingEvents.contains(evId),
                onSelected: (selected) {
                  setState(() {
                    if (selected) {
                      _editingEvents.add(evId);
                    } else {
                      _editingEvents.remove(evId);
                    }
                  });
                },
              ),
          ],
        ),
        const SizedBox(height: 10),
        Text('通知渠道', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final (chId, chLabel) in _channelOptions)
              FilterChip(
                visualDensity: VisualDensity.compact,
                label: Text(
                  _configuredChannels.contains(chId)
                      ? chLabel
                      : '$chLabel（未配置）',
                ),
                selected: _editingChannels.contains(chId),
                onSelected: _configuredChannels.contains(chId)
                    ? (selected) {
                        setState(() {
                          if (selected) {
                            _editingChannels.add(chId);
                          } else {
                            _editingChannels.remove(chId);
                          }
                        });
                      }
                    : null,
              ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: _busy ? null : _saveEdit,
              child: const Text('保存设置'),
            ),
            OutlinedButton(
              onPressed: _busy ? null : () => _reloadEditingTask(id),
              child: const Text('加载最新配置'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _editingTaskId = null;
                      _editingRevision = null;
                    }),
              child: const Text('取消'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTaskRunsPanel(
    BuildContext context,
    String id,
    ColorScheme colors,
    IslePalette palette,
  ) {
    final sage = palette['brandSage'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 22),
        Row(
          children: [
            Expanded(
              child: Text(
                '最近执行记录',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            TextButton(
              onPressed: _runsBusy ? null : () => _loadRuns(id),
              child: const Text('刷新日志'),
            ),
            TextButton(
              onPressed: () => setState(() {
                _selectedRunsTaskId = null;
                _runs = const [];
              }),
              child: const Text('收起'),
            ),
          ],
        ),
        if (_runsBusy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          )
        else if (_runs.isEmpty)
          Text(
            '暂无执行记录。',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          )
        else
          IsleGroupCard(
            margin: EdgeInsets.zero,
            children: [
              for (final run in _runs)
                ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 1,
                  ),
                  onTap: () => _showRunOutputDialog(context, run),
                  leading: IsleStatusBadge(
                    label: _runState(run['state']),
                    color: run['state']?.toString() == 'success'
                        ? sage
                        : colors.error,
                  ),
                  title: Text(
                    _formatEpoch(run['startedAt']),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: run['exitCode'] is int && run['exitCode'] >= 0
                      ? Text(
                          '退出码 ${run['exitCode']}',
                          style: const TextStyle(fontSize: 11.5),
                        )
                      : null,
                  trailing: const Icon(Icons.help_outline_rounded, size: 17),
                ),
            ],
          ),
      ],
    );
  }

  Widget _buildTaskCard(
    BuildContext context,
    Map<String, dynamic> task,
    IslePalette palette,
  ) {
    final colors = Theme.of(context).colorScheme;
    final id = task['id']?.toString() ?? '';
    return IsleSurface(
      key: ValueKey('automationTask_$id'),
      margin: EdgeInsets.zero,
      radius: IsleRadius.card,
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTaskHeader(context, task, colors, palette),
          const SizedBox(height: 10),
          _buildTaskActions(context, task, colors),
          if (_editingTaskId == id) _buildTaskInlineEditor(context, id, colors),
          if (_selectedRunsTaskId == id)
            _buildTaskRunsPanel(context, id, colors, palette),
        ],
      ),
    );
  }

  String _runState(Object? state) => switch (state) {
    'running' => '运行中',
    'success' => '成功',
    'failure' => '失败',
    'timeout' => '超时',
    'interrupted' => '中断',
    'skipped' => '已跳过',
    _ => state?.toString() ?? '未知',
  };

  Iterable<Widget> _deliveryLines(Object? deliveries) sync* {
    if (deliveries is! Map) return;
    const labels = {
      'queued': '等待发送',
      'sent': '已发送',
      'not_configured': '渠道未配置',
      'backoff': '渠道退避中',
      'queue_full': '发送队列已满',
      'interrupted': '发送结果未确认',
      'authentication_failed': '认证失败',
      'tls_failed': '加密连接失败',
      'connection_failed': '连接失败',
      'delivery_failed': '发送失败',
    };
    for (final (id, name) in _channelOptions) {
      final status = deliveries[id];
      if (status is String) {
        yield Text('$name · ${labels[status] ?? status}');
      }
    }
  }

  String _formatEpoch(Object? raw) {
    final seconds = raw is num
        ? raw.toInt()
        : int.tryParse('${raw ?? ''}') ?? 0;
    if (seconds <= 0) return '未知时间';
    final dt = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }
}
