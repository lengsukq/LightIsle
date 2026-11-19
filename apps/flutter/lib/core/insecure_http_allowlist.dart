import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-local allowlist of exact `http://host[:port]` origins that the user
/// has explicitly opted into for plaintext HTTP connections (for example FRP
/// HTTP tunnels or public IP/domain deployments without TLS).
///
/// Entries are matched strictly by canonical origin (`scheme + host + port`):
/// wildcards, paths, queries, credentials, and `https://` URLs are rejected.
class InsecureHttpAllowlist {
  InsecureHttpAllowlist({String preferencesKey = _defaultPreferencesKey})
    : _preferencesKey = preferencesKey;

  static const String _defaultPreferencesKey = 'lightisle.insecureHttpAllowlist';
  static const int maxEntries = 24;

  static final InsecureHttpAllowlist instance = InsecureHttpAllowlist();

  final String _preferencesKey;
  final Set<String> _origins = <String>{};
  bool _loaded = false;

  bool get loaded => _loaded;

  /// Unmodifiable snapshot of currently trusted exact `http://` origins.
  Set<String> get origins => Set<String>.unmodifiable(_origins);

  /// Normalizes [raw] to a canonical exact `http://` origin (`http://host` or
  /// `http://host:port` for non-default ports). Returns `null` if [raw] is not
  /// a valid exact `http://` origin or contains wildcards/paths/credentials.
  static String? normalizeOrigin(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null ||
        !parsed.isAbsolute ||
        parsed.scheme.toLowerCase() != 'http' ||
        parsed.host.isEmpty ||
        parsed.host.contains('*') ||
        parsed.userInfo.isNotEmpty ||
        parsed.hasQuery ||
        parsed.hasFragment ||
        (parsed.path.isNotEmpty && parsed.path != '/')) {
      return null;
    }
    final port = parsed.hasPort && parsed.port != 80 ? parsed.port : null;
    return Uri(
      scheme: 'http',
      host: parsed.host.toLowerCase(),
      port: port,
    ).origin;
  }

  /// Returns whether [host] is a loopback host (`localhost`, `127.0.0.1`, `::1`).
  static bool isLoopbackHost(String host) {
    final normalized = host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    if (normalized == 'localhost' || normalized.endsWith('.localhost')) {
      return true;
    }
    final address = InternetAddress.tryParse(normalized);
    return address?.isLoopback ?? false;
  }

  /// Returns whether [host] is a literal RFC1918 / link-local / ULA private IP.
  static bool isPrivateHost(String host) {
    final address = InternetAddress.tryParse(host);
    if (address == null) return false;
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      final first = bytes[0];
      final second = bytes[1];
      return first == 10 ||
          (first == 172 && second >= 16 && second <= 31) ||
          (first == 192 && second == 168) ||
          (first == 169 && second == 254);
    }
    if (address.type == InternetAddressType.IPv6) {
      final first = bytes[0];
      final second = bytes[1];
      return (first & 0xfe) == 0xfc ||
          (first == 0xfe && (second & 0xc0) == 0x80);
    }
    return false;
  }

  /// Returns `true` when [serverUrl] is a valid `http://` origin that is
  /// neither loopback nor a private LAN IP, and therefore requires an explicit
  /// allowlist entry before `LightIsleApi` will connect to it.
  static bool requiresAllowlist(String serverUrl) {
    final origin = normalizeOrigin(serverUrl);
    if (origin == null) return false;
    final host = Uri.parse(origin).host;
    return !isLoopbackHost(host) && !isPrivateHost(host);
  }

  bool contains(String serverUrl) {
    final origin = normalizeOrigin(serverUrl);
    return origin != null && _origins.contains(origin);
  }

  Future<Set<String>> load({SharedPreferences? preferences}) async {
    try {
      final prefs = preferences ?? await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_preferencesKey) ?? const <String>[];
      _origins
        ..clear()
        ..addAll(stored.map(normalizeOrigin).whereType<String>().take(maxEntries));
      _loaded = true;
    } catch (_) {
      // Allow tests or headless environments without SharedPreferences plugin
      // to keep running using whatever in-memory entries are configured.
    }
    return origins;
  }

  Future<Set<String>> add(
    String serverUrl, {
    SharedPreferences? preferences,
  }) async {
    final origin = normalizeOrigin(serverUrl);
    if (origin == null) {
      throw ArgumentError('白名单仅支持完整的 http://主机[:端口] 地址，不支持通配符或路径。');
    }
    if (!requiresAllowlist(origin)) {
      throw ArgumentError('本机或局域网私有 IP 地址无需加入公网明文 HTTP 白名单。');
    }
    if (!_origins.contains(origin) && _origins.length >= maxEntries) {
      throw StateError('明文 HTTP 白名单最多保存 $maxEntries 条地址，请先移除不需要的条目。');
    }
    _origins.add(origin);
    _loaded = true;
    await _persist(preferences: preferences);
    return origins;
  }

  Future<Set<String>> remove(
    String serverUrl, {
    SharedPreferences? preferences,
  }) async {
    final origin = normalizeOrigin(serverUrl);
    if (origin == null) return origins;
    if (_origins.remove(origin)) {
      await _persist(preferences: preferences);
    }
    return origins;
  }

  Future<void> clear({SharedPreferences? preferences}) async {
    _origins.clear();
    _loaded = true;
    try {
      final prefs = preferences ?? await SharedPreferences.getInstance();
      await prefs.remove(_preferencesKey);
    } catch (_) {
      // Best-effort cleanup in environments without SharedPreferences plugin.
    }
  }

  Future<void> _persist({SharedPreferences? preferences}) async {
    try {
      final prefs = preferences ?? await SharedPreferences.getInstance();
      final sorted = _origins.toList()..sort();
      await prefs.setStringList(_preferencesKey, sorted);
    } catch (_) {
      // Preserve in-memory allowlist even if persistence is unavailable.
    }
  }

  @visibleForTesting
  void resetForTesting([Iterable<String> initialOrigins = const <String>[]]) {
    _origins
      ..clear()
      ..addAll(initialOrigins.map(normalizeOrigin).whereType<String>());
    _loaded = true;
  }
}
