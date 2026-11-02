import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/lightisle_api.dart';

/// Shared offline-media namespace, including the current NAS origin, TLS
/// identity, account and physical disk generation.
///
/// The photo and video stores deliberately retain different requirements for
/// their account identifiers. Callers must validate those identifiers before
/// computing a scope, and must not persist session credentials in the index.
String offlineMediaScopeId(LightIsleApi api, String accountIdentity) {
  final rootIdentity = api.selectedRoot?.identity ?? 'default';
  final origin = api.uri('/').origin;
  final pinnedCertificate = api.certificateFingerprint ?? '';
  return sha256
      .convert(
        utf8.encode(
          '$origin\n$pinnedCertificate\n$accountIdentity\n$rootIdentity',
        ),
      )
      .toString();
}
