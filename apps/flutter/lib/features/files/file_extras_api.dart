import 'dart:convert';
import 'dart:typed_data';

import '../../core/lightisle_api.dart';
import 'file_models.dart';

bool isMarkdownFile(String fileName) {
  final lower = fileName.toLowerCase();
  return lower.endsWith('.md') || lower.endsWith('.markdown');
}

bool isEditableTextFile(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot == fileName.length - 1) return false;
  final ext = fileName.substring(dot + 1).toLowerCase();
  return const <String>{
    'md',
    'markdown',
    'txt',
    'json',
    'yaml',
    'yml',
    'toml',
    'ini',
    'conf',
    'cfg',
    'properties',
    'csv',
    'tsv',
    'log',
    'xml',
    'sql',
    'srt',
    'vtt',
    'env',
    'gitignore',
    'css',
    'js',
    'ts',
    'html',
    'htm',
    'sh',
    'py',
    'go',
    'dart',
    'swift',
    'kt',
    'java',
    'rs',
    'c',
    'h',
    'cpp',
    'hpp',
  }.contains(ext);
}

bool isReadableArchiveFile(String fileName) {
  final lower = fileName.toLowerCase();
  return lower.endsWith('.cbz') ||
      lower.endsWith('.epub') ||
      lower.endsWith('.zip');
}

bool isOfficeDocumentFile(String fileName) {
  final lower = fileName.toLowerCase();
  return lower.endsWith('.docx') ||
      lower.endsWith('.xlsx') ||
      lower.endsWith('.pptx') ||
      lower.endsWith('.doc') ||
      lower.endsWith('.xls') ||
      lower.endsWith('.ppt');
}

class CollectLinkEntry {
  const CollectLinkEntry({
    required this.id,
    required this.rootId,
    required this.rootGeneration,
    required this.targetPath,
    required this.title,
    required this.hasPassword,
    required this.maxFiles,
    required this.maxFileBytes,
    required this.maxTotalBytes,
    required this.uploadedFiles,
    required this.uploadedBytes,
    required this.allowedExts,
    required this.createdAt,
    required this.expiresAt,
  });

  final String id;
  final String rootId;
  final int rootGeneration;
  final String targetPath;
  final String title;
  final bool hasPassword;
  final int maxFiles;
  final int maxFileBytes;
  final int maxTotalBytes;
  final int uploadedFiles;
  final int uploadedBytes;
  final List<String> allowedExts;
  final int createdAt;
  final int expiresAt;

  DateTime? get expiresAtTime => expiresAt > 0
      ? DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000, isUtc: true)
      : null;

  bool get isExpired =>
      expiresAt > 0 &&
      DateTime.now().toUtc().millisecondsSinceEpoch > expiresAt * 1000;

  factory CollectLinkEntry.fromJson(Map<String, dynamic> json) {
    final extsRaw = json['allowedExts'];
    final exts = extsRaw is List
        ? extsRaw.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
        : const <String>[];
    return CollectLinkEntry(
      id: json['id']?.toString() ?? '',
      rootId: json['rootId']?.toString() ?? '',
      rootGeneration: (json['rootGeneration'] as num?)?.toInt() ?? 0,
      targetPath: json['targetPath']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      hasPassword: json['hasPassword'] == true,
      maxFiles: (json['maxFiles'] as num?)?.toInt() ?? 0,
      maxFileBytes: (json['maxFileBytes'] as num?)?.toInt() ?? 0,
      maxTotalBytes: (json['maxTotalBytes'] as num?)?.toInt() ?? 0,
      uploadedFiles: (json['uploadedFiles'] as num?)?.toInt() ?? 0,
      uploadedBytes: (json['uploadedBytes'] as num?)?.toInt() ?? 0,
      allowedExts: exts,
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      expiresAt: (json['expiresAt'] as num?)?.toInt() ?? 0,
    );
  }
}

class CreatedCollectLink {
  const CreatedCollectLink({
    required this.link,
    required this.token,
    required this.publicPath,
    required this.primaryUrl,
    this.alternateUrl,
  });

