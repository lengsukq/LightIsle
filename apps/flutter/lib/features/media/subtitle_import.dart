import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

typedef LocalSubtitle = ({String name, String contents});

/// Reads user-picked subtitle bytes, with a hard cap even when the picker
/// cannot tell us the file length in advance. Never uploads the local file.
Future<LocalSubtitle?> pickLocalSubtitle({
  List<String> extensions = const ['srt', 'ass', 'ssa', 'vtt'],
}) async {
  final files = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: extensions,
  );
  if (files.isEmpty) return null;
  final file = files.first;
  const maxBytes = 1 << 20;
  final length = await file.length();
  if (length != null && length > maxBytes) {
    throw const FormatException('字幕文件超过 1 MiB');
  }
  final accumulator = BytesBuilder(copy: false);
  var count = 0;
  await for (final bytes in file.readAsByteStream()) {
    count += bytes.length;
    if (count > maxBytes) {
      throw const FormatException('字幕文件超过 1 MiB');
    }
    accumulator.add(bytes);
  }
  if (count == 0) throw const FormatException('字幕文件为空');
  return (
    name: file.name,
    contents: _decodeSubtitleBytes(accumulator.takeBytes()),
  );
}

String _decodeSubtitleBytes(Uint8List bytes) {
  if (bytes.length >= 2) {
    final bom0 = bytes[0];
    final bom1 = bytes[1];
    if (bom0 == 0xFF && bom1 == 0xFE) {
      return _decodeUtf16(bytes, littleEndian: true);
    }
    if (bom0 == 0xFE && bom1 == 0xFF) {
      return _decodeUtf16(bytes, littleEndian: false);
    }
  }
  return utf8.decode(bytes, allowMalformed: false);
}

String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = 2; i + 1 < bytes.length; i += 2) {
    final codeUnit = littleEndian
        ? bytes[i] | (bytes[i + 1] << 8)
        : (bytes[i] << 8) | bytes[i + 1];
    units.add(codeUnit);
  }
  return String.fromCharCodes(units);
}
