import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';

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
      final channelList = (channelsRes['channels'] as List<dynamic>? ?? const [])
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
    final events = (notification['events'] as List<dynamic>? ?? const ['failure', 'timeout'])
        .map((e) => e.toString())
        .toSet();
    final channels = (notification['channels'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toSet();
    setState(() {
      _editingTaskId = task['id']?.toString();
      _cronController.text = schedule['cron']?.toString() ?? '';
      _timezoneController.text = schedule['timezone']?.toString() ?? 'Asia/Shanghai';
      _editingEnabled = task['enabled'] == true;
      _editingEvents = events;
      _editingChannels = channels;
    });
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
      '确定删除“$name”及其本地脚本目录吗？该操作不可恢复。',
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

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: IsleAppBar(
        title: const Text('本机脚本自动化'),
        actions: [
          IconButton(
            tooltip: '刷新脚本目录',
            onPressed: _busy ? null : () => _reload(refresh: true),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: IsleListView(
        children: [
          IsleSurface(
            radius: 18,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '脚本由你在 Mac 本地通过外部编辑器或 AI Agent 维护。轻屿只负责定时调度、通知和只读日志，不提供在线代码编辑器或依赖安装。',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  '任务目录：LightIsle 数据目录 / automation / scripts / <task-id> / task.json',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      key: const ValueKey('copyAutomationAgentPrompt'),
                      onPressed: _copyAgentPrompt,
                      icon: const Icon(Icons.copy_all_rounded, size: 18),
                      label: const Text('复制给本地 Agent 的脚本规范'),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('refreshAutomationTasks'),
                      onPressed: _busy ? null : () => _reload(refresh: true),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: Text(_busy ? '正在刷新…' : '刷新脚本'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_error != null)
            Notice(_error!, error: true, onRetry: () => _reload(refresh: true)),
          if (_notice != null) Notice(_notice!),
          if (_busy) const LinearProgressIndicator(),
          if (_loaded && _tasks.isEmpty && !_busy)
            const Notice('还没有本地自动化脚本。请在本机创建任务文件夹和 task.json，然后点击“刷新脚本”。'),
          if (_tasks.isNotEmpty)
            IsleResponsiveGrid(
              minItemWidth: 340,
              maxColumns: 2,
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final task in _tasks) _buildTaskCard(context, task),
              ],
            ),
          const IsleHelpDisclosure(
            summary: '安全与邮件模板说明',
            details:
                '脚本以运行 LightIsle 的当前 Mac 用户权限执行，具备真实文件访问能力，请只运行你信任的本地脚本。'
                '邮件模板（builtin / content / custom）由本地 task.json 与 HTML 文件决定，客户端编辑 Cron 或通知渠道时会自动保留原邮件模板设置。',
          ),
        ],
      ),
    );
  }

  Widget _buildTaskCard(BuildContext context, Map<String, dynamic> task) {
    final colors = Theme.of(context).colorScheme;
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

    return IsleSurface(
      key: ValueKey('automationTask_$id'),
      margin: EdgeInsets.zero,
      radius: 18,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IsleSquircleBadge(
                icon: Icons.terminal_rounded,
                color: colors.primary,
                size: 40,
                iconSize: 20,
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
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        IsleStatusBadge(
                          label: running
                              ? '运行中'
                              : enabled
                              ? '已启用'
                              : '已暂停',
                          color: running
                              ? const Color(0xFF0A84FF)
                              : enabled
                              ? const Color(0xFF10B981)
                              : const Color(0xFF64748B),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$id · $entry · $cron ($tz)',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
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
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
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
                onPressed: _busy || lastError.isNotEmpty
                    ? null
                    : () => _startEdit(task),
                icon: const Icon(Icons.schedule_rounded, size: 16),
                label: const Text('Cron 与通知'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _loadRuns(id),
                icon: const Icon(Icons.receipt_long_rounded, size: 16),
                label: const Text('日志'),
              ),
              TextButton.icon(
                onPressed: _busy || running ? null : () => _deleteTask(task),
                style: TextButton.styleFrom(foregroundColor: colors.error),
                icon: const Icon(Icons.delete_outline_rounded, size: 16),
                label: const Text('删除'),
              ),
            ],
          ),
          if (_editingTaskId == id) ...[
            const Divider(height: 24),
            Text(
              '仅修改任务启停、Cron 和通知事件/渠道；不会改动脚本代码、env.json 或本地邮件模板设置。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _cronController,
                    decoration: const InputDecoration(
                      labelText: '五段 Cron',
                      hintText: '0 8 * * *',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _timezoneController,
                    decoration: const InputDecoration(
                      labelText: '时区',
                      hintText: 'Asia/Shanghai',
                    ),
                  ),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用此任务'),
              value: _editingEnabled,
              onChanged: (v) => setState(() => _editingEnabled = v),
            ),
            Text('通知事件', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final (evId, evLabel) in _eventOptions)
                  FilterChip(
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
            Row(
              children: [
                FilledButton(
                  onPressed: _busy ? null : _saveEdit,
                  child: const Text('保存设置'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _editingTaskId = null),
                  child: const Text('取消'),
                ),
              ],
            ),
          ],
          if (_selectedRunsTaskId == id) ...[
            const Divider(height: 24),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '最近 30 次执行记录',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
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
                '暂无执行记录；定时触发后会显示退出码和标准输出。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              )
            else
              for (final run in _runs)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    '${_formatEpoch(run['startedAt'])} · ${run['state'] ?? ''} · 退出码 ${run['exitCode'] ?? 0}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: SelectableText(
                        (run['output']?.toString().trim().isNotEmpty == true)
                            ? run['output'].toString()
                            : '（没有标准输出）',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
          ],
        ],
      ),
    );
  }

  String _formatEpoch(Object? raw) {
    final seconds = raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}') ?? 0;
    if (seconds <= 0) return '未知时间';
    final dt = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }
}
