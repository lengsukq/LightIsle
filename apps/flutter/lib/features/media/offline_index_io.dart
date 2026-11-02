import 'dart:convert';
import 'dart:io';

/// Atomically writes an offline-media manifest without changing its schema,
/// existing location or temporary suffix. The two stores own distinct
/// validation and account/disk isolation rules; only durable JSON I/O is
/// shared.
Future<void> writeOfflineIndexAtomically(
  File index,
  Object payload, {
  required String temporarySuffix,
}) async {
  if (temporarySuffix != '.tmp' && temporarySuffix != '.new') {
    throw const FormatException('Invalid offline manifest staging suffix');
  }
  // Encode before touching disk so invalid objects cannot damage an index.
  final json = jsonEncode(payload);
  final staging = File('${index.path}$temporarySuffix');
  try {
    await staging.writeAsString(json, flush: true);
    await staging.rename(index.path);
  } finally {
    if (await staging.exists()) await staging.delete();
  }
}
