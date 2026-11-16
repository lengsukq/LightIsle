import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

import 'lightisle_api.dart';

enum HostEndpointTier { loopback, lan, tailscale, publicDomain }

/// One candidate connection URL bound to a [LoginHistoryEntry] host profile.
class HostEndpoint {
  const HostEndpoint({required this.url, this.label, this.certificateFingerprint});

  final String url;
  final String? label;
  final String? certificateFingerprint;

  String get normalizedUrl => LoginHistoryEntry.normalizeServer(url);
  String? get normalizedFingerprint =>
      LoginHistoryEntry.normalizeFingerprint(certificateFingerprint);
  bool get isHttps => normalizedUrl.startsWith('https://');
  String get probeKey =>
      LoginHistoryEntry.buildServerProbeKey(normalizedUrl, normalizedFingerprint);
  HostEndpointTier get tier => classifyUrl(normalizedUrl);

  String get defaultTierLabel => switch (tier) {
    HostEndpointTier.loopback => '本机回环',
    HostEndpointTier.lan => '局域网',
    HostEndpointTier.tailscale => 'Tailscale',
    HostEndpointTier.publicDomain => '公网域名',
  };

  String get displayLabel =>
      (label?.trim().isNotEmpty ?? false) ? label!.trim() : defaultTierLabel;

  static HostEndpointTier classifyUrl(String rawUrl) {
    final parsed = Uri.tryParse(rawUrl.trim());
    final host = (parsed?.host ?? '').trim().toLowerCase();
    if (host.isEmpty) return HostEndpointTier.publicDomain;
    if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
      return HostEndpointTier.loopback;
    }
    if (host.endsWith('.local')) {
      return HostEndpointTier.lan;
    }
    if (host.endsWith('.ts.net')) {
      return HostEndpointTier.tailscale;
    }
    final parts = host.split('.');
    if (parts.length == 4) {
      final octets = <int>[];
      for (final p in parts) {
        final v = int.tryParse(p);
        if (v == null || v < 0 || v > 255) {
          octets.clear();
          break;
        }
        octets.add(v);
      }
      if (octets.length == 4) {
        if (octets[0] == 127) return HostEndpointTier.loopback;
        if (octets[0] == 10 ||
            (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
            (octets[0] == 192 && octets[1] == 168) ||
            (octets[0] == 169 && octets[1] == 254)) {
          return HostEndpointTier.lan;
        }
        if (octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127) {
          return HostEndpointTier.tailscale;
        }
      }
    }
    return HostEndpointTier.publicDomain;
  }

  HostEndpoint copyWith({
    String? url,
    String? label,
    bool clearLabel = false,
    String? certificateFingerprint,
    bool clearFingerprint = false,
  }) => HostEndpoint(
    url: url != null ? LoginHistoryEntry.normalizeServer(url) : normalizedUrl,
    label: clearLabel ? null : (label?.trim() ?? this.label),
    certificateFingerprint: clearFingerprint
        ? null
        : (certificateFingerprint != null
              ? LoginHistoryEntry.normalizeFingerprint(certificateFingerprint)
              : normalizedFingerprint),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'url': normalizedUrl,
    if (label != null && label!.trim().isNotEmpty) 'label': label!.trim(),
    if (normalizedFingerprint != null)
      'certificateFingerprint': normalizedFingerprint,
  };

  factory HostEndpoint.fromJson(Map<String, dynamic> json) {
    final rawUrl = json['url'];
    final normalized = rawUrl is String
        ? LoginHistoryEntry.normalizeServer(rawUrl)
        : '';
    if (normalized.isEmpty) throw const FormatException('主机候选地址格式无效。');
    final rawLabel = json['label'];
    return HostEndpoint(
      url: normalized,
      label: rawLabel is String && rawLabel.trim().isNotEmpty ? rawLabel.trim() : null,
      certificateFingerprint: LoginHistoryEntry.normalizeFingerprint(
        json['certificateFingerprint'] is String ? json['certificateFingerprint'] as String : null,
      ),
    );
  }
}

