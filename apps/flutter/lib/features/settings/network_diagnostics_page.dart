import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import 'network_diagnostics_controller.dart';
import 'tailscale_status_card.dart';

part 'network_diagnostics_painters.dart';

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

  Widget _buildFailedHeroContent(
    NetworkDiagnosticsController test, {
    required ColorScheme scheme,
    required bool wide,
  }) {
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
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.api.uri('/').host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
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
                border: Border.all(color: scheme.error.withValues(alpha: .22)),
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
                                ?.copyWith(color: scheme.onSurfaceVariant),
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
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
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

  String _gaugePrimaryText(NetworkDiagnosticsController test) {
    if (test.stage == NetworkTestStage.download) {
      return _value(test.downloadMbps);
    }
    if (test.stage == NetworkTestStage.upload) return _value(test.uploadMbps);
    if (test.stage == NetworkTestStage.completed) {
      return test.mode == NetworkTestMode.observe
          ? _value(test.successRate)
          : _value(test.downloadMbps);
    }
    return test.busy ? '${(test.progress * 100).round()}' : '—';
  }

  String _gaugeUnitText(NetworkDiagnosticsController test) {
    if (test.stage == NetworkTestStage.completed &&
        test.mode == NetworkTestMode.observe) {
      return '% 请求成功';
    }
    if (test.stage == NetworkTestStage.download ||
        test.stage == NetworkTestStage.upload ||
        test.stage == NetworkTestStage.completed) {
      return 'Mbps';
    }
    return test.busy ? '% 已完成' : 'Mbps';
  }

  Widget _buildHeroGauge(
    NetworkDiagnosticsController test, {
    required ColorScheme scheme,
    required IslePalette palette,
    required bool reduced,
    required bool wide,
    required double maxWidth,
  }) {
    final mineral = palette['brandBlue'];
    final sage = palette['brandSage'];
    final amber = palette['brandAmber'];
    return SizedBox(
      width: wide ? 260 : math.min(208, maxWidth - 32),
      height: wide ? 260 : 196,
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
            primary: mineral,
            secondary: sage,
            tertiary: amber,
            track: scheme.outlineVariant,
          ),
          child: child,
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 52),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  switch (test.stage) {
                    NetworkTestStage.completed =>
                      Icons.check_circle_outline_rounded,
                    NetworkTestStage.failed => Icons.error_outline_rounded,
                    NetworkTestStage.cancelled => Icons.pause_circle_outline,
                    _ => Icons.wifi_tethering_rounded,
                  },
                  size: 24,
                  color: test.stage == NetworkTestStage.failed
                      ? scheme.error
                      : mineral,
                ),
                const SizedBox(height: 12),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    _gaugePrimaryText(test),
                    style: Theme.of(context).textTheme.displayMedium?.copyWith(
                      fontSize: 44,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1.6,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _gaugeUnitText(test),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeroControls(
    NetworkDiagnosticsController test, {
    required ColorScheme scheme,
    required IslePalette palette,
    required bool wide,
  }) {
    final sage = palette['brandSage'];
    return Column(
      crossAxisAlignment: wide
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        Text(
          test.stage == NetworkTestStage.completed
              ? test.verdict
              : '连接测速',
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
          textAlign: wide ? TextAlign.start : TextAlign.center,
        ),
        const SizedBox(height: 6),
        Text(
          test.stageText,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined, size: 15, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
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
        const SizedBox(height: 18),
        SizedBox(
          width: wide ? 260 : double.infinity,
          child: LinearProgressIndicator(
            value: test.progress,
            minHeight: 5,
            borderRadius: BorderRadius.circular(10),
            color: sage,
            backgroundColor: scheme.outlineVariant.withValues(alpha: .5),
          ),
        ),
        if (test.busy) ...[
          const SizedBox(height: 6),
          Text(
            '检测步骤 ${test.completedSteps} / ${test.totalSteps}',
            textAlign: wide ? TextAlign.start : TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: wide ? 260 : double.infinity,
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
  }

  Widget _hero(NetworkDiagnosticsController test) {
    final scheme = Theme.of(context).colorScheme;
    final palette = IslePalette.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final reduced = IsleLayout.opaqueNavigation(context);
    final wideText = MediaQuery.textScalerOf(context).scale(14) < 19;
    final mineral = palette['brandBlue'];
    final amber = palette['brandAmber'];

    return Container(
      decoration: BoxDecoration(
        borderRadius: IsleRadius.brHero,
        border: Border.all(
          color: IsleGlass.rimBorderColor(isDark),
          width: 1.0,
        ),
        gradient: reduced
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.alphaBlend(
                    mineral.withValues(alpha: isDark ? .12 : .06),
                    palette['cardTop'],
                  ),
                  palette['cardTop'],
                  Color.alphaBlend(
                    amber.withValues(alpha: isDark ? .09 : .04),
                    palette['cardBottom'],
                  ),
                ],
              ),
        color: reduced ? palette['cardTop'] : null,
        boxShadow: IsleShadows.raised(isDark),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 680 && wideText;
          if (test.stage == NetworkTestStage.failed) {
            return _buildFailedHeroContent(test, scheme: scheme, wide: wide);
          }
          final gauge = _buildHeroGauge(
            test,
            scheme: scheme,
            palette: palette,
            reduced: reduced,
            wide: wide,
            maxWidth: constraints.maxWidth,
          );
          final controls = _buildHeroControls(
            test,
            scheme: scheme,
            palette: palette,
            wide: wide,
          );
          return Padding(
            padding: EdgeInsets.all(wide ? 26 : 18),
            child: wide
                ? Row(
                    children: [
                      gauge,
                      const SizedBox(width: 26),
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
    margin: EdgeInsets.zero,
    tint: tint,
    radius: IsleRadius.card,
    padding: const EdgeInsets.all(15),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IsleSquircleBadge(icon: icon, color: tint, size: 30, iconSize: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label, style: Theme.of(context).textTheme.labelLarge),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
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
        if (detail.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    ),
  );

  Widget _metrics(NetworkDiagnosticsController test) {
    final palette = IslePalette.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns =
            constraints.maxWidth >= 780 &&
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
                ? ''
                : '${_value(test.downloadMbps! / 8)} MB/s',
          ),
          _metric(
            icon: Icons.north_rounded,
            tint: palette['brandSage'],
            label: '上传速度',
            value: test.uploadMbps == null
                ? test.stage == NetworkTestStage.failed
                      ? '未完成'
                      : '待测'
                : _value(test.uploadMbps),
            unit: test.uploadMbps == null ? '' : 'Mbps',
            detail: test.uploadMbps == null
                ? ''
                : '${_value(test.uploadMbps! / 8)} MB/s',
          ),
          _metric(
            icon: Icons.timer_outlined,
            tint: palette['brandAmber'],
            label: '平均延迟',
            value:
                test.averageLatency == null &&
                    test.stage == NetworkTestStage.failed
                ? '未完成'
                : _value(test.averageLatency),
            unit: test.averageLatency == null ? '' : 'ms',
            detail: '',
          ),
          _metric(
            icon: Icons.multiline_chart_rounded,
            tint: palette['brandViolet'],
            label: '延迟抖动',
            value: test.jitter == null && test.stage == NetworkTestStage.failed
                ? '未完成'
                : _value(test.jitter),
            unit: test.jitter == null ? '' : 'ms',
            detail: '',
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
    final palette = IslePalette.of(context);
    final mineral = palette['brandBlue'];
    return IsleSurface(
      margin: EdgeInsets.zero,
      radius: IsleRadius.card,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.show_chart_rounded, size: 21, color: mineral),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '稳定性趋势',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
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
            height: 112,
            width: double.infinity,
            child: CustomPaint(
              key: const ValueKey('networkTestLatencyChart'),
              painter: _LatencyLinePainter(
                test.latencyPoints,
                mineral,
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
                'Core 运行  ${test.coreUptimeText}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (test.restartHints > 0)
                Text(
                  '检测期间发现 ${test.restartHints} 次进程重启迹象',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: scheme.error),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    final mineral = palette['brandBlue'];
    return Scaffold(
      appBar: IsleAppBar(
        title: const Text('连接测速'),
        actions: [
          IsleHelpButton(
            title: '连接测速说明',
            accentColor: mineral,
            items: const [
              IsleHelpItem(
                title: '端到端真实链路检测',
                body: '测量当前手机或电脑与家里的轻屿 Mac 之间的实际吞吐、往返延迟与抖动（涵盖局域网直连或异地组网隧道），不等同于运营商公网宽带测速。',
              ),
              IsleHelpItem(
                title: '三种检测模式',
                body: '快速模式（约 8 MiB）适合日常排查，标准模式（约 32 MiB）测试峰值吞吐，持续观察模式（约 1 分钟）用于捕捉无线或远程链路的间歇抖动。',
              ),
            ],
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _test,
        builder: (context, _) => IsleListView(
          maxWidth: IsleLayout.workbenchMaxWidth,
          children: [
            IsleWorkbenchSplit(
              breakpoint: 980,
              primaryFlex: 7,
              secondaryFlex: 5,
              primary: _hero(_test),
              secondary: TailscaleStatusCard(api: widget.api),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: IsleSectionHeader(
                    title: '检测模式',
                    accentColor: mineral,
                  ),
                ),
                Text(switch (_test.mode) {
                  NetworkTestMode.quick => '约 8 MiB',
                  NetworkTestMode.standard => '约 32 MiB',
                  NetworkTestMode.observe => '约 1 分钟',
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
                    onSelected: _test.busy
                        ? null
                        : (_) => _test.selectMode(mode),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            IsleSectionHeader(title: '实时指标', accentColor: mineral),
            _metrics(_test),
            const SizedBox(height: 16),
            _latency(_test),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}
