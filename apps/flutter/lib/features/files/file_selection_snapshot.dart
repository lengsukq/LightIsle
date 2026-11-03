import 'file_models.dart';

/// Immutable snapshot of the current file selection and loaded directory.
///
/// A selection is safe for write operations only when *every* selected path
/// still resolves to a loaded, writable entry. This prevents an old selection
/// from looking writable while an asynchronous directory refresh is in flight.
final class FileSelectionSnapshot {
  FileSelectionSnapshot({
    required List<FileEntry> loadedEntries,
    required Set<String> selectedPaths,
    required this.canWrite,
  }) : _selectedPaths = Set.unmodifiable(selectedPaths),
       _loadedEntries = List.unmodifiable(loadedEntries) {
    selectedEntries = List.unmodifiable(
      _loadedEntries.where((entry) => _selectedPaths.contains(entry.path)),
    );
    visiblePaths = Set.unmodifiable(
      _loadedEntries.take(maxSelection).map((entry) => entry.path),
    );
  }

  static const int maxSelection = 50;

  final Set<String> _selectedPaths;
  final List<FileEntry> _loadedEntries;
  final bool Function(FileEntry) canWrite;

  late final List<FileEntry> selectedEntries;
  late final Set<String> visiblePaths;

  int get count => _selectedPaths.length;

  bool get fullyLoaded =>
      count > 0 && count <= maxSelection && selectedEntries.length == count;

  bool get allVisibleSelected =>
      visiblePaths.isNotEmpty && visiblePaths.every(_selectedPaths.contains);

  bool get writableSelection => fullyLoaded && selectedEntries.every(canWrite);

  bool get canExportFiles =>
      fullyLoaded && selectedEntries.every((entry) => !entry.isFolder);

  /// Select up to one visible page or clear that page when already selected.
  Set<String> toggledVisible() {
    if (allVisibleSelected) {
      return {..._selectedPaths}..removeAll(visiblePaths);
    }
    return visiblePaths;
  }
}
