import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/features/media/media_page_result.dart';

void main() {
  test('decodes valid rows and skips malformed media without losing siblings', () {
    final page = MediaPageResult.parse<int>(
      {
        'assets': [
          {'id': 1},
          'not a map',
          {'id': -3},
          {'id': 4},
        ],
        'nextCursor': '42',
      },
      itemsKey: 'assets',
      fromJson: (row) {
        final id = row['id'] as int;
        if (id < 0) throw const FormatException('invalid id');
        return id;
      },
    );
    expect(page.items, [1, 4]);
    expect(page.nextCursor, 42);
  });

  test('handles numeric cursors and malformed or missing result arrays', () {
    final result = MediaPageResult.parse<String>(
      {'films': null, 'nextCursor': 10.0},
      itemsKey: 'films',
      fromJson: (row) => row['title'] as String,
    );
    expect(result.items, isEmpty);
    expect(result.nextCursor, 10);
    final empty = MediaPageResult.parse<String>(
      {'nextCursor': 'unknown'},
      itemsKey: 'films',
      fromJson: (row) => row['title'] as String,
    );
    expect(empty.items, isEmpty);
    expect(empty.nextCursor, 0);
  });

  test('unexpected programmer errors still surface to caller', () {
    expect(
      () => MediaPageResult.parse<int>(
        {'assets': [{'id': 'not an int'}]},
        itemsKey: 'assets',
        fromJson: (row) => row['id'] as int,
      ),
      throwsA(isA<TypeError>()),
    );
  });
}