/// Saved host profile + credentials supporting optional multi-address selection.
class LoginHistoryEntry {
  const LoginHistoryEntry({
    required this.server,
    required this.username,
    required this.password,
    required this.updatedAt,
    this.role,
    this.certificateFingerprint,
    this.hostLabel,
    this.autoSelectEndpoint = true,
    this.endpoints = const <HostEndpoint>[],
  });

  static const int maxEndpointsPerHost = 6;

  final String server;
  final String username;
  final String password;
  final String? role;
  final String? certificateFingerprint;
  final int updatedAt;
  final String? hostLabel;
  final bool autoSelectEndpoint;
  final List<HostEndpoint> endpoints;

  /// Expands shorthand input (e.g. `192.168.1.100`) and normalizes to canonical origin.
  static String normalizeUserInputServer(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final withScheme =
        (trimmed.startsWith('http://') || trimmed.startsWith('https://'))
        ? trimmed
        : (RegExp(r'^(\[[^\]]+\]|[^/:]+)(:\d+|/)').hasMatch(trimmed)
              ? 'http://$trimmed'
              : 'http://$trimmed:16666');
    return normalizeServer(withScheme);
  }

  /// Canonical origin (lowercase scheme + host + optional explicit port).
  static String normalizeServer(String raw) {
    final trimmed = raw.trim();
    final parsed = Uri.tryParse(trimmed);
    if (parsed != null &&
        parsed.isAbsolute &&
        (parsed.scheme == 'http' || parsed.scheme == 'https') &&
        parsed.host.isNotEmpty) {
      return Uri(
        scheme: parsed.scheme.toLowerCase(),
        host: parsed.host.toLowerCase(),
        port: parsed.hasPort ? parsed.port : null,
      ).origin;
    }
    return trimmed.replaceAll(RegExp(r'/+$'), '').toLowerCase();
  }

  static String? normalizeFingerprint(String? raw) {
    if (raw == null) return null;
    final cleaned = raw.replaceAll(RegExp(r'[:\s]'), '').toLowerCase();
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(cleaned) ? cleaned : null;
  }

  /// Unique key combining normalized primary server origin and case-insensitive username.
  static String buildKey(String server, String username) =>
      '${normalizeServer(server)}|${username.trim().toLowerCase()}';

  /// Deduplication key for probing the same server + TLS pin only once.
  static String buildServerProbeKey(
    String server, [
    String? certificateFingerprint,
  ]) =>
      '${normalizeServer(server)}|${normalizeFingerprint(certificateFingerprint) ?? ''}';

  String get key => buildKey(server, username);

  String get serverProbeKey =>
      buildServerProbeKey(server, certificateFingerprint);

  bool get isHttps => server.toLowerCase().startsWith('https://');

  bool get isAdmin => role == 'admin';

  String get displayHostName {
    final custom = hostLabel?.trim() ?? '';
    if (custom.isNotEmpty) return custom;
    final parsed = Uri.tryParse(server);
    return (parsed != null && parsed.host.isNotEmpty) ? parsed.host : server;
  }

  /// Deduplicated candidate endpoints with primary [server] guaranteed first.
  List<HostEndpoint> get effectiveEndpoints {
    final primaryUrl = normalizeServer(server);
    final primaryPin = normalizeFingerprint(certificateFingerprint);
    final byUrl = <String, HostEndpoint>{};
    for (final ep in endpoints) {
      final norm = ep.normalizedUrl;
      if (norm.isEmpty) continue;
      byUrl.putIfAbsent(norm, () => ep.copyWith(url: norm));
    }
    final existingPrimary = byUrl.remove(primaryUrl);
    final primaryEndpoint = HostEndpoint(
      url: primaryUrl,
      label: existingPrimary?.label,
      certificateFingerprint:
          primaryPin ?? existingPrimary?.normalizedFingerprint,
    );
    return List<HostEndpoint>.unmodifiable(<HostEndpoint>[
      if (primaryUrl.isNotEmpty) primaryEndpoint,
      ...byUrl.values.take(maxEndpointsPerHost - 1),
    ]);
  }

