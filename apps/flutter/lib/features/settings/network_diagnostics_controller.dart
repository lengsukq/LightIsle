import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';

/// Keep the network experiment predictable, small and explicitly opt-in.
/// Every probe goes to the authenticated LightIsle server, not a third party.
enum NetworkTestMode {
  quick,
  standard,
  observe;

  String get label => switch (this) {
    quick => '快速检测',
    standard => '完整测速',
    observe => '持续观察',
  };
  int get bytesPerTransfer => switch (this) {
    quick => 2 << 20,
    standard => 8 << 20,
    observe => 0,
  };
  int get transferRounds => this == observe ? 0 : 2;
  int get initialProbes => switch (this) {
    quick => 5,
    standard => 8,
    observe => 3,
  };
  int get stabilityProbes => switch (this) {
    quick => 8,
    standard => 14,
    observe => 30,
  };
  int get plannedTransferBytes => bytesPerTransfer * transferRounds * 2;
}

enum NetworkTestStage {
  idle,
  latency,
  download,
  upload,
  stability,
  completed,
  cancelled,
  failed,
}

class NetworkLatencyPoint {
  const NetworkLatencyPoint({
    required this.milliseconds,
    required this.stability,
  });
  final double? milliseconds;
  final bool stability;
  bool get success => milliseconds != null;
}

/// HTTP timing is an application-layer round trip, NOT ICMP ping/packet loss.
/// The server generates and discards the test data in memory.
class NetworkDiagnosticsController extends ChangeNotifier {
  NetworkDiagnosticsController({
    required this.api,
    this.probeInterval = const Duration(milliseconds: 260),
    this.observationInterval = const Duration(seconds: 2),
  });

  final LightIsleApi api;
  final Duration probeInterval;

  /// 30 probes over approximately one minute; tests may set this to zero.
  final Duration observationInterval;
  final List<NetworkLatencyPoint> _latency = [];
  final List<double> _downSamples = [];
  final List<double> _upSamples = [];

  NetworkTestMode mode = NetworkTestMode.quick;
  NetworkTestStage stage = NetworkTestStage.idle;
  double progress = 0;
  double transferProgress = 0;
  double? downloadMbps;
  double? uploadMbps;
  int? coreUptimeSeconds;
  int restartHints = 0;
  int? _previousCoreUptime;
  String? error;
  DateTime? finishedAt;
  int completedSteps = 0;
  int totalSteps = 0;
  int _generation = 0;
  bool _disposed = false;
  LightIsleApi? _ownedClient;

  List<NetworkLatencyPoint> get latencyPoints => List.unmodifiable(_latency);
  List<double> get downloadSamples => List.unmodifiable(_downSamples);
  List<double> get uploadSamples => List.unmodifiable(_upSamples);
  bool get busy => switch (stage) {
    NetworkTestStage.latency ||
    NetworkTestStage.download ||
    NetworkTestStage.upload ||
    NetworkTestStage.stability => true,
    _ => false,
  };
  int get successfulRequests => _latency.where((p) => p.success).length;
  int get failedRequests => _latency.where((p) => !p.success).length;
  int get totalProbes => _latency.length;
  double? get averageLatency => _average(_validLatency);
  double? get p95Latency {
    final values = _validLatency..sort();
    if (values.isEmpty) return null;
    final index = ((values.length * .95).ceil() - 1).clamp(
      0,
      values.length - 1,
    );
    return values[index];
  }

  double? get jitter {
    var sum = 0.0;
    var pairs = 0;
    for (var i = 1; i < _latency.length; i++) {
      final current = _latency[i].milliseconds;
      final previous = _latency[i - 1].milliseconds;
      if (current == null || previous == null) continue;
      sum += (current - previous).abs();
      pairs++;
    }
    return pairs == 0 ? null : sum / pairs;
  }

  double? get failureRate =>
      totalProbes == 0 ? null : failedRequests * 100 / totalProbes;
  double? get successRate =>
      totalProbes == 0 ? null : successfulRequests * 100 / totalProbes;
  int get longestFailureStreak {
    var longest = 0;
    var current = 0;
    for (final point in _latency) {
      current = point.success ? 0 : current + 1;
      if (current > longest) longest = current;
    }
    return longest;
  }

