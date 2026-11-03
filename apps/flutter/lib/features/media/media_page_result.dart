/// Shared bounded response decoding for photo and cinema paginated lists.
///
/// The page owner still controls request generations and filtering. Keep this
/// layer side-effect free so a malformed item cannot discard valid siblings.
final class MediaPageResult<T> {
  const MediaPageResult({required this.items, required this.nextCursor});

  final List<T> items;
  final int nextCursor;

  static MediaPageResult<T> parse<T>(
    Map<String, dynamic> response, {
    required String itemsKey,
    required T Function(Map<String, dynamic>) fromJson,
  }) {
    final parsed = <T>[];
    final rows = response[itemsKey];
    if (rows is List) {
      for (final row in rows) {
        if (row is! Map) continue;
        try {
          parsed.add(fromJson(Map<String, dynamic>.from(row)));
        } on FormatException {
          // One old or malformed index record should not hide the other rows.
        }
      }
    }
    final cursor = response['nextCursor'];
    final next = cursor is num
        ? cursor.toInt()
        : int.tryParse('$cursor') ?? 0;
    return MediaPageResult<T>(items: parsed, nextCursor: next);
  }
}