  final CollectLinkEntry link;
  final String token;
  final String publicPath;
  final String primaryUrl;
  final String? alternateUrl;
}

class FilePinEntry {
  const FilePinEntry({
    required this.rootId,
    required this.rootGeneration,
    required this.path,
    required this.kind,
    required this.label,
    required this.pinnedAt,
    required this.exists,
    this.size = 0,
    this.modified,
    this.canWrite = false,
  });

  final String rootId;
  final int rootGeneration;
  final String path;
  final String kind;
  final String label;
  final int pinnedAt;
  final bool exists;
  final int size;
  final DateTime? modified;
  final bool canWrite;

  bool get isFolder => kind == 'folder';

  String get displayName {
    if (label.trim().isNotEmpty) return label.trim();
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
  }

  FileEntry toFileEntry() => FileEntry(
    name: path.split('/').last,
    path: path,
    type: isFolder ? 'folder' : 'file',
    size: size,
    modified: modified,
    canWrite: canWrite,
  );

  factory FilePinEntry.fromJson(Map<String, dynamic> json) {
    final modRaw = json['modified']?.toString();
    return FilePinEntry(
      rootId: json['rootId']?.toString() ?? '',
      rootGeneration: (json['rootGeneration'] as num?)?.toInt() ?? 0,
      path: json['path']?.toString() ?? '',
      kind: json['kind']?.toString() ?? 'file',
      label: json['label']?.toString() ?? '',
      pinnedAt: (json['pinnedAt'] as num?)?.toInt() ?? 0,
      exists: json['exists'] != false,
      size: (json['size'] as num?)?.toInt() ?? 0,
      modified: modRaw == null || modRaw.isEmpty
          ? null
          : DateTime.tryParse(modRaw),
      canWrite: json['canWrite'] == true,
    );
  }
}

class FileInsightItem {
  const FileInsightItem({
    required this.name,
    required this.path,
    required this.parentDir,
    required this.size,
    this.modified,
    this.modifiedAt = 0,
    this.ext = '',
    this.canWrite = false,
  });

  final String name;
  final String path;
  final String parentDir;
  final int size;
  final DateTime? modified;
  final int modifiedAt;
  final String ext;
  final bool canWrite;

  FileEntry toFileEntry() => FileEntry(
    name: name,
    path: path,
    type: 'file',
    size: size,
    modified: modified,
    canWrite: canWrite,
  );

  factory FileInsightItem.fromJson(Map<String, dynamic> json) {
    final modRaw = json['modified']?.toString();
    return FileInsightItem(
      name: json['name']?.toString() ?? '',
      path: json['path']?.toString() ?? '',
      parentDir: json['parentDir']?.toString() ?? '.',
      size: (json['size'] as num?)?.toInt() ?? 0,
      modified: modRaw == null || modRaw.isEmpty
          ? null
          : DateTime.tryParse(modRaw),
      modifiedAt: (json['modifiedAt'] as num?)?.toInt() ?? 0,
      ext: json['ext']?.toString() ?? '',
      canWrite: json['canWrite'] == true,
    );
  }
}

class FileInsightsResponse {
  const FileInsightsResponse({
    required this.mode,
    required this.scannedFiles,
    required this.matchedFiles,
    required this.totalBytes,
    required this.truncated,
    required this.timedOut,
    required this.items,
    this.minBytes = 0,
    this.days = 0,
  });

  final String mode;
  final int minBytes;
  final int days;
  final int scannedFiles;
  final int matchedFiles;
  final int totalBytes;
  final bool truncated;
  final bool timedOut;
  final List<FileInsightItem> items;

  factory FileInsightsResponse.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final list = <FileInsightItem>[];
    if (rawItems is List) {
      for (final row in rawItems) {
        if (row is Map) {
          list.add(FileInsightItem.fromJson(Map<String, dynamic>.from(row)));
        }
      }
    }
    return FileInsightsResponse(
      mode: json['mode']?.toString() ?? 'large',
      minBytes: (json['minBytes'] as num?)?.toInt() ?? 0,
      days: (json['days'] as num?)?.toInt() ?? 0,
      scannedFiles: (json['scannedFiles'] as num?)?.toInt() ?? 0,
      matchedFiles: (json['matchedFiles'] as num?)?.toInt() ?? 0,
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      truncated: json['truncated'] == true,
      timedOut: json['timedOut'] == true,
      items: list,
    );
  }
}

