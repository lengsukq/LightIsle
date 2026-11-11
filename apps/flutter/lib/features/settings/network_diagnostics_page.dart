import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import 'network_diagnostics_controller.dart';

part 'network_diagnostics_painters.dart';

/// A native LightIsle-style dashboard rather than an external speedtest web UI.
class NetworkDiagnosticsPage extends StatefulWidget {
  const NetworkDiagnosticsPage({super.key, required this.api, this.controller});
  final LightIsleApi api;
  final NetworkDiagnosticsController? controller;

  @override
  State<NetworkDiagnosticsPage> createState() => _NetworkDiagnosticsPageState();
}

class _NetworkDiagnosticsPageState extends State<NetworkDiagnosticsPage>
    with SingleTickerProviderStateMixin {
  late final NetworkDiagnosticsController _test;
  late final AnimationController _motion;
  late final bool _ownsTest;

  @override
  void initState() {
    super.initState();
    _ownsTest = widget.controller == null;
    _test = widget.controller ?? NetworkDiagnosticsController(api: widget.api);
    _motion = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2100),
    );
    _test.addListener(_syncMotion);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  void _syncMotion() {
    if (!mounted) return;
    final disable = IsleLayout.opaqueNavigation(context);
    if (_test.busy && !disable) {
      if (!_motion.isAnimating) _motion.repeat();
    } else if (_motion.isAnimating) {
      _motion.stop();
    }
  }

  @override
  void dispose() {
    _test.removeListener(_syncMotion);
    _motion.dispose();
    if (_ownsTest) _test.dispose();
    super.dispose();
  }

  String _value(double? n, {int decimals = 1}) =>
      n == null || !n.isFinite ? '—' : n.toStringAsFixed(decimals);

  Widget _hero(NetworkDiagnosticsController test) {
    final scheme = Theme.of(context).colorScheme;
    final palette = IslePalette.of(context);
    final reduced = IsleLayout.opaqueNavigation(context);
    final wideText = MediaQuery.textScalerOf(context).scale(14) < 19;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: .55),
          width: .8,
        ),
        gradient: reduced
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  palette['brandBlue'].withValues(alpha: .12),
                  scheme.surface.withValues(alpha: .95),
                  palette['brandIndigo'].withValues(alpha: .09),
                ],
              ),
        color: reduced ? scheme.surface : null,
        boxShadow: IsleShadows.card(
          Theme.of(context).brightness == Brightness.dark,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 680 && wideText;
          if (test.stage == NetworkTestStage.failed) {
            // Failures should be actionable at the top of the page, not
            // hidden beneath an empty gauge and multiple metric cards.
            return Padding(
              padding: EdgeInsets.all(wide ? 26 : 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: scheme.errorContainer.withValues(alpha: .65),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          Icons.wifi_off_rounded,
                          color: scheme.error,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '连接检测中断',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 3),
                            Text(
                              widget.api.uri('/').host,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      key: const ValueKey('networkTestFailureCard'),
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: scheme.errorContainer.withValues(alpha: .52),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: scheme.error.withValues(alpha: .22),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 20,
                            color: scheme.error,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  test.error ?? '测速过程中发生未知错误。',
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                                if (test.failureAdvice != null) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    test.failureAdvice!,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '中断阶段：${test.failureStep ?? '连接检查'} · 已完成 ${test.completedSteps}/${test.totalSteps} 步',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 15),
                  SizedBox(
                    width: wide ? 248 : double.infinity,
                    child: FilledButton.icon(
                      key: const ValueKey('networkTestStart'),
                      onPressed: () => unawaited(test.start()),
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重新检测'),
                    ),
                  ),
                ],
              ),
            );
          }
          final gauge = SizedBox(
            width: wide ? 280 : math.min(216, constraints.maxWidth - 32),
            height: wide ? 280 : 204,
            child: AnimatedBuilder(
              animation: _motion,
              builder: (context, child) => CustomPaint(
                key: const ValueKey('networkTestGauge'),
                painter: _TestGaugePainter(
                  progress:
                      (test.progress +
                              (test.busy && test.totalSteps > 0
                                  ? test.transferProgress / test.totalSteps
                                  : 0))
                          .clamp(0.0, 1.0),
                  pulse: _motion.value,
                  animated: test.busy && !reduced,
                  primary: palette['brandBlue'],
                  secondary: palette['brandCyan'],
                  tertiary: palette['brandIndigo'],
                  track: scheme.outlineVariant,
                ),
                child: child,
              ),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 55),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        switch (test.stage) {
                          NetworkTestStage.completed =>
                            Icons.check_circle_outline_rounded,
                          NetworkTestStage.failed =>
                            Icons.error_outline_rounded,
                          NetworkTestStage.cancelled =>
                            Icons.pause_circle_outline,
                          _ => Icons.wifi_tethering_rounded,
                        },
                        size: 24,
                        color: test.stage == NetworkTestStage.failed
                            ? scheme.error
                            : palette['brandBlue'],
                      ),
                      const SizedBox(height: 13),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          test.stage == NetworkTestStage.download
                              ? _value(test.downloadMbps)
                              : test.stage == NetworkTestStage.upload
                              ? _value(test.uploadMbps)
                              : test.stage == NetworkTestStage.completed
                              ? test.mode == NetworkTestMode.observe
                                    ? _value(test.successRate)
                                    : _value(test.downloadMbps)
                              : test.busy
                              ? '${(test.progress * 100).round()}'
                              : '—',
                          style: Theme.of(context).textTheme.displayMedium
                              ?.copyWith(
                                fontSize: 46,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -1.8,
                              ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        test.stage == NetworkTestStage.completed &&
                                test.mode == NetworkTestMode.observe
                            ? '% 请求成功'
                            : test.stage == NetworkTestStage.download ||
                                  test.stage == NetworkTestStage.upload ||
                                  test.stage == NetworkTestStage.completed
                            ? 'Mbps'
                            : test.busy
                            ? '% 已完成'
                            : 'NAS LINK',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: scheme.onSurfaceVariant,
                              letterSpacing: 1.6,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          final controls = Column(
            crossAxisAlignment: wide
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.center,
            children: [
              Text(
                test.stage == NetworkTestStage.completed
                    ? test.verdict
                    : '当前 NAS 连接检测',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: wide ? TextAlign.start : TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                test.stageText,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 9),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.dns_outlined,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      widget.api.uri('/').host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: wide ? 270 : double.infinity,
                child: LinearProgressIndicator(
                  value: test.progress,
                  minHeight: 5,
                  borderRadius: BorderRadius.circular(10),
                  color: palette['brandCyan'],
                  backgroundColor: scheme.outlineVariant.withValues(alpha: .5),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                test.busy
                    ? '检测步骤 ${test.completedSteps} / ${test.totalSteps}'
                    : '只使用内存测试数据，不创建 NAS 文件',
                textAlign: wide ? TextAlign.start : TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 19),
              SizedBox(
                width: wide ? 270 : double.infinity,
                child: test.busy
                    ? OutlinedButton.icon(
                        key: const ValueKey('networkTestStop'),
                        onPressed: test.stop,
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: const Text('停止检测'),
                      )
                    : FilledButton.icon(
                        key: const ValueKey('networkTestStart'),
                        onPressed: () => unawaited(test.start()),
                        icon: Icon(
                          test.stage == NetworkTestStage.idle
                              ? Icons.bolt_rounded
                              : Icons.refresh_rounded,
                        ),
                        label: Text(
                          test.stage == NetworkTestStage.idle ? '开始检测' : '重新检测',
                        ),
                      ),
              ),
            ],
          );
          return Padding(
            padding: EdgeInsets.all(wide ? 26 : 18),
            child: wide
                ? Row(
                    children: [
                      gauge,
                      const SizedBox(width: 22),
                      Expanded(child: controls),
                    ],
                  )
                : Column(
                    children: [
                      Center(child: gauge),
                      const SizedBox(height: 5),
                      controls,
                    ],
                  ),
          );
        },
      ),
    );
  }

  Widget _metric({
    required IconData icon,
    required Color tint,
    required String label,
    required String value,
    required String unit,
    required String detail,
  }) => IsleSurface(
    radius: 18,
    padding: const EdgeInsets.all(15),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: tint, size: 19),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label, style: Theme.of(context).textTheme.labelLarge),
            ),
          ],
        ),
        const SizedBox(height: 13),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(width: 5),
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(unit, style: Theme.of(context).textTheme.bodySmall),
            ),
          ],
        ),
        const SizedBox(height: 5),
        Text(
          detail,
          maxLines: 2,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    ),
  );

  Widget _metrics(NetworkDiagnosticsController test) {
    final palette = IslePalette.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns =
            constraints.maxWidth >= 820 &&
                MediaQuery.textScalerOf(context).scale(14) < 19
            ? 4
            : 2;
        final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
        final items = [
          _metric(
            icon: Icons.south_rounded,
            tint: palette['brandBlue'],
            label: '下载速度',
            value: test.downloadMbps == null
                ? test.stage == NetworkTestStage.failed
                      ? '未完成'
                      : '待测'
                : _value(test.downloadMbps),
            unit: test.downloadMbps == null ? '' : 'Mbps',
            detail: test.downloadMbps == null
                ? test.mode == NetworkTestMode.observe
                      ? '此模式不测吞吐'
                      : test.stage == NetworkTestStage.failed
                      ? '中断前尚未测出'
                      : '等待测试'
                : '${_value(test.downloadMbps! / 8)} MB/s',
          ),
          _metric(
            icon: Icons.north_rounded,
            tint: palette['brandCyan'],
            label: '上传速度',
            value: test.uploadMbps == null
                ? test.stage == NetworkTestStage.failed
                      ? '未完成'
                      : '待测'
                : _value(test.uploadMbps),
            unit: test.uploadMbps == null ? '' : 'Mbps',
            detail: test.uploadMbps == null
                ? test.mode == NetworkTestMode.observe
                      ? '此模式不测吞吐'
                      : test.stage == NetworkTestStage.failed
                      ? '中断前尚未测出'
                      : '等待测试'
                : '${_value(test.uploadMbps! / 8)} MB/s',
          ),
          _metric(
            icon: Icons.timer_outlined,
            tint: palette['brandIndigo'],
            label: '平均延迟',
            value:
                test.averageLatency == null &&
                    test.stage == NetworkTestStage.failed
                ? '未完成'
                : _value(test.averageLatency),
            unit: test.averageLatency == null ? '' : 'ms',
            detail: 'HTTP 应用层往返',
          ),
          _metric(
            icon: Icons.multiline_chart_rounded,
            tint: palette['brandViolet'],
            label: '延迟抖动',
            value: test.jitter == null && test.stage == NetworkTestStage.failed
                ? '未完成'
                : _value(test.jitter),
            unit: test.jitter == null ? '' : 'ms',
            detail: '连续往返时间变化',
          ),
        ];
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final item in items) SizedBox(width: width, child: item),
          ],
        );
      },
    );
  }

  Widget _latency(NetworkDiagnosticsController test) {
    final scheme = Theme.of(context).colorScheme;
    return IsleSurface(
      radius: 20,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.show_chart_rounded,
                size: 21,
                color: IslePalette.of(context)['brandBlue'],
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '稳定性趋势',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(
                '${test.successfulRequests} / ${test.totalProbes} 成功',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 110,
            width: double.infinity,
            child: CustomPaint(
              key: const ValueKey('networkTestLatencyChart'),
              painter: _LatencyLinePainter(
                test.latencyPoints,
                IslePalette.of(context)['brandBlue'],
                scheme.error,
                scheme.outlineVariant,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 18,
            runSpacing: 6,
            children: [
              Text(
                'P95  ${_value(test.p95Latency)} ms',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                '请求失败率  ${_value(test.failureRate)}%',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                '最长连续失败  ${test.longestFailureStreak} 次',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                'Core 本次进程运行  ${test.coreUptimeText}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (test.restartHints > 0)
                Text(
                  '检测期间发现 ${test.restartHints} 次进程重启迹象',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.error),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '红点表示 HTTP 请求失败。请求失败率不等于网络层丢包率。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: IsleAppBar(title: const Text('连接测速')),
    body: ListenableBuilder(
      listenable: _test,
      builder: (context, _) => IsleListView(
        maxWidth: 880,
        children: [
          _hero(_test),
          const SizedBox(height: 18),
          Row(
            children: [
              const Expanded(child: IsleSectionHeader(title: '检测模式')),
              Text(switch (_test.mode) {
                NetworkTestMode.quick => '约 8 MiB 流量',
                NetworkTestMode.standard => '约 32 MiB 流量',
                NetworkTestMode.observe => '约 1 分钟 · 轻量请求',
              }, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              for (final mode in NetworkTestMode.values)
                ChoiceChip(
                  key: ValueKey('networkTestMode:${mode.name}'),
                  selected: _test.mode == mode,
                  label: Text(mode.label),
                  avatar: Icon(switch (mode) {
                    NetworkTestMode.quick => Icons.bolt_rounded,
                    NetworkTestMode.standard => Icons.query_stats_rounded,
                    NetworkTestMode.observe => Icons.monitor_heart_outlined,
                  }, size: 18),
                  onSelected: _test.busy ? null : (_) => _test.selectMode(mode),
                ),
            ],
          ),
          const SizedBox(height: 20),
          const IsleSectionHeader(title: '实时指标'),
          _metrics(_test),
          const SizedBox(height: 18),
          _latency(_test),
          const SizedBox(height: 12),
          const IsleHelpDisclosure(
            summary: '如何理解测速结果？',
            details:
                '只连接当前登录的 LightIsle NAS，不连接第三方测速服务器。'
                '下载数据由服务器内存生成，上传数据在服务器内存中直接丢弃，不保存文件。'
                '延迟是 HTTP 往返而不是 ICMP Ping，失败率也不是 IP 丢包率。'
                '测速结果受 Wi-Fi、路由器、手机、TLS、远程隧道和 NAS 处理能力共同影响，'
                '不能仅凭某项数值确定问题发生的位置。'
                '快速检测约用 8 MiB，完整检测约用 32 MiB 数据流量。'
                '持续观察模式约一分钟，每两秒发送轻量健康请求，不进行上传/下载吞吐测速；'
                '连续失败次数可用于发现短时中断，但不能证明 NAS 的长期运行时间。'
                'Core 运行时长只计算当前 Go 服务进程，不代表 Mac 的开机时间；重启迹象只用于辅助排查。'
                '离开页面会停止检测，锁屏持续测速不保证。',
          ),
          const SizedBox(height: 24),
        ],
      ),
    ),
  );
}
