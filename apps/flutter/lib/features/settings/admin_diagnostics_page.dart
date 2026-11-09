import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';

/// Admin-only read-only dashboard. Host actions remain in the Mac native UI.
class AdminDiagnosticsPage extends StatefulWidget {
  const AdminDiagnosticsPage({super.key, required this.api});
  final LightIsleApi api;

  @override
  State<AdminDiagnosticsPage> createState() => _AdminDiagnosticsPageState();
}

class _AdminDiagnosticsPageState extends State<AdminDiagnosticsPage> {
  List<Map<String, dynamic>> _history = [];
  List<Map<String, dynamic>> _drives = [];
  Map<String, dynamic>? _network;
  Map<String, dynamic>? _mapKeyStatus, _tmdbKeyStatus;
  final _health = <String, Map<String, dynamic>>{};
  final _healthErrors = <String, String>{};
  String? _historyError, _networkError, _driveError, _checking;
  String? _mapStatusError, _tmdbStatusError;
  bool _loading = false, _loaded = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<Map<String, dynamic>> _read(
    String path, {
    Map<String, String>? query,
  }) async {
    try {
      return await widget.api.get(path, query: query);
    } catch (e) {
      return {'_error': userFacingError(e)};
    }
  }

  Future<void> _refresh() async {
    if (_loading) return;
    final current = ++_generation;
    setState(() => _loading = true);
    final responses = await Future.wait([
      _read('/api/v2/system/history', query: {'limit': '180'}),
      _read('/api/v2/system/diagnostics'),
      _read('/api/v2/admin/disks'),
      _read('/api/v2/map/status'),
      _read('/api/v2/cinema/scrape/status'),
    ]);
    if (!mounted || current != _generation) return;
    setState(() {
      _historyError = responses[0]['_error']?.toString();
      _networkError = responses[1]['_error']?.toString();
      _driveError = responses[2]['_error']?.toString();
      _mapStatusError = responses[3]['_error']?.toString();
      _tmdbStatusError = responses[4]['_error']?.toString();
      if (_mapStatusError == null) _mapKeyStatus = responses[3];
      if (_tmdbStatusError == null) _tmdbKeyStatus = responses[4];
      if (_historyError == null) _history = objectList(responses[0]['samples']);
      if (_networkError == null) _network = responses[1];
      if (_driveError == null) {
        _drives = objectList(responses[2]['disks']);
        final ids = _drives.map((d) => d['id']?.toString()).toSet();
        _health.removeWhere((id, _) => !ids.contains(id));
        _healthErrors.removeWhere((id, _) => !ids.contains(id));
      }
      _loaded = true;
      _loading = false;
    });
  }

  Future<void> _checkHealth(Map<String, dynamic> disk) async {
    if (_checking != null || disk['external'] != true) return;
    final id = disk['id']?.toString() ?? '';
    if (!RegExp(r'^disk[0-9]+(?:s[0-9]+)?$').hasMatch(id)) return;
    setState(() {
      _checking = id;
      _healthErrors.remove(id);
    });
    try {
      final response = await widget.api.get(
        '/api/v2/admin/disks/${Uri.encodeComponent(id)}/smart',
      );
      if (!mounted) return;
      final raw = response['report'];
      if (raw is! Map) throw const FormatException('磁盘检测结果无效');
      setState(() {
        _health[id] = {
          ...Map<String, dynamic>.from(raw),
          'risk': response['risk'],
        };
      });
    } catch (e) {
      if (mounted) setState(() => _healthErrors[id] = userFacingError(e));
    } finally {
      if (mounted) setState(() => _checking = null);
    }
  }

  String _healthText(Map<String, dynamic> report) {
    if (report['source'] != 'smartctl') {
      return switch (report['reason']) {
        'smartctl_not_installed' => 'Mac 未安装 smartmontools',
        'smartctl_permission_required' => '设备 SMART 权限不足',
        'smartctl_device_unsupported' => '该设备不支持 SMART',
        _ => '无法确认磁盘健康状态',
      };
    }
    final risk = switch (report['risk']) {
      'critical' => '严重警告',
      'warning' => '需要留意',
      'ok' => '未发现明显异常',
      _ => '状态未知',
    };
    final temperature = report['temperature'];
    return risk + (temperature is num ? ' · $temperature°C' : '');
  }

