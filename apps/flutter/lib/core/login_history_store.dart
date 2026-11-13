import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

import 'lightisle_api.dart';

/// One saved server + account + password record, uniquely keyed by normalized
/// `server|username` and stored only inside the OS Keychain / Android Keystore.
class LoginHistoryEntry {
  const LoginHistoryEntry({
    required this.server,
    required this.username,
    required this.password,
    required this.updatedAt,
    this.role,
    this.certificateFingerprint,
  });

  final String server;
  final String username;
  final String password;
  final String? role;
  final String? certificateFingerprint;
  final int updatedAt;

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

  /// Unique key combining normalized server origin and case-insensitive username.
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

  LoginHistoryEntry copyWith({
    String? server,
    String? username,
    String? password,
    String? role,
    String? certificateFingerprint,
    int? updatedAt,
  }) => LoginHistoryEntry(
    server: server != null ? normalizeServer(server) : this.server,
    username: username?.trim() ?? this.username,
    password: password ?? this.password,
    role: role ?? this.role,
    certificateFingerprint: certificateFingerprint != null
        ? normalizeFingerprint(certificateFingerprint)
        : this.certificateFingerprint,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'server': normalizeServer(server),
    'username': username.trim(),
    'password': password,
    if (role != null && role!.isNotEmpty) 'role': role,
    if (normalizeFingerprint(certificateFingerprint) != null)
      'certificateFingerprint': normalizeFingerprint(certificateFingerprint),
    'updatedAt': updatedAt,
  };

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
      updatedAt: rawUpdated is num && rawUpdated.toInt() > 0
          ? rawUpdated.toInt()
          : 0,
    );
  }
}

/// Device-local vault for remembered `server + username + password` accounts.
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
        'version': 1,
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

  /// Inserts or updates a history entry keyed by normalized `server + username`
  /// and moves it to the top of the list.
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
    final canonical = LoginHistoryEntry(
      server: normalizedServer,
      username: normalizedUser,
      password: entry.password,
      role: entry.role,
      certificateFingerprint: LoginHistoryEntry.normalizeFingerprint(
        entry.certificateFingerprint,
      ),
      updatedAt: entry.updatedAt > 0
          ? entry.updatedAt
          : DateTime.now().millisecondsSinceEpoch,
    );
    final next = <LoginHistoryEntry>[
      canonical,
      for (final item in existing)
        if (item.key != canonical.key) item,
    ];
    final trimmed = List<LoginHistoryEntry>.unmodifiable(next.take(maxEntries));
    await _writeInternal(trimmed);
    return trimmed;
  });

  /// Updates the stored password if an entry for `server + username` already
  /// exists (e.g. after the user changes their password in settings).
  Future<List<LoginHistoryEntry>> updatePassword(
    String server,
    String username,
    String newPassword,
  ) => _serialize(() async {
    final targetKey = LoginHistoryEntry.buildKey(server, username);
    final existing = await _readInternal();
    final index = existing.indexWhere((item) => item.key == targetKey);
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

  /// Removes a single history entry by `server + username` key.
  Future<List<LoginHistoryEntry>> remove(String server, String username) =>
      _serialize(() async {
        final targetKey = LoginHistoryEntry.buildKey(server, username);
        final existing = await _readInternal();
        final next = List<LoginHistoryEntry>.unmodifiable(
          existing.where((item) => item.key != targetKey),
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
