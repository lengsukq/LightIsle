import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

typedef LocalSubtitle = ({String name, String contents});

/// Reads user-picked subtitle bytes, with a hard cap even when the picker
/// cannot tell us the file length in advance. Never uploads the local file.
Future<LocalSubtitle?> pickLocalSubtitle({
  List<String> extensions = const ['srt', 'vtt'],
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
    contents: utf8.decode(accumulator.takeBytes(), allowMalformed: false),
  );
}
