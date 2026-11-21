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

  double? _latestValue(String field) {
    final values = _history
        .map((item) => item[field])
        .whereType<num>()
        .map((value) => value.toDouble())
        .where((value) => value.isFinite && value >= 0 && value <= 100)
        .toList();
    return values.isEmpty ? null : values.last;
  }

  Widget _metric(String label, String field, IconData icon, Color tint) {
    final values = _history
        .map((item) => item[field])
        .whereType<num>()
        .map((value) => value.toDouble())
        .where((value) => value.isFinite && value >= 0 && value <= 100)
        .toList();
    final last = values.isEmpty ? null : values.last;
    return IsleSurface(
      padding: const EdgeInsets.all(14),
      radius: IsleRadius.card,
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IsleSquircleBadge(
                icon: icon,
                color: tint,
                size: 28,
                iconSize: 15,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            last == null ? '暂无采样' : '${last.toStringAsFixed(1)}%',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: IsleRadius.brPill,
            child: LinearProgressIndicator(
              value: last == null ? 0 : last / 100,
              color: tint,
              backgroundColor: tint.withValues(alpha: 0.14),
              minHeight: 5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _metrics(IslePalette palette) => Column(
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
            final spacing = box.maxWidth < 500 ? 8.0 : 12.0;
            final w = (box.maxWidth - (columns - 1) * spacing) / columns;
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                SizedBox(
                  width: w,
                  child: _metric(
                    '处理器',
                    'cpuPercent',
                    Icons.memory_rounded,
                    palette['brandBlue'],
                  ),
                ),
                SizedBox(
                  width: w,
                  child: _metric(
                    '内存',
                    'memoryPercent',
                    Icons.developer_board_rounded,
                    palette['brandViolet'],
                  ),
                ),
                SizedBox(
                  width: w,
                  child: _metric(
                    '磁盘占用',
                    'diskPercent',
                    Icons.pie_chart_outline_rounded,
                    palette['brandAmber'],
                  ),
                ),
              ],
            );
          },
        ),
    ],
  );

  Widget _keysStatus(IslePalette palette) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      IsleSectionHeader(
        title: '第三方服务 Key 状态',
        accentColor: palette['brandCyan'],
        helpTitle: '为何不能在此查看或修改 Key？',
        helpBody:
            '天地图、TMDB 及隧道密钥仅保存在 Mac 系统钥匙串中，通过本机私有 IPC 提供给 Core。客户端仅展示生效状态，不传输密钥明文；修改请前往 Mac 原生管理端。',
      ),
      IsleGroupCard(
        children: [
          IsleGroupTile(
            icon: Icons.map_outlined,
            iconBgColor: palette['brandCyan'],
            title: '天地图 API Key',
            subtitle: _mapStatusError != null
                ? '无法读取配置状态'
                : _mapKeyStatus?['tiandituConfigured'] == true
                ? '已配置并由 Mac Core 接收'
                : '未配置或 Core 尚未接收',
          ),
          IsleGroupTile(
            icon: Icons.movie_filter_outlined,
            iconBgColor: palette['brandTerracotta'],
            title: 'TMDB Read Access Token',
            subtitle: _tmdbStatusError != null
                ? '无法读取配置状态'
                : _tmdbKeyStatus?['tmdbConfigured'] == true
                ? '已配置并由 Mac Core 接收'
                : '未配置或 Core 尚未接收',
          ),
        ],
      ),
    ],
  );

  Widget _networkStatus(IslePalette palette) {
    final data = _network;
    String safe(String name) {
      final value = data?[name]?.toString() ?? '';
      return value.isEmpty ? '未获取' : value;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IsleSectionHeader(
          title: '本机网络状态',
          accentColor: palette['brandSage'],
          helpTitle: '网络诊断范围',
          helpBody: '此处仅展示 Mac 本机网卡、默认网关与当前请求传输方式，不检测公网出口或异地隧道连通性。',
        ),
        if (_networkError != null)
          Notice('网络诊断暂不可用：${_networkError!}', error: true, onRetry: _refresh)
        else if (data != null)
          IsleGroupCard(
            children: [
              IsleGroupTile(
                icon: Icons.lock_outline_rounded,
                iconBgColor: palette['brandSage'],
                title: '当前连接',
                subtitle: safe('requestTransport'),
              ),
              IsleGroupTile(
                icon: Icons.router_outlined,
                iconBgColor: palette['brandIndigo'],
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
                      ? palette['brandBlue']
                      : palette['textTertiary'],
                  title: iface['name']?.toString() ?? '接口',
                  subtitle: iface['addresses'] is List
                      ? (iface['addresses'] as List).join(' · ')
                      : '无可用地址',
                  trailing: IsleBadgePill(
                    label: iface['up'] == true ? '启用' : '停用',
                    color: iface['up'] == true
                        ? palette['brandSage']
                        : palette['textTertiary'],
                  ),
                ),
            ],
          ),
      ],
    );
  }

  Widget _diskStatus(IslePalette palette) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      IsleSectionHeader(
        title: '磁盘健康',
        accentColor: palette['brandAmber'],
        helpTitle: 'SMART 检测说明',
        helpBody:
            '仅按需读取外接物理盘的 SMART 指标；缺少 smartmontools 或设备权限时将明确标注未知，不推断为健康，也不能替代定期异地备份。',
      ),
      if (_driveError != null)
        Notice('读取磁盘列表失败：${_driveError!}', error: true, onRetry: _refresh)
      else if (_drives.isEmpty && _loaded)
        const IsleEmptyStateCard('未发现磁盘设备。', icon: Icons.disc_full_outlined)
      else
        IsleResponsiveGrid(
          minItemWidth: 300,
          maxColumns: 3,
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final disk in _drives)
              IsleSurface(
                margin: EdgeInsets.zero,
                padding: const EdgeInsets.all(15),
                radius: IsleRadius.card,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        IsleSquircleBadge(
                          icon: Icons.storage_rounded,
                          color: disk['external'] == true
                              ? palette['brandAmber']
                              : palette['brandBlue'],
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
                        IsleStatusBadge(
                          label: disk['mounted'] == true ? '已挂载' : '未挂载',
                          color: disk['mounted'] == true
                              ? palette['brandSage']
                              : palette['textTertiary'],
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 9,
                      ),
                      decoration: IsleDecorations.recessedWell(
                        context,
                        radius: IsleRadius.sm,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${disk['filesystem']?.toString() ?? '未知格式'} · ${disk['readOnly'] == true ? '只读' : '可写'}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${formatBytes(disk['free'] as num?)} 可用 / ${formatBytes(disk['total'] as num?)}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: palette['secondaryText'],
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                          ),
                        ],
                      ),
                    ),
                    if (_health[disk['id']] != null) ...[
                      const SizedBox(height: 6),
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
    ],
  );

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    final cpu = _latestValue('cpuPercent');
    final mem = _latestValue('memoryPercent');

    return Scaffold(
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
        maxWidth: IsleLayout.workbenchMaxWidth,
        children: [
          IsleFocalStage(
            icon: Icons.monitor_heart_outlined,
            accent: palette['brandBlue'],
            title: '本机硬件与服务巡检',
            metrics: [
              IsleFocalMetric(
                label: '处理器瞬时',
                value: cpu == null ? '—' : '${cpu.toStringAsFixed(1)}%',
                icon: Icons.memory_rounded,
                color: palette['brandBlue'],
              ),
              IsleFocalMetric(
                label: '内存占用',
                value: mem == null ? '—' : '${mem.toStringAsFixed(1)}%',
                icon: Icons.developer_board_rounded,
                color: palette['brandViolet'],
              ),
              IsleFocalMetric(
                label: '识别物理盘',
                value: _loaded ? '${_drives.length} 块' : '读取中',
                icon: Icons.storage_rounded,
                color: palette['brandAmber'],
              ),
            ],
          ),
          if (_loading)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: ClipRRect(
                borderRadius: IsleRadius.brPill,
                child: const LinearProgressIndicator(minHeight: 3),
              ),
            ),
          if (_loaded) ...[
            _metrics(palette),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final zoomed = MediaQuery.textScalerOf(context).scale(14) > 18;
                if (!zoomed && constraints.maxWidth >= 680) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _networkStatus(palette)),
                      const SizedBox(width: 16),
                      Expanded(child: _keysStatus(palette)),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _networkStatus(palette),
                    const SizedBox(height: 12),
                    _keysStatus(palette),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            _diskStatus(palette),
          ],
        ],
      ),
    );
  }
}