  Widget _metric(String label, String field, Color tint) {
    final values = _history
        .map((item) => item[field])
        .whereType<num>()
        .map((value) => value.toDouble())
        .where((value) => value.isFinite && value >= 0 && value <= 100)
        .toList();
    final last = values.isEmpty ? null : values.last;
    return IsleSurface(
      padding: const EdgeInsets.all(12),
      radius: 14,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Text(
            last == null ? '暂无采样' : '${last.toStringAsFixed(1)}%',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: last == null ? 0 : last / 100,
            color: tint,
            backgroundColor: tint.withValues(alpha: .15),
            minHeight: 5,
          ),
          const SizedBox(height: 5),
          Text(
            values.isEmpty ? '等待采样' : '${values.length} 个历史样本',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _metrics() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const IsleSectionHeader(title: '运行指标'),
      if (_historyError != null)
        Notice('历史采样读取失败：${_historyError!}', error: true, onRetry: _refresh)
      else
        LayoutBuilder(
          builder: (context, box) {
            final zoomed = MediaQuery.textScalerOf(context).scale(14) > 18;
            final columns = !zoomed && box.maxWidth >= 340
                ? 3
                : !zoomed && box.maxWidth >= 260
                ? 2
                : 1;
            final spacing = box.maxWidth < 500 ? 8.0 : 10.0;
            final w = (box.maxWidth - (columns - 1) * spacing) / columns;
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                SizedBox(
                  width: w,
                  child: _metric('处理器', 'cpuPercent', const Color(0xff3b82f6)),
                ),
                SizedBox(
                  width: w,
                  child: _metric(
                    '内存',
                    'memoryPercent',
                    const Color(0xff8b5cf6),
                  ),
                ),
                SizedBox(
                  width: w,
                  child: _metric(
                    '磁盘占用',
                    'diskPercent',
                    const Color(0xff0ea5e9),
                  ),
                ),
              ],
            );
          },
        ),
      const SizedBox(height: 6),
      Text(
        '最近最多 180 条历史样本，采样间隔约一分钟。',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );

  Widget _keysStatus() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const IsleSectionHeader(title: '第三方服务 Key 状态'),
      IsleGroupCard(
        children: [
          IsleGroupTile(
            icon: Icons.map_outlined,
            iconBgColor: const Color(0xff0ea5e9),
            title: '天地图 API Key',
            subtitle: _mapStatusError != null
                ? '无法读取配置状态'
                : _mapKeyStatus?['tiandituConfigured'] == true
                ? '已配置并由 Mac Core 接收'
                : '未配置或 Core 尚未接收',
          ),
          IsleGroupTile(
            icon: Icons.movie_filter_outlined,
            iconBgColor: const Color(0xfff97316),
            title: 'TMDB Read Access Token',
            subtitle: _tmdbStatusError != null
                ? '无法读取配置状态'
                : _tmdbKeyStatus?['tmdbConfigured'] == true
                ? '已配置并由 Mac Core 接收'
                : '未配置或 Core 尚未接收',
          ),
        ],
      ),
      const IsleHelpDisclosure(
        summary: '为何不能在手机直接查看或修改 Key？',
        details:
            '天地图、TMDB 和部分隧道 Token 仅保存在 Mac 钥匙串，并通过本机私有 IPC 提供给 Core。'
            '移动端只读取配置是否生效，不接收 Key 明文，也不新增远程修改密钥的接口。'
            '请在 Mac 原生管理端的媒体服务或网络连接设置中保存、更换和清除密钥。',
      ),
    ],
  );

  Widget _networkStatus() {
    final data = _network;
    String safe(String name) {
      final value = data?[name]?.toString() ?? '';
      return value.isEmpty ? '未获取' : value;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const IsleSectionHeader(title: '本机网络状态'),
        if (_networkError != null)
          Notice('网络诊断暂不可用：${_networkError!}', error: true, onRetry: _refresh)
        else if (data != null)
          IsleGroupCard(
            children: [
              IsleGroupTile(
                icon: Icons.lock_outline_rounded,
                iconBgColor: const Color(0xff10b981),
                title: '当前连接',
                subtitle: safe('requestTransport'),
              ),
              IsleGroupTile(
                icon: Icons.router_outlined,
                iconBgColor: const Color(0xff6366f1),
                title: '默认网关',
                subtitle:
                    '${safe('gatewayIPv4')} · ${safe('defaultInterface')}',
              ),
              for (final iface in objectList(data['interfaces']))
                IsleGroupTile(
                  icon: iface['up'] == true
                      ? Icons.lan_outlined
                      : Icons.portable_wifi_off_rounded,
                  iconBgColor: iface['up'] == true
                      ? const Color(0xff3b82f6)
                      : const Color(0xff64748b),
                  title: iface['name']?.toString() ?? '接口',
                  subtitle: iface['addresses'] is List
                      ? (iface['addresses'] as List).join(' · ')
                      : '无可用地址',
                  trailing: IsleBadgePill(
                    label: iface['up'] == true ? '启用' : '停用',
                    color: iface['up'] == true
                        ? const Color(0xff10b981)
                        : const Color(0xff64748b),
                  ),
                ),
            ],
          ),
        const IsleHelpDisclosure(
          summary: '网络诊断的范围',
          details:
              '仅查看 Mac 本机网卡、网关和本次 HTTP/HTTPS 请求；不检测公网、Cloudflare 或 FRP 连通性。',
        ),
      ],
    );
  }

  Widget _diskStatus() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const IsleSectionHeader(title: '磁盘健康'),
      if (_driveError != null)
        Notice('读取磁盘列表失败：${_driveError!}', error: true, onRetry: _refresh)
      else if (_drives.isEmpty && _loaded)
        const IsleEmptyStateCard('未发现磁盘设备。', icon: Icons.disc_full_outlined)
      else
        IsleResponsiveGrid(
          minItemWidth: 300,
          maxColumns: 3,
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final disk in _drives)
              IsleSurface(
                margin: EdgeInsets.zero,
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const IsleSquircleBadge(
                          icon: Icons.storage_rounded,
                          color: Color(0xff3b82f6),
                          size: 34,
                          iconSize: 18,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            disk['name']?.toString() ?? '磁盘',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${disk['mounted'] == true ? '已挂载' : '未挂载'} · ${disk['filesystem']?.toString() ?? '未知格式'} · ${disk['readOnly'] == true ? '只读' : '可写'}',
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${formatBytes(disk['free'] as num?)} 可用 / ${formatBytes(disk['total'] as num?)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (_health[disk['id']] != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        _healthText(_health[disk['id']]!),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                    if (_healthErrors[disk['id']] != null)
                      Notice(_healthErrors[disk['id']]!, error: true),
                    if (disk['external'] == true)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: _checking == null
                              ? () => _checkHealth(disk)
                              : null,
                          icon: const Icon(Icons.monitor_heart_outlined),
                          label: Text(
                            _checking == disk['id'] ? '检测中…' : '检查 SMART',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      const IsleHelpDisclosure(
        summary: 'SMART 不是备份',
        details:
            '仅手动读取外接盘 SMART。缺少 smartctl 或设备权限时显示未知，不推断为健康；无挂载、弹出、格式化、修复操作。',
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: IsleAppBar(
      title: const Text('设备诊断'),
      actions: [
        IconButton(
          tooltip: '刷新诊断',
          onPressed: _loading ? null : _refresh,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    ),
    body: IsleListView(
      children: [
        const IsleIntroCard(
          icon: Icons.monitor_heart_outlined,
          title: '本机硬件与服务只读巡检',
          description: '管理员只读查看性能、网络及磁盘状态。宿主级修改操作请前往 Mac 原生管理端执行。',
        ),
        if (_loading) const LinearProgressIndicator(),
        if (_loaded) ...[
          _metrics(),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final zoomed = MediaQuery.textScalerOf(context).scale(14) > 18;
              if (!zoomed && constraints.maxWidth >= 680) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _networkStatus()),
                    const SizedBox(width: 14),
                    Expanded(child: _keysStatus()),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _networkStatus(),
                  const SizedBox(height: 10),
                  _keysStatus(),
                ],
              );
            },
          ),
          const SizedBox(height: 10),
          _diskStatus(),
        ],
      ],
    ),
  );
}