class EditableTextDocument {
  const EditableTextDocument({
    required this.path,
    required this.name,
    required this.content,
    required this.size,
    required this.mtimeUnixNano,
    this.modified,
    required this.canWrite,
  });

  final String path;
  final String name;
  final String content;
  final int size;
  final int mtimeUnixNano;
  final DateTime? modified;
  final bool canWrite;

  factory EditableTextDocument.fromJson(Map<String, dynamic> json) {
    final modRaw = json['modified']?.toString();
    return EditableTextDocument(
      path: json['path']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      mtimeUnixNano: (json['mtimeUnixNano'] as num?)?.toInt() ?? 0,
      modified: modRaw == null || modRaw.isEmpty
          ? null
          : DateTime.tryParse(modRaw),
      canWrite: json['canWrite'] == true,
    );
  }
}

class TextSaveOutcome {
  const TextSaveOutcome({
    required this.saved,
    required this.conflict,
    this.path = '',
    this.size = 0,
    this.mtimeUnixNano = 0,
    this.conflictMessage,
  });

  final bool saved;
  final bool conflict;
  final String path;
  final int size;
  final int mtimeUnixNano;
  final String? conflictMessage;
}

class ArchiveEntryDescriptor {
  const ArchiveEntryDescriptor({
    required this.name,
    required this.size,
    required this.mime,
    required this.kind,
  });

  final String name;
  final int size;
  final String mime;
  final String kind;

  bool get isImage => kind == 'image';
  bool get isDocument => kind == 'document';
  bool get isMetadata => kind == 'metadata';

  factory ArchiveEntryDescriptor.fromJson(Map<String, dynamic> json) =>
      ArchiveEntryDescriptor(
        name: json['name']?.toString() ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        mime: json['mime']?.toString() ?? '',
        kind: json['kind']?.toString() ?? '',
      );
}

class ArchiveEntriesResponse {
  const ArchiveEntriesResponse({
    required this.path,
    required this.format,
    required this.size,
    required this.mtimeUnixNano,
    required this.entryCount,
    required this.entries,
  });

  final String path;
  final String format;
  final int size;
  final int mtimeUnixNano;
  final int entryCount;
  final List<ArchiveEntryDescriptor> entries;

  factory ArchiveEntriesResponse.fromJson(Map<String, dynamic> json) {
    final raw = json['entries'];
    final items = <ArchiveEntryDescriptor>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          items.add(
            ArchiveEntryDescriptor.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    return ArchiveEntriesResponse(
      path: json['path']?.toString() ?? '',
      format: json['format']?.toString() ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      mtimeUnixNano: (json['mtimeUnixNano'] as num?)?.toInt() ?? 0,
      entryCount: (json['entryCount'] as num?)?.toInt() ?? items.length,
      entries: items,
    );
  }
}

class ReadingProgressEntry {
  const ReadingProgressEntry({
    required this.rootId,
    required this.rootGeneration,
    required this.path,
    required this.locator,
    required this.percent,
    required this.updatedAt,
  });

  final String rootId;
  final int rootGeneration;
  final String path;
  final String locator;
  final double percent;
  final int updatedAt;

  factory ReadingProgressEntry.fromJson(Map<String, dynamic> json) =>
      ReadingProgressEntry(
        rootId: json['rootId']?.toString() ?? '',
        rootGeneration: (json['rootGeneration'] as num?)?.toInt() ?? 0,
        path: json['path']?.toString() ?? '',
        locator: json['locator']?.toString() ?? '',
        percent: (json['percent'] as num?)?.toDouble() ?? 0.0,
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );
}

/// Self-contained API helper for collect links, file pins, file insights,
/// editable text/Markdown files, archive readers, and reading progress.
class FileExtrasApi {
  const FileExtrasApi(this.api);

