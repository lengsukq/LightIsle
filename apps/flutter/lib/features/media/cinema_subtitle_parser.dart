/// Unified subtitle timeline model and parser supporting WebVTT (`.vtt`),
/// SubRip (`.srt`), and SubStation Alpha (`.ass` / `.ssa`) locally without
/// uploading files to the server.
class SubtitleCue {
  const SubtitleCue({
    required this.start,
    required this.end,
    required this.text,
  });

  final Duration start;
  final Duration end;
  final String text;

  bool contains(Duration position) => position >= start && position <= end;
}

final RegExp _cueTimePattern = RegExp(
  r'^(?:(\d{1,2}):)?(\d{2}):(\d{2})[.,](\d{3})$',
);
final RegExp _assTimePattern = RegExp(
  r'^(\d{1,2}):(\d{2}):(\d{2})[.,](\d{2,3})$',
);
final RegExp _assOverridePattern = RegExp(r'\{[^}]*\}');
final RegExp _markupTagPattern = RegExp(r'<[^>]+>');
final RegExp _whitespaceRunPattern = RegExp(r'\s+');

/// Parses WebVTT, SRT, or ASS/SSA subtitle text into sorted [SubtitleCue] items.
List<SubtitleCue> parseSubtitleText(String source) {
  final normalized = source
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceFirst('\uFEFF', '');
  if (_looksLikeAss(normalized)) {
    return _parseAss(normalized);
  }
  return _parseSrtOrVtt(normalized);
}

/// Kept for backwards compatibility with existing WebVTT/SRT callers.
List<SubtitleCue> parseWebVtt(String source) => parseSubtitleText(source);

bool _looksLikeAss(String normalized) {
  final lower = normalized.toLowerCase();
  return lower.contains('[events]') &&
      (lower.contains('\ndialogue:') || lower.startsWith('dialogue:'));
}

Duration? _parseCueTimestamp(String value) {
  final match = _cueTimePattern.firstMatch(value.trim());
  if (match == null) return null;
  final hours = int.tryParse(match.group(1) ?? '0') ?? 0;
  final minutes = int.tryParse(match.group(2) ?? '') ?? 0;
  final seconds = int.tryParse(match.group(3) ?? '') ?? 0;
  final milliseconds = int.tryParse(match.group(4) ?? '') ?? 0;
  return Duration(
    hours: hours,
    minutes: minutes,
    seconds: seconds,
    milliseconds: milliseconds,
  );
}

Duration? _parseAssTimestamp(String value) {
  final match = _assTimePattern.firstMatch(value.trim());
  if (match == null) return null;
  final hours = int.tryParse(match.group(1) ?? '') ?? 0;
  final minutes = int.tryParse(match.group(2) ?? '') ?? 0;
  final seconds = int.tryParse(match.group(3) ?? '') ?? 0;
  final fraction = match.group(4) ?? '0';
  final millis = fraction.length == 2
      ? (int.tryParse(fraction) ?? 0) * 10
      : (int.tryParse(fraction) ?? 0);
  return Duration(
    hours: hours,
    minutes: minutes,
    seconds: seconds,
    milliseconds: millis,
  );
}

String _cleanCueMarkup(String raw) {
  final stripped = raw
      .replaceAll(_markupTagPattern, '')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
  return stripped
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
}

List<SubtitleCue> _parseSrtOrVtt(String normalized) {
  final blocks = normalized.split(RegExp(r'\n\s*\n'));
  final cues = <SubtitleCue>[];
  for (final block in blocks) {
    final lines = block.split('\n').map((line) => line.trimRight()).toList();
    final timingIndex = lines.indexWhere((line) => line.contains('-->'));
    if (timingIndex < 0) continue;
    final sides = lines[timingIndex].split('-->');
    if (sides.length != 2) continue;
    final startToken = sides[0].trim();
    final endToken = sides[1].trim().split(_whitespaceRunPattern).first;
    final start = _parseCueTimestamp(startToken);
    final end = _parseCueTimestamp(endToken);
    final text = _cleanCueMarkup(lines.skip(timingIndex + 1).join('\n'));
    if (start == null || end == null || end <= start || text.isEmpty) {
      continue;
    }
    cues.add(SubtitleCue(start: start, end: end, text: text));
  }
  cues.sort((a, b) => a.start.compareTo(b.start));
  return List.unmodifiable(cues);
}

List<SubtitleCue> _parseAss(String normalized) {
  final lines = normalized.split('\n');
  var inEvents = false;
  var startCol = 1;
  var endCol = 2;
  var textCol = 9;
  var formatFieldCount = 10;
  final cues = <SubtitleCue>[];

  for (final rawLine in lines) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('[') && line.endsWith(']')) {
      inEvents = line.toLowerCase() == '[events]';
      continue;
    }
    if (!inEvents) continue;

    final lower = line.toLowerCase();
    if (lower.startsWith('format:')) {
      final fields = line
          .substring(7)
          .split(',')
          .map((item) => item.trim().toLowerCase())
          .toList(growable: false);
      formatFieldCount = fields.length;
      final foundStart = fields.indexOf('start');
      final foundEnd = fields.indexOf('end');
      final foundText = fields.indexOf('text');
      if (foundStart >= 0 && foundEnd >= 0 && foundText >= 0) {
        startCol = foundStart;
        endCol = foundEnd;
        textCol = foundText;
      }
      continue;
    }
    if (!lower.startsWith('dialogue:')) continue;

    final payload = line.substring(9).trimLeft();
    final fields = _splitAssDialogueFields(payload, textCol, formatFieldCount);
    if (fields.length <= textCol ||
        fields.length <= startCol ||
        fields.length <= endCol) {
      continue;
    }
    final start = _parseAssTimestamp(fields[startCol]);
    final end = _parseAssTimestamp(fields[endCol]);
    if (start == null || end == null || end <= start) continue;

    final text = _cleanAssText(fields[textCol]);
    if (text.isEmpty) continue;
    cues.add(SubtitleCue(start: start, end: end, text: text));
  }

  cues.sort((a, b) => a.start.compareTo(b.start));
  return List.unmodifiable(cues);
}

List<String> _splitAssDialogueFields(String payload, int textCol, int total) {
  final cap = textCol > total - 1 ? textCol : total - 1;
  final parts = <String>[];
  var cursor = 0;
  for (var count = 0; count < cap; count++) {
    final comma = payload.indexOf(',', cursor);
    if (comma < 0) break;
    parts.add(payload.substring(cursor, comma).trim());
    cursor = comma + 1;
  }
  parts.add(payload.substring(cursor));
  return parts;
}

String _cleanAssText(String raw) {
  // Vector drawings use {\p1}...{\p0} and are not readable caption text.
  if (raw.contains(r'\p1')) return '';
  final cleaned = raw
      .replaceAll(_assOverridePattern, '')
      .replaceAll(r'\N', '\n')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\h', ' ');
  return cleaned
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
}