  bool get hasMultipleEndpoints => effectiveEndpoints.length > 1;

  bool ownsServer(String candidateServer) {
    final target = normalizeServer(candidateServer);
    if (target.isEmpty) return false;
    return effectiveEndpoints.any((ep) => ep.normalizedUrl == target);
  }

  HostEndpoint endpointFor(String candidateServer) {
    final target = normalizeServer(candidateServer);
    for (final ep in effectiveEndpoints) {
      if (ep.normalizedUrl == target) return ep;
    }
    return HostEndpoint(url: target);
  }

  /// Picks the best endpoint from already-collected [latencies].
  /// When [autoSelectEndpoint] is false (turned off by user), strictly returns
  /// the fixed primary endpoint without switching routes.
  HostEndpoint selectPreferredEndpoint(
    Map<String, ServerLatencyResult> latencies,
  ) {
    final candidates = effectiveEndpoints;
    if (candidates.isEmpty) {
      return HostEndpoint(
        url: normalizeServer(server),
        certificateFingerprint: normalizeFingerprint(certificateFingerprint),
      );
    }
    if (!autoSelectEndpoint || candidates.length == 1) {
      return candidates.first;
    }
    final online = <HostEndpoint>[
      for (final ep in candidates)
        if (latencies[ep.probeKey]?.state == ServerLatencyState.online) ep,
    ];
    if (online.isEmpty) return candidates.first;
    online.sort((a, b) {
      final tierCmp = a.tier.index.compareTo(b.tier.index);
      if (tierCmp != 0) return tierCmp;
      final aMs = latencies[a.probeKey]?.latencyMs ?? 999999;
      final bMs = latencies[b.probeKey]?.latencyMs ?? 999999;
      return aMs.compareTo(bMs);
    });
    return online.first;
  }

  /// Probes candidate addresses concurrently when [autoSelectEndpoint] is true
  /// and multiple addresses exist; returns the fixed primary address immediately
  /// when [autoSelectEndpoint] is turned off.
  Future<HostEndpoint> resolveConnectEndpoint(
    ServerLatencyProber prober, {
    Map<String, ServerLatencyResult>? latencyCache,
  }) async {
    final candidates = effectiveEndpoints;
    if (candidates.isEmpty) {
      return HostEndpoint(
        url: normalizeServer(server),
        certificateFingerprint: normalizeFingerprint(certificateFingerprint),
      );
    }
    if (!autoSelectEndpoint || candidates.length == 1) {
      return candidates.first;
    }
    final results = <String, ServerLatencyResult>{};
    await Future.wait(
      candidates.map((ep) async {
        final res = await prober(
          ep.normalizedUrl,
          certificateFingerprint: ep.normalizedFingerprint,
        );
        results[ep.probeKey] = res;
      }),
    );
    latencyCache?.addAll(results);
    return selectPreferredEndpoint(results);
  }

  LoginHistoryEntry copyWith({
    String? server,
    String? username,
    String? password,
    String? role,
    String? certificateFingerprint,
    bool clearCertificateFingerprint = false,
    int? updatedAt,
    String? hostLabel,
    bool clearHostLabel = false,
    bool? autoSelectEndpoint,
    List<HostEndpoint>? endpoints,
  }) => LoginHistoryEntry(
    server: server != null ? normalizeServer(server) : this.server,
    username: username?.trim() ?? this.username,
    password: password ?? this.password,
    role: role ?? this.role,
    certificateFingerprint: clearCertificateFingerprint
        ? null
        : (certificateFingerprint != null
              ? normalizeFingerprint(certificateFingerprint)
              : this.certificateFingerprint),
    updatedAt: updatedAt ?? this.updatedAt,
    hostLabel: clearHostLabel ? null : (hostLabel?.trim() ?? this.hostLabel),
    autoSelectEndpoint: autoSelectEndpoint ?? this.autoSelectEndpoint,
    endpoints: endpoints ?? this.endpoints,
  );