  String get coreUptimeText {
    final seconds = coreUptimeSeconds;
    if (seconds == null) return '未提供';
    if (seconds >= 86400) {
      return '${seconds ~/ 86400} 天 ${(seconds % 86400) ~/ 3600} 小时';
    }
    if (seconds >= 3600) {
      return '${seconds ~/ 3600} 小时 ${(seconds % 3600) ~/ 60} 分钟';
    }
    if (seconds >= 60) return '${seconds ~/ 60} 分钟';
    return '$seconds 秒';
  }

  void _observeCore(Map<String, dynamic> response) {
    final raw = response['coreUptimeSeconds'];
    if (raw is! num || !raw.isFinite || raw < 0 || raw > 8640000000) return;
    final seconds = raw.toInt();
    if (_previousCoreUptime != null && seconds + 1 < _previousCoreUptime!) {
      restartHints++;
    }
    _previousCoreUptime = seconds;
    coreUptimeSeconds = seconds;
  }

  List<double> get _validLatency =>
      _latency.where((p) => p.success).map((p) => p.milliseconds!).toList();

  static double? _average(List<double> values) =>
      values.isEmpty ? null : values.reduce((a, b) => a + b) / values.length;

  String get stageText => switch (stage) {
    NetworkTestStage.idle => '准备就绪',
    NetworkTestStage.latency => '正在测量连接延迟',
    NetworkTestStage.download => '正在测量下载速度',
    NetworkTestStage.upload => '正在测量上传速度',
    NetworkTestStage.stability => '正在观察连续连接稳定性',
    NetworkTestStage.completed => '检测已完成',
    NetworkTestStage.cancelled => '已停止检测',
    NetworkTestStage.failed => '检测中断',
  };

  String get verdict {
    if (stage == NetworkTestStage.failed) return '检测未完成';
    if (stage != NetworkTestStage.completed) return '尚未生成评估';
    final loss = failureRate ?? 100;
    final latency = averageLatency ?? double.infinity;
    final variance = jitter ?? double.infinity;
    if (loss > 10 || variance > 45 || latency > 180) return '连接波动较明显';
    if (loss > 0 || variance > 18 || latency > 75) return '连接基本稳定';
    return '连接稳定';
  }

