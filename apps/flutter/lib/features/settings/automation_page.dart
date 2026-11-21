import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'automation_task_card.dart';

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
                  AutomationTaskCard(
                    task: task,
                    busy: _busy,
                    isEditing: _editingTaskId == task['id']?.toString(),
                    isShowingRuns:
                        _selectedRunsTaskId == task['id']?.toString(),
                    runsBusy: _runsBusy,
                    runs: _runs,
                    configuredChannels: _configuredChannels,
                    cronController: _cronController,
                    timezoneController: _timezoneController,
                    editingEnabled: _editingEnabled,
                    editingEvents: _editingEvents,
                    editingChannels: _editingChannels,
                    onToggleEnabled: () => _toggleTask(task),
                    onStartEdit: () => _startEdit(task),
                    onLoadRuns: () => _loadRuns(task['id']?.toString() ?? ''),
                    onDeleteTask: () => _deleteTask(task),
                    onEditingEnabledChanged: (v) =>
                        setState(() => _editingEnabled = v),
                    onToggleEditingEvent: (eventId, selected) => setState(() {
                      if (selected) {
                        _editingEvents.add(eventId);
                      } else {
                        _editingEvents.remove(eventId);
                      }
                    }),
                    onToggleEditingChannel: (channelId, selected) =>
                        setState(() {
                          if (selected) {
                            _editingChannels.add(channelId);
                          } else {
                            _editingChannels.remove(channelId);
                          }
                        }),
                    onSaveEdit: _saveEdit,
                    onReloadEditingTask: () =>
                        _reloadEditingTask(task['id']?.toString() ?? ''),
                    onCancelEdit: () => setState(() {
                      _editingTaskId = null;
                      _editingRevision = null;
                    }),
                    onCollapseRuns: () => setState(() {
                      _selectedRunsTaskId = null;
                      _runs = const [];
                    }),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
