import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

const _discoveryTimeoutMs = 10000;
const _discoveryCallTimeout = Duration(seconds: 12);

class NasDiscoveryServer {
  const NasDiscoveryServer({required this.name, required this.address});

  final String name;
  final String address;
}

class NasDiscoveryException implements Exception {
  const NasDiscoveryException(this.message);

  final String message;

  @override
  String toString() => message;
}

class NasDiscoveryCancelled implements Exception {
  const NasDiscoveryCancelled();
}

/// Native Android/iOS Bonjour adapters return candidates only; discovery never
/// logs in or marks a server certificate as trusted.
class NasDiscoveryService {
  NasDiscoveryService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('lightisle/discovery');

  final MethodChannel _channel;
  String? _activeRequestId;

  Future<List<NasDiscoveryServer>> discover() async {
    if (_activeRequestId != null) {
      throw StateError('A NAS discovery request is already active.');
    }

    final requestId = _newRequestId();
    _activeRequestId = requestId;
    try {
      final response = await _channel
          .invokeMapMethod<String, Object?>('discover', {
            'requestId': requestId,
            'timeoutMs': _discoveryTimeoutMs,
          })
          .timeout(_discoveryCallTimeout);
      _throwIfCancelled(requestId);
      if (response == null || response['servers'] is! List) {
        throw const NasDiscoveryException('局域网发现返回了无法识别的结果，请手动输入服务器地址。');
      }

      final rows = response['servers'] as List;
      final servers = <NasDiscoveryServer>[];
      for (final row in rows.take(16)) {
        final server = _parseCandidate(row);
        if (server != null) servers.add(server);
      }
      if (rows.isNotEmpty && servers.isEmpty) {
        throw const NasDiscoveryException('发现结果不是可用的本地 HTTP/HTTPS 地址，请手动输入服务器地址。');
      }
      return List.unmodifiable(servers);
    } on NasDiscoveryCancelled {
      rethrow;
    } on TimeoutException {
      if (_activeRequestId == requestId) {
        unawaited(cancel());
        throw const NasDiscoveryException('局域网搜索超时，请手动输入服务器地址后重试。');
      }
      throw const NasDiscoveryCancelled();
    } on PlatformException catch (error) {
      _throwIfCancelled(requestId);
      if (error.code == 'discovery_cancelled') {
        throw const NasDiscoveryCancelled();
      }
      throw NasDiscoveryException(_messageFor(error.code));
    } catch (error) {
      _throwIfCancelled(requestId);
      if (error is NasDiscoveryException) rethrow;
      throw const NasDiscoveryException('无法搜索局域网 NAS，请检查网络后重试。');
    } finally {
      if (_activeRequestId == requestId) _activeRequestId = null;
    }
  }

  /// Invalidates the pending result before asking the native browser to stop.
  Future<void> cancel() async {
    final requestId = _activeRequestId;
    if (requestId == null) return;
    _activeRequestId = null;
    try {
      await _channel
          .invokeMethod<bool>('cancel', {'requestId': requestId})
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // Invalidating the local request is sufficient to ignore a late result.
    }
  }

  void _throwIfCancelled(String requestId) {
    if (_activeRequestId != requestId) {
      throw const NasDiscoveryCancelled();
    }
  }

  static String _newRequestId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static String _messageFor(String code) => switch (code) {
    'discovery_timeout' => '10 秒内没有发现 LightIsle NAS。可手动输入服务器地址。',
    'discovery_permission_denied' => '系统未允许局域网发现，请在系统设置中允许 LightIsle 访问本地网络。',
    'discovery_unavailable' => '此设备暂不支持局域网发现，可手动输入服务器地址。',
    'discovery_cancelled' => '局域网搜索已取消。',
    'discovery_failed' => '无法启动局域网发现，请检查当前网络或本地网络权限后重试。',
    _ => '无法搜索局域网 NAS，请检查网络后重试。',
  };

  static NasDiscoveryServer? _parseCandidate(Object? row) {
    if (row is! Map) return null;
    final nameValue = row['name'];
    final hostValue = row['host'];
    final portValue = row['port'];
    final urlValue = row['url'];
    final schemeValue = row['scheme'];
    if (hostValue is! String || portValue is! int || urlValue is! String) {
      return null;
    }
    if (portValue < 1 ||
        portValue > 65535 ||
        !_isLocalNumericAddress(hostValue)) {
      return null;
    }

    final urlHost = hostValue.contains(':')
        ? '[${hostValue.replaceAll('%', '%25')}]'
        : hostValue;
    // Missing scheme is a legacy HTTPS-only advertisement. The device is
    // untrusted: never infer HTTP from the port number or a forged URL.
    final scheme = schemeValue ?? 'https';
    if (scheme != 'https' && scheme != 'http') return null;
    final address = '$scheme://$urlHost:$portValue';
    // The native channel is an input boundary. Rebuild the only accepted URL
    // from validated address pieces and require an exact match.
    if (urlValue != address) return null;

    final rawName = nameValue is String ? nameValue : '';
    final cleanedName = rawName
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
        .trim();
    final safeName = cleanedName.length > 128
        ? cleanedName.substring(0, 128)
        : cleanedName;
    return NasDiscoveryServer(
      name: safeName.isEmpty ? 'LightIsle NAS' : safeName,
      address: address,
    );
  }

  static bool _isLocalNumericAddress(String host) {
    if (host.isEmpty || host.length > 128 || host != host.trim()) return false;

    if (!host.contains(':')) {
      final octets = host.split('.');
      if (octets.length != 4) return false;
      final values = <int>[];
      for (final octet in octets) {
        if (octet.isEmpty ||
            octet.length > 3 ||
            !RegExp(r'^\d+$').hasMatch(octet)) {
          return false;
        }
        final value = int.tryParse(octet);
        if (value == null ||
            value < 0 ||
            value > 255 ||
            value.toString() != octet) {
          return false;
        }
        values.add(value);
      }
      final address = InternetAddress.tryParse(host);
      if (address == null || address.type != InternetAddressType.IPv4) {
        return false;
      }
      return _isPrivateOrLinkLocalV4(values);
    }

    final zoneIndex = host.lastIndexOf('%');
    final addressText = zoneIndex < 0 ? host : host.substring(0, zoneIndex);
    final zone = zoneIndex < 0 ? null : host.substring(zoneIndex + 1);
    if (!RegExp(r'^[0-9a-fA-F:.]+$').hasMatch(addressText)) {
      return false;
    }
    if (zoneIndex >= 0 &&
        (host.indexOf('%') != zoneIndex ||
            zone == null ||
            !RegExp(r'^[A-Za-z0-9_.-]{1,32}$').hasMatch(zone))) {
      return false;
    }
    final address = InternetAddress.tryParse(addressText);
    if (address == null || address.type != InternetAddressType.IPv6) {
      return false;
    }
    final bytes = address.rawAddress;
    final uniqueLocal = (bytes[0] & 0xfe) == 0xfc;
    final linkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80;
    final siteLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0xc0;
    if (zone != null && !linkLocal && !siteLocal) {
      return false;
    }
    return uniqueLocal || linkLocal || siteLocal;
  }

  static bool _isPrivateOrLinkLocalV4(List<int> octets) {
    return octets[0] == 10 ||
        (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
        (octets[0] == 192 && octets[1] == 168) ||
        (octets[0] == 169 && octets[1] == 254);
  }
}
