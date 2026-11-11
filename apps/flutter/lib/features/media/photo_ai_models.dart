import '../../core/lightisle_api.dart';

int _aiInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '') ?? 0;
}

double _aiDouble(Object? v) {
  if (v is num) return v.toDouble();
  return double.tryParse(v?.toString() ?? '') ?? 0;
}

bool _aiBool(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  return v?.toString().toLowerCase() == 'true';
}

String _aiStr(Object? v) => v?.toString() ?? '';

enum PhotoSearchMode {
  all('all', '智能全搜', '搜画面语义（海边日落/猫）、图中文字、人物或文件名…'),
  scene('scene', '画面语义', '自然语言搜画面，如「海边日落」「猫咪」「美食」…'),
  ocr('ocr', '图中搜字', '搜截图、发票、合同、证件中的文字…'),
  person('person', '人物姓名', '按已命名的人物搜索，如「宝宝」「妈妈」…'),
  path('path', '文件名', '按文件名或所在目录名称匹配…');

  const PhotoSearchMode(this.value, this.label, this.hintText);
  final String value;
  final String label;
  final String hintText;
}

void appendPhotoAISearchQuery(
  Map<String, String> query, {
  required String searchTerm,
  required PhotoSearchMode searchMode,
  required int personId,
}) {
  if (personId > 0) {
    query['personId'] = '$personId';
  }
  if (searchTerm.trim().isNotEmpty && searchMode != PhotoSearchMode.all) {
    query['searchMode'] = searchMode.value;
  }
}

class PersonSummary {
  const PersonSummary({
    required this.id,
    required this.name,
    required this.photoCount,
    required this.faceCount,
    this.coverFaceId = 0,
    this.coverAssetId = 0,
    this.hidden = false,
  });

  final int id;
  final String name;
  final int photoCount;
  final int faceCount;
  final int coverFaceId;
  final int coverAssetId;
  final bool hidden;

  String get displayName => name.trim().isEmpty ? '人物 #$id' : name.trim();

  factory PersonSummary.fromJson(Map<String, dynamic> json) => PersonSummary(
    id: _aiInt(json['id']),
    name: _aiStr(json['name']),
    photoCount: _aiInt(json['photoCount']),
    faceCount: _aiInt(json['faceCount']),
    coverFaceId: _aiInt(json['coverFaceId']),
    coverAssetId: _aiInt(json['coverAssetId']),
    hidden: _aiBool(json['hidden']),
  );
}

class AssetFaceRef {
  const AssetFaceRef({
    required this.faceId,
    this.personId = 0,
    this.personName = '',
    this.boxX = 0,
    this.boxY = 0,
    this.boxW = 0,
    this.boxH = 0,
  });

  final int faceId;
  final int personId;
  final String personName;
  final double boxX;
  final double boxY;
  final double boxW;
  final double boxH;

  String get displayLabel {
    if (personName.trim().isNotEmpty) return personName.trim();
    if (personId > 0) return '人物 #$personId';
    return '未分组面孔';
  }

  factory AssetFaceRef.fromJson(Map<String, dynamic> json) => AssetFaceRef(
    faceId: _aiInt(json['faceId']),
    personId: _aiInt(json['personId']),
    personName: _aiStr(json['personName']),
    boxX: _aiDouble(json['boxX']),
    boxY: _aiDouble(json['boxY']),
    boxW: _aiDouble(json['boxW']),
    boxH: _aiDouble(json['boxH']),
  );
}

class AssetAIDetail {
  const AssetAIDetail({
    required this.assetId,
    required this.indexed,
    required this.status,
    this.ocrText = '',
    this.sceneLabels = const [],
    this.faces = const [],
  });

  final int assetId;
  final bool indexed;
  final String status;
  final String ocrText;
  final List<String> sceneLabels;
  final List<AssetFaceRef> faces;