  void selectMode(NetworkTestMode value) {
    if (busy || _disposed || value == mode) return;
    mode = value;
    notifyListeners();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _step(int generation) {
    if (generation != _generation || _disposed) return;
    completedSteps++;
    progress = (completedSteps / math.max(totalSteps, 1)).clamp(0, 1);
    transferProgress = 0;
    _notify();
  }

  bool _valid(int generation) => !_disposed && _generation == generation;

  Future<void> start() async {
    if (_disposed || busy) return;
    final generation = ++_generation;
    _latency.clear();
    _downSamples.clear();
    _upSamples.clear();
    downloadMbps = null;
    uploadMbps = null;
    coreUptimeSeconds = null;
    _previousCoreUptime = null;
    restartHints = 0;
    error = null;
    finishedAt = null;
    progress = 0;
    transferProgress = 0;
    completedSteps = 0;
    totalSteps =
        mode.initialProbes + mode.stabilityProbes + mode.transferRounds * 2;
    stage = NetworkTestStage.latency;
    _notify();

    final snapshot = api.sessionSnapshot;
    final client = snapshot == null
        ? api
        : (_ownedClient = LightIsleApi.fromSessionSnapshot(snapshot));
    try {
      // Warm the TCP/TLS session so the first handshake is not mistaken for
      // steady-state latency. Still fail clearly when the server is offline.
      final warmup = await client.get('/api/v2/network-test/ping');
      if (!_valid(generation)) return;
      if (warmup['ok'] != true) {
        throw const FormatException('服务器未返回有效的测速响应。');
      }
      _observeCore(warmup);
      for (var i = 0; i < mode.initialProbes; i++) {
        await _probe(client, generation, stability: false);
        if (!_valid(generation)) return;
      }
      if (successfulRequests == 0) {
        throw const FormatException('延迟检测全部失败，请检查 NAS 连接。');
      }

      if (mode.transferRounds > 0) {
        stage = NetworkTestStage.download;
        _notify();
        var downBytes = 0;
        var downSeconds = 0.0;
        for (var i = 0; i < mode.transferRounds; i++) {
          if (!_valid(generation)) return;
          final stopwatch = Stopwatch()..start();
          var lastRefresh = DateTime.now().millisecondsSinceEpoch;
          final bytes = await client.networkTestDownload(
            mode.bytesPerTransfer,
            onProgress: (received, total) {
              final now = DateTime.now().millisecondsSinceEpoch;
              if (!_valid(generation) ||
                  (received != total && now - lastRefresh < 65)) {
                return;
              }
              lastRefresh = now;
              transferProgress = total == 0 ? 0 : received / total;
              _notify();
            },
          );
          stopwatch.stop();
          if (!_valid(generation)) return;
          final duration = math.max(0.001, stopwatch.elapsedMicroseconds / 1e6);
          final sample = bytes * 8 / duration / 1e6;
          _downSamples.add(sample);
          downBytes += bytes;
          downSeconds += duration;
          downloadMbps = downBytes * 8 / downSeconds / 1e6;
          _step(generation);
        }

        stage = NetworkTestStage.upload;
        _notify();
        var upBytes = 0;
        var upSeconds = 0.0;
        for (var i = 0; i < mode.transferRounds; i++) {
          if (!_valid(generation)) return;
          final stopwatch = Stopwatch()..start();
          var lastRefresh = DateTime.now().millisecondsSinceEpoch;
          final bytes = await client.networkTestUpload(
            mode.bytesPerTransfer,
            onProgress: (sent, total) {
              final now = DateTime.now().millisecondsSinceEpoch;
              if (!_valid(generation) ||
                  (sent != total && now - lastRefresh < 65)) {
                return;
              }
              lastRefresh = now;
              transferProgress = total == 0 ? 0 : sent / total;
              _notify();
            },
          );
          stopwatch.stop();
          if (!_valid(generation)) return;
          final duration = math.max(0.001, stopwatch.elapsedMicroseconds / 1e6);
          final sample = bytes * 8 / duration / 1e6;
          _upSamples.add(sample);
          upBytes += bytes;
          upSeconds += duration;
          uploadMbps = upBytes * 8 / upSeconds / 1e6;
          _step(generation);
        }
      }

      stage = NetworkTestStage.stability;
      _notify();
      for (var i = 0; i < mode.stabilityProbes; i++) {
        if (!_valid(generation)) return;
        final interval = mode == NetworkTestMode.observe
            ? observationInterval
            : probeInterval;
        if (i > 0 && interval > Duration.zero) {
          await Future<void>.delayed(interval);
          if (!_valid(generation)) return;
        }
        await _probe(client, generation, stability: true);
      }
      if (!_valid(generation)) return;
      stage = NetworkTestStage.completed;
      progress = 1;
      finishedAt = DateTime.now();
      _notify();
    } catch (exception) {
      if (!_valid(generation)) return;
      error = exception is LightIsleApiException && exception.statusCode == 404
          ? '当前 NAS Core 不支持连接测速，请升级 Mac 端服务。'
          : userFacingError(exception);
      stage = NetworkTestStage.failed;
      _notify();
    } finally {
      if (!identical(client, api)) client.close();
      if (identical(_ownedClient, client)) _ownedClient = null;
    }
  }

  Future<void> _probe(
    LightIsleApi client,
    int generation, {
    required bool stability,
  }) async {
    if (!_valid(generation)) return;
    final stopwatch = Stopwatch()..start();
    double? time;
    try {
      final reply = await client.get('/api/v2/network-test/ping');
      if (reply['ok'] == true) {
        time = stopwatch.elapsedMicroseconds / 1000;
        _observeCore(reply);
      }
    } catch (_) {
      // The request failure is counted, but is not called ICMP packet loss.
    }
    stopwatch.stop();
    if (!_valid(generation)) return;
    _latency.add(NetworkLatencyPoint(milliseconds: time, stability: stability));
    _step(generation);
  }

  void stop() {
    if (!busy || _disposed) return;
    _generation++;
    _ownedClient?.close();
    _ownedClient = null;
    stage = NetworkTestStage.cancelled;
    _notify();
  }

  @override
  void dispose() {
    _generation++;
    _disposed = true;
    _ownedClient?.close();
    _ownedClient = null;
    super.dispose();
  }
}