  Map<String, dynamic> toJson() {
    final canonicalEndpoints = effectiveEndpoints;
    return <String, dynamic>{
      'server': normalizeServer(server),
      'username': username.trim(),
      'password': password,
      if (role != null && role!.isNotEmpty) 'role': role,
      if (normalizeFingerprint(certificateFingerprint) != null)
        'certificateFingerprint': normalizeFingerprint(certificateFingerprint),
      if (hostLabel != null && hostLabel!.trim().isNotEmpty)
        'hostLabel': hostLabel!.trim(),
      if (!autoSelectEndpoint) 'autoSelectEndpoint': false,
      if (canonicalEndpoints.length > 1 ||
          (canonicalEndpoints.length == 1 &&
              canonicalEndpoints.first.label != null))
        'endpoints': canonicalEndpoints
            .map((ep) => ep.toJson())
            .toList(growable: false),
      'updatedAt': updatedAt,
    };
  }

  factory LoginHistoryEntry.fromJson(Map<String, dynamic> json) {
    final rawServer = json['server'];
    final rawUsername = json['username'];
    final rawPassword = json['password'];
    final rawUpdated = json['updatedAt'];
    if (rawServer is! String ||
        rawServer.trim().isEmpty ||
        rawUsername is! String ||
        rawUsername.trim().isEmpty ||
        rawPassword is! String ||
        rawPassword.isEmpty ||
        rawPassword.length > 256) {
      throw const FormatException('登录历史条目格式无效。');
    }
    final parsedEndpoints = <HostEndpoint>[];
    if (json['endpoints'] is List) {
      for (final rawEp in json['endpoints'] as List) {
        if (rawEp is Map) {
          try {
            parsedEndpoints.add(
              HostEndpoint.fromJson(Map<String, dynamic>.from(rawEp)),
            );
          } on FormatException {
            // Ignore malformed candidate endpoint without losing the account.
          }
        }
      }
    }
    final rawLabel = json['hostLabel'];
    return LoginHistoryEntry(
      server: normalizeServer(rawServer),
      username: rawUsername.trim(),
      password: rawPassword,
      role: json['role'] is String ? json['role'] as String : null,
      certificateFingerprint: normalizeFingerprint(
        json['certificateFingerprint'] is String
            ? json['certificateFingerprint'] as String
            : null,
      ),
      hostLabel: rawLabel is String && rawLabel.trim().isNotEmpty
          ? rawLabel.trim()
          : null,
      autoSelectEndpoint: json['autoSelectEndpoint'] is bool
          ? json['autoSelectEndpoint'] as bool
          : true,
      endpoints: List<HostEndpoint>.unmodifiable(parsedEndpoints),
      updatedAt: rawUpdated is num && rawUpdated.toInt() > 0
          ? rawUpdated.toInt()
          : 0,
    );
  }
}