  final LightIsleApi api;

  String _collectLinksBasePath() {
    final root = api.selectedRoot;
    if (root == null || root.id.isEmpty) {
      return '/api/v2/collect-links';
    }
    return '/api/v2/roots/${Uri.encodeComponent(root.id)}/collect-links';
  }

  Map<String, String>? _collectRootQuery() {
    final root = api.selectedRoot;
    if (root == null || root.generation <= 0) return null;
    return <String, String>{'rootGeneration': '${root.generation}'};
  }

  Future<List<CollectLinkEntry>> listCollectLinks() async {
    final res = await api.get(
      _collectLinksBasePath(),
      query: _collectRootQuery(),
    );
    final raw = res['links'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) => CollectLinkEntry.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  Future<CreatedCollectLink> createCollectLink({
    required String path,
    required int hours,
    String title = '',
    String password = '',
    int maxFiles = 0,
    int maxFileBytes = 0,
    int maxTotalBytes = 0,
    List<String> allowedExts = const [],
  }) async {
    final body = <String, Object>{
      'path': path,
      'hours': hours,
      if (title.trim().isNotEmpty) 'title': title.trim(),
      if (password.isNotEmpty) 'password': password,
      if (maxFiles > 0) 'maxFiles': maxFiles,
      if (maxFileBytes > 0) 'maxFileBytes': maxFileBytes,
      if (maxTotalBytes > 0) 'maxTotalBytes': maxTotalBytes,
      if (allowedExts.isNotEmpty) 'allowedExts': allowedExts,
    };
    final res = await api.send(
      'POST',
      _collectLinksBasePath(),
      body: body,
      query: _collectRootQuery(),
    );
    final rawLink = res['link'];
    final link = rawLink is Map
        ? CollectLinkEntry.fromJson(Map<String, dynamic>.from(rawLink))
        : CollectLinkEntry(
            id: '',
            rootId: api.selectedRoot?.id ?? '',
            rootGeneration: api.selectedRoot?.generation ?? 0,
            targetPath: path,
            title: title,
            hasPassword: password.isNotEmpty,
            maxFiles: maxFiles,
            maxFileBytes: maxFileBytes,
            maxTotalBytes: maxTotalBytes,
            uploadedFiles: 0,
            uploadedBytes: 0,
            allowedExts: allowedExts,
            createdAt: 0,
            expiresAt: 0,
          );
    final token = res['token']?.toString() ?? '';
    final publicPath =
        res['publicPath']?.toString() ??
        '/api/v2/roots/${Uri.encodeComponent(link.rootId)}/public/collect/${Uri.encodeComponent(token)}';
    final primaryUrl = resolvePublicPathUrl(publicPath);
    String? alternateUrl;
    try {
      final remote = await api.get('/api/v2/remote/status');
      final candidate =
          remote['publicUrl']?.toString() ??
          remote['tailscaleUrl']?.toString() ??
          remote['url']?.toString();
      if (candidate != null && candidate.trim().isNotEmpty) {
        final base = Uri.tryParse(candidate.trim());
        if (base != null && base.hasScheme && base.host.isNotEmpty) {
          final alt = base.resolve(publicPath).toString();
          if (alt != primaryUrl) alternateUrl = alt;
        }
      }
    } catch (_) {
      // Optional remote origin lookup; never fail collect link creation.
    }
    return CreatedCollectLink(
      link: link,
      token: token,
      publicPath: publicPath,
      primaryUrl: primaryUrl,
      alternateUrl: alternateUrl,
    );
  }

  String resolvePublicPathUrl(String publicPath) {
    final base = api.uri('/');
    return base.resolve(publicPath).toString();
  }

  Future<void> revokeCollectLink(String id) async {
    await api.send(
      'DELETE',
      '${_collectLinksBasePath()}/${Uri.encodeComponent(id)}',
      query: _collectRootQuery(),
    );
  }

  Future<List<FilePinEntry>> listPins() async {
    final res = await api.get('/api/v2/files/pins');
    final raw = res['pins'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) => FilePinEntry.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  Future<FilePinEntry> addPin({
    required String path,
    String label = '',
  }) async {
    final res = await api.send(
      'POST',
      '/api/v2/files/pins',
      body: <String, Object>{
        'path': path,
        if (label.trim().isNotEmpty) 'label': label.trim(),
      },
    );
    final raw = res['pin'];
    if (raw is Map) {
      return FilePinEntry.fromJson(Map<String, dynamic>.from(raw));
    }
    throw const FormatException('置顶返回数据无效');
  }

  Future<void> removePin(String path) async {
    await api.send('DELETE', '/api/v2/files/pins', query: {'path': path});
  }

  Future<FileInsightsResponse> fetchInsights({
    required String mode,
    String path = '.',
    int? minBytes,
    int? days,
    int limit = 100,
  }) async {
    final query = <String, String>{
      'mode': mode,
      'path': path,
      'limit': '$limit',
      if (minBytes != null && minBytes > 0) 'minBytes': '$minBytes',
      if (days != null && days > 0) 'days': '$days',
    };
    final res = await api.get('/api/v2/files/insights', query: query);
    return FileInsightsResponse.fromJson(res);
  }

  Future<EditableTextDocument> loadEditableText(String path) async {
    final res = await api.get('/api/v2/files/text', query: {'path': path});
    return EditableTextDocument.fromJson(res);
  }

  Future<TextSaveOutcome> saveEditableText({
    required String path,
    required String content,
    int? expectedMtimeUnixNano,
    bool create = false,
  }) async {
    try {
      final res = await api.send(
        'PUT',
        '/api/v2/files/text',
        body: <String, Object>{
          'path': path,
          'content': content,
          if (expectedMtimeUnixNano != null && expectedMtimeUnixNano > 0)
            'expectedMtimeUnixNano': expectedMtimeUnixNano,
          if (create) 'create': true,
        },
      );
      return TextSaveOutcome(
        saved: res['saved'] == true,
        conflict: false,
        path: res['path']?.toString() ?? path,
        size: (res['size'] as num?)?.toInt() ?? utf8.encode(content).length,
        mtimeUnixNano: (res['mtimeUnixNano'] as num?)?.toInt() ?? 0,
      );
    } on LightIsleApiException catch (err) {
      if (err.statusCode == 409 || err.code == 'file_modified_conflict') {
        return TextSaveOutcome(
          saved: false,
          conflict: true,
          path: path,
          conflictMessage: err.message.isNotEmpty
              ? err.message
              : '文件在磁盘上已被其他设备修改，已保留当前草稿，请先刷新核对后再合并保存。',
        );
      }
      rethrow;
    }
  }

  Future<ArchiveEntriesResponse> listArchiveEntries(String path) async {
    final res = await api.get(
      '/api/v2/files/archive-entries',
      query: {'path': path},
    );
    return ArchiveEntriesResponse.fromJson(res);
  }

  Future<Uint8List> fetchArchiveEntryBytes(
    String path,
    String entry, {
    int maxBytes = 32 * 1024 * 1024,
  }) => api.bytes(
    '/api/v2/files/archive-entry',
    query: {'path': path, 'entry': entry},
    maxBytes: maxBytes,
  );

  Future<ReadingProgressEntry?> getReadingProgress(String path) async {
    final res = await api.get(
      '/api/v2/files/reading-progress',
      query: {'path': path},
    );
    if (res['found'] != true) return null;
    final raw = res['progress'];
    if (raw is! Map) return null;
    return ReadingProgressEntry.fromJson(Map<String, dynamic>.from(raw));
  }

  Future<ReadingProgressEntry?> saveReadingProgress({
    required String path,
    required String locator,
    required double percent,
  }) async {
    final clamped = percent.clamp(0.0, 100.0).toDouble();
    final res = await api.send(
      'PUT',
      '/api/v2/files/reading-progress',
      body: <String, Object>{
        'path': path,
        'locator': locator,
        'percent': clamped,
      },
    );
    final raw = res['progress'];
    if (raw is! Map) return null;
    return ReadingProgressEntry.fromJson(Map<String, dynamic>.from(raw));
  }
}
