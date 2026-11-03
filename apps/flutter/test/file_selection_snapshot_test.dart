import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/features/files/file_models.dart';
import 'package:lightisle/features/files/file_selection_snapshot.dart';

FileEntry file(String path, {bool writable = true, bool folder = false}) =>
    FileEntry(
      name: path.split('/').last,
      path: path,
      type: folder ? 'folder' : 'file',
      size: 1,
      modified: null,
      canWrite: writable,
    );

void main() {
  test('stale selected paths never allow writes or exports', () {
    final selection = FileSelectionSnapshot(
      loadedEntries: [file('new.txt')],
      selectedPaths: {'deleted.txt'},
      canWrite: (entry) => entry.canWrite,
    );
    expect(selection.count, 1);
    expect(selection.selectedEntries, isEmpty);
    expect(selection.fullyLoaded, false);
    expect(selection.writableSelection, false);
    expect(selection.canExportFiles, false);
  });

  test('read-only selection allows file export but never write operations', () {
    final selection = FileSelectionSnapshot(
      loadedEntries: [file('notes.txt', writable: false)],
      selectedPaths: {'notes.txt'},
      canWrite: (entry) => entry.canWrite,
    );
    expect(selection.fullyLoaded, true);
    expect(selection.canExportFiles, true);
    expect(selection.writableSelection, false);
  });

  test('folder selection is writable but cannot be exported as raw files', () {
    final selection = FileSelectionSnapshot(
      loadedEntries: [file('Documents', folder: true)],
      selectedPaths: {'Documents'},
      canWrite: (entry) => entry.canWrite,
    );
    expect(selection.writableSelection, true);
    expect(selection.canExportFiles, false);
  });

  test('select all is bounded to first 50 loaded paths', () {
    final files = [for (var i = 0; i < 75; i++) file('file-$i.txt')];
    final empty = FileSelectionSnapshot(
      loadedEntries: files,
      selectedPaths: {},
      canWrite: (entry) => entry.canWrite,
    );
    final selected = empty.toggledVisible();
    expect(selected.length, 50);
    final filled = FileSelectionSnapshot(
      loadedEntries: files,
      selectedPaths: selected,
      canWrite: (entry) => entry.canWrite,
    );
    expect(filled.allVisibleSelected, true);
    expect(filled.toggledVisible(), isEmpty);
  });
}
