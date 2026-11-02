/// Shared file name validation for ordinary files and media exports.
/// The same reserved names and byte rules apply everywhere.
String? validateFileName(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return '名称不能为空。';
  if (value == '.' || value == '..') return '不能使用“.”或“..”作为名称。';
  if (value.startsWith('.lightisle-')) return '此名称为系统保留名称。';
  if (value.contains('/') || value.contains('\\')) return '名称不能包含路径分隔符。';
  if (value.runes.length > 150) return '名称不能超过 150 个字符。';
  if (value.contains('\u0000')) return '名称包含无效字符。';
  return null;
}

String? validateRelativePath(String raw) {
  final value = raw.trim();
  if (value.isEmpty || value == '.') return '请输入目标路径。';
  if (value.length > 1024) return '路径不能超过 1024 个字符。';
  if (value.startsWith('/') || value.startsWith('\\') || value.contains('\\')) {
    return '请使用共享目录内的相对路径。';
  }
  final parts = value.split('/');
  if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
    return '路径中不能包含空段、“.”或“..”。';
  }
  if (parts.any((part) => part.startsWith('.lightisle-'))) {
    return '路径包含系统保留名称。';
  }
  if (parts.any((part) => part.runes.length > 150)) {
    return '每个路径部分最多 150 个字符。';
  }
  if (value.contains('\u0000')) return '路径包含无效字符。';
  return null;
}