/// Device-local vault for remembered host profiles + credentials.
class LoginHistoryStore {
  LoginHistoryStore({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('lightisle/session-vault');

  static const int maxEntries = 12;
  static const int _maxPayloadBytes = 8192;

  final MethodChannel _channel;
  Future<void> _tail = Future<void>.value();

  Future<T> _serialize<T>(Future<T> Function() operation) async {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    try {
      await previous;
      return await operation();
    } finally {
      done.complete();
    }
  }

  Future<List<LoginHistoryEntry>> _readInternal() async {
    String? raw;
    try {
      raw = await _channel.invokeMethod<String>('history.read');
    } on MissingPluginException {
      return const <LoginHistoryEntry>[];
    }
    if (raw == null || raw.isEmpty) return const <LoginHistoryEntry>[];
    if (raw.length > _maxPayloadBytes) {
      throw const FormatException('保存的登录历史数据过大或已损坏。');
    }
    final decoded = jsonDecode(raw);
    final List<dynamic> rawEntries;
    if (decoded is Map && decoded['entries'] is List) {
      rawEntries = decoded['entries'] as List<dynamic>;
    } else if (decoded is List) {
      rawEntries = decoded;
    } else {
      throw const FormatException('保存的登录历史格式无效。');
    }

    final seenKeys = <String>{};
    final parsed = <LoginHistoryEntry>[];
    for (final item in rawEntries) {
      if (item is! Map) continue;
      try {
        final entry = LoginHistoryEntry.fromJson(
          Map<String, dynamic>.from(item),
        );
        if (seenKeys.add(entry.key)) {
          parsed.add(entry);
        }
      } on FormatException {
        // Skip individual malformed items while preserving valid history.
      }
    }
    parsed.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List<LoginHistoryEntry>.unmodifiable(parsed.take(maxEntries));
  }

  Future<void> _writeInternal(List<LoginHistoryEntry> entries) async {
    if (entries.isEmpty) {
      try {
        await _channel.invokeMethod<void>('history.clear');
      } on MissingPluginException {
        // No-op in headless widget tests without a registered channel.
      }
      return;
    }
    final working = List<LoginHistoryEntry>.from(entries.take(maxEntries));
    while (working.isNotEmpty) {
      final encoded = jsonEncode(<String, dynamic>{
        'version': 2,
        'entries': working.map((e) => e.toJson()).toList(growable: false),
      });
      if (utf8.encode(encoded).length <= _maxPayloadBytes) {
        try {
          await _channel.invokeMethod<void>('history.write', <String, dynamic>{
            'value': encoded,
          });
        } on MissingPluginException {
          // No-op in headless widget tests without a registered channel.
        }
        return;
      }
      working.removeLast();
    }
    throw const FormatException('单条登录历史数据超出安全存储上限。');
  }

  Future<List<LoginHistoryEntry>> readAll() => _serialize(_readInternal);

  /// Inserts or updates a history entry. If an existing host profile for the
  /// same username already owns `entry.server` among its configured endpoints,
  /// updates that host profile in place without creating a duplicate entry.
  Future<List<LoginHistoryEntry>> upsert(
    LoginHistoryEntry entry,
  ) => _serialize(() async {
    final normalizedServer = LoginHistoryEntry.normalizeServer(entry.server);
    final normalizedUser = entry.username.trim();
    if (normalizedServer.isEmpty ||
        normalizedUser.isEmpty ||
        entry.password.isEmpty ||
        entry.password.length > 256) {
      throw ArgumentError('登录历史必须包含有效的服务器地址、用户名和密码。');
    }
    final existing = await _readInternal();
    final lowerUser = normalizedUser.toLowerCase();
    final normalizedPin = LoginHistoryEntry.normalizeFingerprint(
      entry.certificateFingerprint,
    );
    final nowTs = entry.updatedAt > 0
        ? entry.updatedAt
        : DateTime.now().millisecondsSinceEpoch;

    final matchIdx = existing.indexWhere(
      (item) =>
          item.username.toLowerCase() == lowerUser &&
          item.ownsServer(normalizedServer),
    );

    final LoginHistoryEntry canonical;
    if (matchIdx >= 0 && entry.endpoints.isEmpty) {
      final matched = existing[matchIdx];
      final updatedEndpoints = matched.effectiveEndpoints
          .map((ep) {
            if (ep.normalizedUrl == normalizedServer && normalizedPin != null) {
              return ep.copyWith(certificateFingerprint: normalizedPin);
            }
            return ep;
          })
          .toList(growable: false);
      final primaryPin = matched.server == normalizedServer
          ? (normalizedPin ?? matched.certificateFingerprint)
          : matched.certificateFingerprint;
      canonical = LoginHistoryEntry(
        server: matched.server,
        username: normalizedUser,
        password: entry.password,
        role: entry.role ?? matched.role,
        certificateFingerprint: primaryPin,
        hostLabel: entry.hostLabel ?? matched.hostLabel,
        autoSelectEndpoint: matched.autoSelectEndpoint,
        endpoints: updatedEndpoints,
        updatedAt: nowTs,
      );
    } else {
      canonical = LoginHistoryEntry(
        server: normalizedServer,
        username: normalizedUser,
        password: entry.password,
        role: entry.role,
        certificateFingerprint: normalizedPin,
        hostLabel: entry.hostLabel,
        autoSelectEndpoint: entry.autoSelectEndpoint,
        endpoints: entry.endpoints,
        updatedAt: nowTs,
      );
    }

    final next = <LoginHistoryEntry>[
      canonical,
      for (var i = 0; i < existing.length; i++)
        if (i != matchIdx && existing[i].key != canonical.key) existing[i],
    ];
    final trimmed = List<LoginHistoryEntry>.unmodifiable(next.take(maxEntries));
    await _writeInternal(trimmed);
    return trimmed;
  });

  /// Replaces a host profile's multi-address list, primary address, label, and
  /// `autoSelectEndpoint` toggle atomically.
  Future<List<LoginHistoryEntry>> saveHostProfile({
    required String originalKey,
    required LoginHistoryEntry updatedProfile,
  }) => _serialize(() async {
    final normalizedPrimary = LoginHistoryEntry.normalizeServer(
      updatedProfile.server,
    );
    final normalizedUser = updatedProfile.username.trim();
    if (normalizedPrimary.isEmpty ||
        normalizedUser.isEmpty ||
        updatedProfile.password.isEmpty) {
      throw ArgumentError('主机配置必须保留有效的主地址与账号凭据。');
    }
    final existing = await _readInternal();
    final canonical = updatedProfile.copyWith(
      server: normalizedPrimary,
      username: normalizedUser,
      endpoints: updatedProfile.effectiveEndpoints,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    final replaced = <LoginHistoryEntry>[];
    var inserted = false;
    for (final item in existing) {
      if (item.key == originalKey || item.key == canonical.key) {
        if (!inserted) {
          replaced.add(canonical);
          inserted = true;
        }
      } else {
        replaced.add(item);
      }
    }
    if (!inserted) {
      replaced.insert(0, canonical);
    }
    final trimmed = List<LoginHistoryEntry>.unmodifiable(
      replaced.take(maxEntries),
    );
    await _writeInternal(trimmed);
    return trimmed;
  });

  /// Updates the stored password if an entry for `server + username` (or any
  /// endpoint belonging to that host profile) exists.
  Future<List<LoginHistoryEntry>> updatePassword(
    String server,
    String username,
    String newPassword,
  ) => _serialize(() async {
    final normalizedServer = LoginHistoryEntry.normalizeServer(server);
    final lowerUser = username.trim().toLowerCase();
    final existing = await _readInternal();
    final index = existing.indexWhere(
      (item) =>
          item.username.toLowerCase() == lowerUser &&
          item.ownsServer(normalizedServer),
    );
    if (index < 0 || newPassword.isEmpty || newPassword.length > 256) {
      return existing;
    }
    final updated = existing[index].copyWith(
      password: newPassword,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    final next = <LoginHistoryEntry>[
      updated,
      for (var i = 0; i < existing.length; i++)
        if (i != index) existing[i],
    ];
    final trimmed = List<LoginHistoryEntry>.unmodifiable(next.take(maxEntries));
    await _writeInternal(trimmed);
    return trimmed;
  });

  /// Removes a single history entry by `server + username` key (or owned server).
  Future<List<LoginHistoryEntry>> remove(String server, String username) =>
      _serialize(() async {
        final targetKey = LoginHistoryEntry.buildKey(server, username);
        final normalizedServer = LoginHistoryEntry.normalizeServer(server);
        final lowerUser = username.trim().toLowerCase();
        final existing = await _readInternal();
        final next = List<LoginHistoryEntry>.unmodifiable(
          existing.where(
            (item) =>
                item.key != targetKey &&
                !(item.username.toLowerCase() == lowerUser &&
                    item.ownsServer(normalizedServer)),
          ),
        );
        await _writeInternal(next);
        return next;
      });

  Future<void> clear() => _serialize(() async {
    try {
      await _channel.invokeMethod<void>('history.clear');
    } on MissingPluginException {
      // No-op in headless widget tests.
    }
  });
}

enum ServerLatencyState { probing, online, offline, certError, invalid }

class ServerLatencyResult {
  const ServerLatencyResult._({
    required this.state,
    required this.message,
    this.latencyMs,
  });

  const ServerLatencyResult.probing()
    : this._(state: ServerLatencyState.probing, message: '测速中…');

  factory ServerLatencyResult.online(int latencyMs) {
    final clamped = max(1, latencyMs);
    return ServerLatencyResult._(
      state: ServerLatencyState.online,
      latencyMs: clamped,
      message: '$clamped ms',
    );
  }

  const ServerLatencyResult.offline([String message = '离线 / 超时'])
    : this._(state: ServerLatencyState.offline, message: message);

  const ServerLatencyResult.certError([String message = '需核对证书指纹'])
    : this._(state: ServerLatencyState.certError, message: message);

  const ServerLatencyResult.invalid([String message = '地址格式无效'])
    : this._(state: ServerLatencyState.invalid, message: message);

  final ServerLatencyState state;
  final int? latencyMs;
  final String message;
}

typedef ServerLatencyProber = Future<ServerLatencyResult> Function(
  String serverUrl, {
  String? certificateFingerprint,
});

/// Measures real HTTP round-trip latency to a LightIsle server/domain before
/// switching or logging in. Performs a connection warm-up first so TLS/TCP
/// handshake overhead is not misreported as steady-state RTT.
Future<ServerLatencyResult> probeServerLatency(
  String serverUrl, {
  String? certificateFingerprint,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final trimmed = serverUrl.trim();
  if (trimmed.isEmpty) {
    return const ServerLatencyResult.invalid('请输入服务器地址');
  }
  LightIsleApi? api;
  try {
    final pin = LoginHistoryEntry.normalizeFingerprint(certificateFingerprint);
    api = LightIsleApi(
      trimmed,
      allowInsecureHttp: true,
      certificateFingerprint: pin,
      requestTimeout: timeout,
    );
    final firstWatch = Stopwatch()..start();
    await api.get('/api/v2/auth/status').timeout(timeout);
    firstWatch.stop();
    final firstMs = max(1, firstWatch.elapsedMilliseconds);

    // Measure a second request over the warm keep-alive socket for true HTTP RTT.
    try {
      final rttWatch = Stopwatch()..start();
      await api.get('/api/v2/auth/status').timeout(timeout);
      rttWatch.stop();
      return ServerLatencyResult.online(max(1, rttWatch.elapsedMilliseconds));
    } catch (_) {
      return ServerLatencyResult.online(firstMs);
    }
  } on ArgumentError catch (error) {
    return ServerLatencyResult.invalid(
      error.message?.toString() ?? '服务器地址格式无效',
    );
  } on TimeoutException {
    return const ServerLatencyResult.offline('连接超时');
  } on LightIsleApiException catch (error) {
    if (error.code == 'certificate_untrusted' ||
        error.code == 'certificate_mismatch') {
      return const ServerLatencyResult.certError('HTTPS 证书需核对');
    }
    if (error.code == 'network_timeout') {
      return const ServerLatencyResult.offline('连接超时');
    }
    return const ServerLatencyResult.offline('无法连接');
  } catch (_) {
    return const ServerLatencyResult.offline('无法连接');
  } finally {
    api?.close();
  }
}
