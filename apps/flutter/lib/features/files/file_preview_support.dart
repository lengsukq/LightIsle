import 'dart:convert';
import 'dart:typed_data';

enum FilePreviewKind { text, image, video, pdf, external }

FilePreviewKind classifyFilePreview(String fileName) {
  final ext = fileName.split('.').last.toLowerCase();
  if (const {
    'txt',
    'md',
    'json',
    'log',
    'csv',
    'yaml',
    'yml',
    'xml',
    'html',
    'htm',
    'css',
    'js',
    'ts',
    'dart',
    'java',
    'py',
    'sh',
    'ini',
    'conf',
    'properties',
    'sql',
    'srt',
    'vtt',
    'go',
    'swift',
    'kt',
  }.contains(ext)) {
    return FilePreviewKind.text;
  }
  if (const {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'heic',
    'heif',
    'bmp',
  }.contains(ext)) {
    return FilePreviewKind.image;
  }
  if (const {
    'mp4',
    'm4v',
    'webm',
    'mov',
    'mkv',
    'avi',
    'mpeg',
    'mpg',
    'ts',
    'mts',
    '3gp',
    'wmv',
    'flv',
  }.contains(ext)) {
    return FilePreviewKind.video;
  }
  if (ext == 'pdf') return FilePreviewKind.pdf;
  return FilePreviewKind.external;
}

/// Never silently replace invalid text bytes with the Unicode replacement
/// character. For non-UTF8 files the user can open the unmodified original
/// with their editor; UTF-16 files with a BOM are also handled.
String decodePreviewText(Uint8List data) {
  if (data.length >= 2 && data[0] == 0xff && data[1] == 0xfe) {
    return _decodeUtf16(data, littleEndian: true);
  }
  if (data.length >= 2 && data[0] == 0xfe && data[1] == 0xff) {
    return _decodeUtf16(data, littleEndian: false);
  }
  final bom =
      data.length >= 3 && data[0] == 0xef && data[1] == 0xbb && data[2] == 0xbf
      ? 3
      : 0;
  return utf8.decode(data.sublist(bom), allowMalformed: false);
}

String _decodeUtf16(Uint8List data, {required bool littleEndian}) {
  if (data.length.isOdd) {
    throw const FormatException('UTF-16 文件字节数不完整');
  }
  final units = <int>[];
  for (var i = 2; i < data.length; i += 2) {
    units.add(
      littleEndian
          ? data[i] | (data[i + 1] << 8)
          : (data[i] << 8) | data[i + 1],
    );
  }
  final scalars = <int>[];
  for (var i = 0; i < units.length; i++) {
    final current = units[i];
    if (current >= 0xd800 && current <= 0xdbff) {
      if (i + 1 >= units.length) {
        throw const FormatException('UTF-16 文本不完整');
      }
      final next = units[++i];
      if (next < 0xdc00 || next > 0xdfff) {
        throw const FormatException('UTF-16 替代字符无效');
      }
      scalars.add(0x10000 + ((current - 0xd800) << 10) + (next - 0xdc00));
    } else if (current >= 0xdc00 && current <= 0xdfff) {
      throw const FormatException('UTF-16 替代字符无效');
    } else {
      scalars.add(current);
    }
  }
  return String.fromCharCodes(scalars);
}
