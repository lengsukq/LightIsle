/// Shared byte-size and local date/time formatters for the Flutter client.
String formatBytes(num? value) {
  if (value == null || !value.isFinite) return '—';
  var n = value.toDouble();
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var i = 0;
  while (n >= 1024 && i < units.length - 1) {
    n /= 1024;
    i++;
  }
  return '${n.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

String formatDateOnly(DateTime date) {
  final local = date.toLocal();
  final year = local.year.toString().padLeft(4, '0');
  return '$year-${_twoDigits(local.month)}-${_twoDigits(local.day)}';
}

String formatDateTime(DateTime date, {bool includeSeconds = false}) {
  final local = date.toLocal();
  final base =
      '${formatDateOnly(local)} ${_twoDigits(local.hour)}:${_twoDigits(local.minute)}';
  return includeSeconds ? '$base:${_twoDigits(local.second)}' : base;
}

String formatUnixSeconds(
  Object? raw, {
  String emptyLabel = '—',
  bool includeSeconds = false,
  bool dateOnly = false,
}) {
  final seconds = raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}') ?? 0;
  if (seconds <= 0) return emptyLabel;
  final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  return dateOnly
      ? formatDateOnly(date)
      : formatDateTime(date, includeSeconds: includeSeconds);
}

String formatUnixMillis(
  int milliseconds, {
  String emptyLabel = '—',
  bool includeSeconds = false,
}) {
  if (milliseconds <= 0) return emptyLabel;
  return formatDateTime(
    DateTime.fromMillisecondsSinceEpoch(milliseconds),
    includeSeconds: includeSeconds,
  );
}
