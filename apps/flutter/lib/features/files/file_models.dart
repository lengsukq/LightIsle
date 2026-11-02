/// Entries shared between browsing, previews and transfer actions.
class FileEntry {
  const FileEntry({
    required this.name,
    required this.path,
    required this.type,
    required this.size,
    required this.modified,
    required this.canWrite,
  });

  final String name;
  final String path;
  final String type;
  final int size;
  final DateTime? modified;
  final bool canWrite;

  bool get isFolder => type == 'folder';

  factory FileEntry.fromJson(Map<String, dynamic> json) => FileEntry(
    name: json['name']?.toString() ?? '',
    path: json['path']?.toString() ?? '',
    type: json['type']?.toString() ?? 'file',
    size: fileModelAsInt(json['size']),
    modified: DateTime.tryParse(json['modified']?.toString() ?? ''),
    canWrite: json['canWrite'] == true,
  );
}

class TrashEntry {
  const TrashEntry({
    required this.id,
    required this.name,
    required this.originalPath,
    required this.deletedAt,
  });

  final String id;
  final String name;
  final String originalPath;
  final DateTime? deletedAt;

  factory TrashEntry.fromJson(Map<String, dynamic> json) => TrashEntry(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    originalPath: json['originalPath']?.toString() ?? '',
    deletedAt: DateTime.tryParse(json['deletedAt']?.toString() ?? ''),
  );
}

int fileModelAsInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
