import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/lightisle_api.dart';

/// DLNA AVTransport supports explicit user-approved playback of an MP4 file.
/// The NAS session cookie, certificate pin and internal media token never
/// leave this device; the renderer receives only an expiring public share.
class DlnaRenderer {
  const DlnaRenderer({required this.name, required this.controlUri});

  final String name;
  final Uri controlUri;

  static bool isLocalDeviceUri(Uri uri) {
    if (uri.scheme != 'http' || uri.userInfo.isNotEmpty || uri.hasFragment) {
      return false;
    }
    final parts = uri.host.split('.');
    if (parts.length != 4) return false;
    final octets = <int>[];
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null ||
          value < 0 ||
          value > 255 ||
          part != value.toString()) {
        return false;
      }
      octets.add(value);
    }
    // No loopback, public hosts, link-local, multicast or cloud addresses.
    return octets[0] == 10 ||
        (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
        (octets[0] == 192 && octets[1] == 168);
  }

  static Uri? safeControlUri(Uri description, String controlPath) {
    if (!isLocalDeviceUri(description) ||
        controlPath.isEmpty ||
        controlPath.contains('..') ||
        controlPath.contains('#')) {
      return null;
    }
    final control = description.resolve(controlPath.trim());
    if (!isLocalDeviceUri(control) ||
        control.scheme != description.scheme ||
        control.host != description.host ||
        control.port != description.port ||
        control.userInfo.isNotEmpty) {
      return null;
    }
    return control;
  }
}

class DlnaCast {
  static const _service = 'urn:schemas-upnp-org:service:AVTransport:1';
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4)
    ..findProxy = (_) => 'DIRECT';

  void close() => _client.close(force: true);

  Future<List<DlnaRenderer>> discover({
    Duration duration = const Duration(seconds: 3),
  }) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final locations = <Uri>{};
    final subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        final packet = datagram!;
        // Never trust LOCATION blindly; only LAN IPs are fetched.
        if (!DlnaRenderer.isLocalDeviceUri(
          Uri(scheme: 'http', host: packet.address.address),
        )) {
          continue;
        }
        final data = latin1.decode(packet.data, allowInvalid: true);
        final match = RegExp(
          r'^location:\s*(\S+)\s*$',
          multiLine: true,
          caseSensitive: false,
        ).firstMatch(data.replaceAll('\r', ''));
        if (match == null || locations.length >= 24) continue;
        final uri = Uri.tryParse(match.group(1)!);
        if (uri != null &&
            DlnaRenderer.isLocalDeviceUri(uri) &&
            uri.host == packet.address.address) {
          locations.add(uri);
        }
      }
    });
    try {
      final search = utf8.encode(
        'M-SEARCH * HTTP/1.1\r\n'
        'HOST:239.255.255.250:1900\r\n'
        'MAN:"ssdp:discover"\r\n'
        'MX:2\r\n'
        'ST:urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n',
      );
      socket.send(search, InternetAddress('239.255.255.250'), 1900);
      await Future<void>.delayed(duration);
    } finally {
      await subscription.cancel();
      socket.close();
    }
    final found = <DlnaRenderer>[];
    for (final uri in locations.take(12)) {
      try {
        final description = await _readDescription(uri);
        final serviceBlocks = RegExp(
          r'<service\b[^>]*>([\s\S]*?)</service>',
          caseSensitive: false,
        ).allMatches(description);
        for (final block in serviceBlocks) {
          if (_xmlTag(block.group(1)!, 'serviceType') != _service) continue;
          final uriControl = DlnaRenderer.safeControlUri(
            uri,
            _xmlTag(block.group(1)!, 'controlURL'),
          );
          if (uriControl == null) continue;
          final name = _xmlTag(description, 'friendlyName');
          found.add(
            DlnaRenderer(
              name: name.isEmpty ? uri.host : name,
              controlUri: uriControl,
            ),
          );
          break;
        }
      } on Object {
        // Other SSDP responders may not implement AVTransport. Ignore safely.
      }
    }
    found.sort((a, b) => a.name.compareTo(b.name));
    return found;
  }

  static String _xmlTag(String source, String tag) {
    final match = RegExp(
      '<$tag>([^<]{0,512})</$tag>',
      caseSensitive: false,
    ).firstMatch(source);
    return (match?.group(1) ?? '')
        .trim()
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
  }

  Future<String> _readDescription(Uri uri) async {
    final request = await _client
        .getUrl(uri)
        .timeout(const Duration(seconds: 4));
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 4));
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw const HttpException('DLNA device description unavailable');
    }
    final data = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 4))) {
      data.addAll(chunk);
      if (data.length > 128 * 1024) {
        throw const FormatException('DLNA description too large');
      }
    }
    return utf8.decode(data, allowMalformed: true);
  }

  static String _xmlEscape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  Future<void> _soap(
    DlnaRenderer renderer,
    String action,
    String parameters,
  ) async {
    if (!DlnaRenderer.isLocalDeviceUri(renderer.controlUri)) {
      throw StateError('拒绝访问非局域网 DLNA 设备');
    }
    final body =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:$action xmlns:u="$_service">'
        '$parameters</u:$action></s:Body></s:Envelope>';
    final req = await _client
        .postUrl(renderer.controlUri)
        .timeout(const Duration(seconds: 4));
    req.followRedirects = false;
    req.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
    req.headers.set('SOAPACTION', '"$_service#$action"');
    req.add(utf8.encode(body));
    final response = await req.close().timeout(const Duration(seconds: 6));
    await response.drain<void>();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('电视未接受 $action 请求（HTTP ${response.statusCode}）');
    }
  }

  Future<void> play(DlnaRenderer renderer, Uri shareUrl) async {
    if (shareUrl.scheme != 'https' && shareUrl.scheme != 'http') {
      throw StateError('无效的分享地址');
    }
    await _soap(
      renderer,
      'SetAVTransportURI',
      '<InstanceID>0</InstanceID>'
          '<CurrentURI>${_xmlEscape(shareUrl.toString())}</CurrentURI>'
          '<CurrentURIMetaData></CurrentURIMetaData>',
    );
    await _soap(renderer, 'Play', '<InstanceID>0</InstanceID><Speed>1</Speed>');
  }

  Future<void> stop(DlnaRenderer renderer) async {
    await _soap(renderer, 'Stop', '<InstanceID>0</InstanceID>');
  }
}

class DlnaCastSession {
  DlnaCastSession({
    required this.api,
    required this.cast,
    required this.renderer,
    required this.shareId,
  });

  final LightIsleApi api;
  final DlnaCast cast;
  final DlnaRenderer renderer;
  final String shareId;
  bool _revoked = false;
  bool get revoked => _revoked;

  Future<void> stop() async {
    if (_revoked) return;
    Object? deviceError;
    try {
      await cast.stop(renderer);
    } catch (error) {
      deviceError = error;
    }
    // Revocation is more important than the best-effort TV Stop command:
    // receivers may be off, unreachable or ignore AVTransport Stop.
    // If the revoke fails, retain this session so the UI can retry it.
    await api.send(
      'DELETE',
      '/api/v2/file-shares/${Uri.encodeComponent(shareId)}',
    );
    _revoked = true;
    cast.close();
    if (deviceError != null) {
      throw StateError('临时公开链接已撤销，但电视未确认停止播放：$deviceError');
    }
  }
}
