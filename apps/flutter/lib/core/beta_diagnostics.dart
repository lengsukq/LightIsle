import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

final _requestId = RegExp(r'^(?:flutter-)?[a-f0-9]{32}$');
const _safeCodes = {
  'authentication_required', 'file_permission_denied', 'root_unavailable',
  'volume_offline', 'root_generation_changed', 'default_root_not_configured',
  'storage_quota_exceeded', 'storage_accounting_uncertain',
  'storage_operation_uncertain', 'offset_mismatch', 'upload_outcome_uncertain',
  'upload_begin_uncertain', 'insufficient_storage_space', 'transcode_unavailable',
  'download_unavailable', 'network_error', 'network_timeout',
  'certificate_untrusted', 'certificate_mismatch', 'request_failed',
};
final _random = Random.secure();

String? safeDiagnosticID(String? value) =>
    value != null && _requestId.hasMatch(value) ? value : null;

String newDiagnosticID() =>
    'flutter-${List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

class BetaDiagnostics {
  static const _limit = 200;
  static const _retention = Duration(days: 7);
  static const _maxFileBytes = 100000;
  final _events = <Map<String, Object?>>[];
  String? _scope;
  int _epoch = 0;
  Timer? _saveTimer;
  Future<void> _pending = Future.value();

  int get epoch => _epoch;

  void setAccount(String origin, Object? account) {
    final id = int.tryParse(account?.toString() ?? '');
    if (id == null || id <= 0) return;
    final scope = sha256.convert(utf8.encode('$origin\n$id')).toString();
    if (scope == _scope) return;
    clearAccount();
    _scope = scope;
    final epoch = _epoch;
    _pending = _pending.then((_) async {
      try {
        final file = await _file(scope);
        if (!await file.exists() || await file.length() > _maxFileBytes) return;
        final value = jsonDecode(await file.readAsString());
        if (epoch != _epoch || value is! List) return;
        _events.insertAll(0, value.take(_limit).map(_validated).nonNulls);
        _trim();
      } on Object {
        // The device can still show and export its in-memory events.
      }
    });
  }

  void clearAccount() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_scope != null && _events.isNotEmpty) _queueSave();
    _epoch++;
    _scope = null;
    _events.clear();
  }

  void record(String id, String code, int? status, int epoch) {
    if (epoch != _epoch || safeDiagnosticID(id) == null) return;
    _events.add({
      'time': DateTime.now().toUtc().toIso8601String(),
      'requestID': id,
      'code': _safeCodes.contains(code) ? code : 'request_failed',
      if (status != null && status >= 100 && status <= 599) 'status': status,
    });
    _trim();
    _saveTimer ??= Timer(const Duration(seconds: 1), () {
      _saveTimer = null;
      _queueSave();
    });
  }

  Future<String> report() async {
    await _pending;
    _trim();
    return const JsonEncoder.withIndent('  ').convert({
      'schema': 1,
      'source': 'flutter',
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'events': _events,
    });
  }

  void _trim() {
    final cutoff = DateTime.now().subtract(_retention);
    _events.removeWhere(
      (event) => !DateTime.parse(event['time']! as String).isAfter(cutoff),
    );
    if (_events.length > _limit) {
      _events.removeRange(0, _events.length - _limit);
    }
  }

  Map<String, Object?>? _validated(Object? value) {
    if (value is! Map ||
        value['time'] is! String ||
        value['requestID'] is! String ||
        value['code'] is! String) {
      return null;
    }
    final time = DateTime.tryParse(value['time'] as String);
    final id = safeDiagnosticID(value['requestID'] as String);
    final code = value['code'] as String;
    if (time == null || id == null || !_safeCodes.contains(code)) return null;
    final status = value['status'];
    return {
      'time': time.toUtc().toIso8601String(),
      'requestID': id,
      'code': code,
      if (status is int && status >= 100 && status <= 599) 'status': status,
    };
  }

  Future<File> _file(String scope) async {
    final data = await getApplicationSupportDirectory();
    final directory = Directory('${data.path}/beta-diagnostics');
    await directory.create(recursive: true);
    return File('${directory.path}/$scope.json');
  }

  void _queueSave() {
    final scope = _scope;
    if (scope == null) return;
    final payload = jsonEncode(_events);
    _pending = _pending.then((_) async {
      try {
        final file = await _file(scope);
        final staging = File('${file.path}.${newDiagnosticID()}.tmp');
        try {
          await staging.writeAsString(payload, flush: true);
          await staging.rename(file.path);
        } finally {
          if (await staging.exists()) await staging.delete();
        }
      } on Object {
        // Persistence is best effort and never affects an API result.
      }
    });
  }
}