  factory AssetAIDetail.fromJson(Map<String, dynamic> json) {
    final labels = (json['sceneLabels'] as List<dynamic>? ?? const [])
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    final faces = (json['faces'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((e) => AssetFaceRef.fromJson(Map<String, dynamic>.from(e)))
        .toList(growable: false);
    return AssetAIDetail(
      assetId: _aiInt(json['assetId']),
      indexed: _aiBool(json['indexed']),
      status: _aiStr(json['status']),
      ocrText: _aiStr(json['ocrText']),
      sceneLabels: labels,
      faces: faces,
    );
  }
}

class SimilarPhotoCandidate {
  const SimilarPhotoCandidate({
    required this.assetId,
    required this.path,
    required this.name,
    required this.size,
    required this.takenAt,
    required this.width,
    required this.height,
    required this.sharpness,
    required this.qualityScore,
    required this.recommended,
    required this.canTrash,
    this.qualityBadges = const [],
  });

  final int assetId;
  final String path;
  final String name;
  final int size;
  final int takenAt;
  final int width;
  final int height;
  final double sharpness;
  final double qualityScore;
  final bool recommended;
  final bool canTrash;
  final List<String> qualityBadges;

  factory SimilarPhotoCandidate.fromJson(Map<String, dynamic> json) =>
      SimilarPhotoCandidate(
        assetId: _aiInt(json['assetId']),
        path: _aiStr(json['path']),
        name: _aiStr(json['name']),
        size: _aiInt(json['size']),
        takenAt: _aiInt(json['takenAt']),
        width: _aiInt(json['width']),
        height: _aiInt(json['height']),
        sharpness: _aiDouble(json['sharpness']),
        qualityScore: _aiDouble(json['qualityScore']),
        recommended: _aiBool(json['recommended']),
        canTrash: _aiBool(json['canTrash']),
        qualityBadges: (json['qualityBadges'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList(growable: false),
      );
}

class SimilarPhotoGroup {
  const SimilarPhotoGroup({
    required this.groupId,
    required this.kind,
    required this.takenAt,
    required this.recommendedAssetId,
    required this.recommendReason,
    required this.reclaimableBytes,
    required this.items,
  });

  final String groupId;
  final String kind;
  final int takenAt;
  final int recommendedAssetId;
  final String recommendReason;
  final int reclaimableBytes;
  final List<SimilarPhotoCandidate> items;

  factory SimilarPhotoGroup.fromJson(Map<String, dynamic> json) =>
      SimilarPhotoGroup(
        groupId: _aiStr(json['groupId']),
        kind: _aiStr(json['kind']),
        takenAt: _aiInt(json['takenAt']),
        recommendedAssetId: _aiInt(json['recommendedAssetId']),
        recommendReason: _aiStr(json['recommendReason']),
        reclaimableBytes: _aiInt(json['reclaimableBytes']),
        items: (json['items'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map(
              (e) =>
                  SimilarPhotoCandidate.fromJson(Map<String, dynamic>.from(e)),
            )
            .toList(growable: false),
      );
}

List<int> selectRecommendedWasteIds(SimilarPhotoGroup group) {
  final keepId = group.recommendedAssetId > 0
      ? group.recommendedAssetId
      : (group.items.isNotEmpty ? group.items.first.assetId : 0);
  return group.items
      .where((item) => item.assetId != keepId && item.canTrash)
      .map((item) => item.assetId)
      .toList(growable: false);
}

enum DuplicateKeepStrategy {
  shortestPath('保留最短路径'),
  newest('保留最新修改'),
  oldest('保留最早创建');

  const DuplicateKeepStrategy(this.label);
  final String label;
}

class DuplicateFileItem {
  const DuplicateFileItem({
    required this.path,
    required this.name,
    required this.size,
    required this.modified,
    required this.identity,
    required this.canTrash,
    this.isApfsClone = false,
    this.isHardlink = false,
  });

  final String path;
  final String name;
  final int size;
  final int modified;
  final String identity;
  final bool canTrash;
  final bool isApfsClone;
  final bool isHardlink;

  factory DuplicateFileItem.fromJson(Map<String, dynamic> json) =>
      DuplicateFileItem(
        path: _aiStr(json['path']),
        name: _aiStr(json['name']),
        size: _aiInt(json['size']),
        modified: _aiInt(json['modified']),
        identity: _aiStr(json['identity']),
        canTrash: _aiBool(json['canTrash']),
        isApfsClone: _aiBool(json['isApfsClone']),
        isHardlink: _aiBool(json['isHardlink']),
      );
}

class DuplicateFileGroup {
  const DuplicateFileGroup({
    required this.groupId,
    required this.sha256,
    required this.size,
    required this.count,
    required this.reclaimableBytes,
    required this.reclaimablePhysicalBytes,
    required this.items,
    this.allApfsClones = false,
  });

  final String groupId;
  final String sha256;
  final int size;
  final int count;
  final int reclaimableBytes;
  final int reclaimablePhysicalBytes;
  final bool allApfsClones;
  final List<DuplicateFileItem> items;

  factory DuplicateFileGroup.fromJson(Map<String, dynamic> json) =>
      DuplicateFileGroup(
        groupId: _aiStr(json['groupId']),
        sha256: _aiStr(json['sha256']),
        size: _aiInt(json['size']),
        count: _aiInt(json['count']),
        reclaimableBytes: _aiInt(json['reclaimableBytes']),
        reclaimablePhysicalBytes: _aiInt(json['reclaimablePhysicalBytes']),
        allApfsClones: _aiBool(json['allApfsClones']),
        items: (json['items'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map(
              (e) => DuplicateFileItem.fromJson(Map<String, dynamic>.from(e)),
            )
            .toList(growable: false),
      );
}

String chooseDuplicateKeepPath(
  List<DuplicateFileItem> items,
  DuplicateKeepStrategy strategy,
) {
  if (items.isEmpty) return '';
  final sorted = List<DuplicateFileItem>.from(items)
    ..sort((a, b) {
      switch (strategy) {
        case DuplicateKeepStrategy.newest:
          if (b.modified != a.modified) return b.modified.compareTo(a.modified);
        case DuplicateKeepStrategy.oldest:
          if (a.modified != b.modified) return a.modified.compareTo(b.modified);
        case DuplicateKeepStrategy.shortestPath:
          if (a.path.length != b.path.length) {
            return a.path.length.compareTo(b.path.length);
          }
      }
      return a.path.compareTo(b.path);
    });
  return sorted.first.path;
}

class DuplicateScanSnapshot {
  const DuplicateScanSnapshot({
    this.running = false,
    this.progressPhase = '',
    this.progressScanned = 0,
    this.progressCandidates = 0,
    this.progressHashed = 0,
    this.progressCurrentPath = '',
    this.lastDone = 0,
    this.lastError = '',
    this.quotaReleaseNote = '',
    this.scannedFiles = 0,
    this.totalGroups = 0,
    this.totalReclaimableBytes = 0,
    this.totalReclaimablePhysicalBytes = 0,
    this.truncated = false,
    this.hasResult = false,
    this.groups = const [],
  });

  final bool running;
  final String progressPhase;
  final int progressScanned;
  final int progressCandidates;
  final int progressHashed;
  final String progressCurrentPath;
  final int lastDone;
  final String lastError;
  final String quotaReleaseNote;
  final int scannedFiles;
  final int totalGroups;
  final int totalReclaimableBytes;
  final int totalReclaimablePhysicalBytes;
  final bool truncated;
  final bool hasResult;
  final List<DuplicateFileGroup> groups;

  String get progressLabel {
    switch (progressPhase) {
      case 'walking':
        return '正在遍历目录 · 已发现 $progressScanned 个候选文件';
      case 'sampling':
        return '正在比对稀疏采样指纹 · 候选 $progressCandidates 个文件';
      case 'hashing':
        return '正在核验完整 SHA-256 指纹 · 已完成 $progressHashed/$progressCandidates';
      default:
        return '正在后台扫描重复文件…';
    }
  }

  factory DuplicateScanSnapshot.fromJson(Map<String, dynamic> json) {
    final progRaw = json['progress'];
    final prog = progRaw is Map ? Map<String, dynamic>.from(progRaw) : null;
    final resRaw = json['result'];
    final res = resRaw is Map ? Map<String, dynamic>.from(resRaw) : null;
    final groups = res == null
        ? const <DuplicateFileGroup>[]
        : (res['groups'] as List<dynamic>? ?? const [])
              .whereType<Map>()
              .map(
                (e) =>
                    DuplicateFileGroup.fromJson(Map<String, dynamic>.from(e)),
              )
              .toList(growable: false);
    return DuplicateScanSnapshot(
      running: _aiBool(json['running']),
      progressPhase: prog == null ? '' : _aiStr(prog['phase']),
      progressScanned: prog == null ? 0 : _aiInt(prog['scannedFiles']),
      progressCandidates: prog == null ? 0 : _aiInt(prog['candidateFiles']),
      progressHashed: prog == null ? 0 : _aiInt(prog['hashedFiles']),
      progressCurrentPath: prog == null ? '' : _aiStr(prog['currentPath']),
      lastDone: _aiInt(json['lastDone']),
      lastError: _aiStr(json['lastError']),
      quotaReleaseNote: _aiStr(json['quotaReleaseNote']),
      hasResult: res != null,
      scannedFiles: res == null ? 0 : _aiInt(res['scannedFiles']),
      totalGroups: res == null ? 0 : _aiInt(res['totalGroups']),
      totalReclaimableBytes: res == null
          ? 0
          : _aiInt(res['totalReclaimableBytes']),
      totalReclaimablePhysicalBytes: res == null
          ? 0
          : _aiInt(res['totalReclaimablePhysicalBytes']),
      truncated: res != null && _aiBool(res['truncated']),
      groups: groups,
    );
  }
}

class PhotoAIRepository {
  const PhotoAIRepository(this.api);
  final LightIsleApi api;

  Future<AssetAIDetail> fetchAssetAIDetail(int assetId) async {
    final res = await api.get('/api/v2/photos/$assetId/ai');
    return AssetAIDetail.fromJson(res);
  }

  Future<bool> setAIPaused(bool paused) async {
    final res = await api.send(
      'POST',
      '/api/v2/photos/ai/pause',
      body: <String, Object>{'paused': paused},
    );
    return _aiBool(res['paused']);
  }

  Future<List<PersonSummary>> listPersons({bool includeHidden = false}) async {
    final res = await api.get(
      '/api/v2/photos/persons',
      query: includeHidden
          ? const <String, String>{'includeHidden': '1'}
          : null,
    );
    return (res['persons'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((e) => PersonSummary.fromJson(Map<String, dynamic>.from(e)))
        .toList(growable: false);
  }

  Future<void> updatePerson(int personId, {String? name, bool? hidden}) async {
    final body = <String, Object>{};
    if (name != null) body['name'] = name;
    if (hidden != null) body['hidden'] = hidden;
    await api.send('PATCH', '/api/v2/photos/persons/$personId', body: body);
  }

  Future<void> mergePerson({
    required int sourcePersonId,
    required int targetPersonId,
  }) async {
    await api.send(
      'POST',
      '/api/v2/photos/persons/$sourcePersonId/merge',
      body: <String, Object>{'targetPersonId': targetPersonId},
    );
  }

  Future<({List<SimilarPhotoGroup> groups, String quotaReleaseNote})>
  listSimilarGroups({int limit = 50}) async {
    final res = await api.get(
      '/api/v2/photos/cleanup/similar',
      query: <String, String>{'limit': '$limit'},
    );
    final groups = (res['groups'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((e) => SimilarPhotoGroup.fromJson(Map<String, dynamic>.from(e)))
        .toList(growable: false);
    return (groups: groups, quotaReleaseNote: _aiStr(res['quotaReleaseNote']));
  }

  Future<({int trashed, int stagedTrashBytes, String quotaReleaseNote})>
  trashSimilarGroup({
    required int keepAssetId,
    required List<int> trashAssetIds,
  }) async {
    final res = await api.send(
      'POST',
      '/api/v2/photos/cleanup/trash',
      body: <String, Object>{
        'keepAssetId': keepAssetId,
        'trashAssetIds': trashAssetIds,
      },
    );
    return (
      trashed: _aiInt(res['trashed']),
      stagedTrashBytes: _aiInt(res['stagedTrashBytes']),
      quotaReleaseNote: _aiStr(res['quotaReleaseNote']),
    );
  }

  Future<DuplicateScanSnapshot> getDuplicatesStatus() async {
    final res = await api.get('/api/v2/files/duplicates');
    return DuplicateScanSnapshot.fromJson(res);
  }

  Future<DuplicateScanSnapshot> scanDuplicates({
    String path = '.',
    int minSizeBytes = 1048576,
    int maxGroups = 200,
    bool asyncScan = true,
  }) async {
    final res = await api.send(
      'POST',
      '/api/v2/files/duplicates/scan',
      body: <String, Object>{
        'path': path,
        'minSizeBytes': minSizeBytes,
        'maxGroups': maxGroups,
        if (asyncScan) 'async': true,
      },
    );
    return DuplicateScanSnapshot.fromJson(res);
  }

  Future<void> cancelDuplicateScan() async {
    await api.send(
      'POST',
      '/api/v2/files/duplicates/cancel',
      body: const <String, Object>{},
    );
  }

  Future<({int trashed, int stagedTrashBytes, String quotaReleaseNote})>
  trashDuplicates(
    List<({String keepPath, List<DuplicateFileItem> trashItems})> groups,
  ) async {
    final res = await api.send(
      'POST',
      '/api/v2/files/duplicates/trash',
      body: <String, Object>{
        'groups': [
          for (final g in groups)
            <String, Object>{
              'keepPath': g.keepPath,
              'trashItems': [
                for (final item in g.trashItems)
                  <String, Object>{
                    'path': item.path,
                    'size': item.size,
                    'identity': item.identity,
                  },
              ],
            },
        ],
      },
    );
    return (
      trashed: _aiInt(res['trashed']),
      stagedTrashBytes: _aiInt(res['stagedTrashBytes']),
      quotaReleaseNote: _aiStr(res['quotaReleaseNote']),
    );
  }
}
