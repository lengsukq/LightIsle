import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/files/desktop_backup_engine.dart';
import 'package:lightisle/features/files/desktop_backup_ignore.dart';
import 'package:lightisle/features/files/desktop_backup_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _IgnoreTestNasApi extends LightIsleApi {
  _IgnoreTestNasApi() : super('http://127.0.0.1:1');

  final Set<String> folders = <String>{'.', 'backup'};
  final Map<String, Uint8List> files = <String, Uint8List>{};
  final Map<String, ({String path, int size, BytesBuilder bytes})> _uploads =
      <String, ({String path, int size, BytesBuilder bytes})>{};

  static String _parentOf(String p) {
    final idx = p.lastIndexOf('/');
    return idx < 0 ? '.' : p.substring(0, idx);
  }

  static String _nameOf(String p) {
    final idx = p.lastIndexOf('/');
    return idx < 0 ? p : p.substring(idx + 1);
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/roots') {
      return {
        'roots': [
          {
            'rootID': 'r1',
            'name': '主盘',
            'generation': 1,
            'online': true,
            'isDefault': true,
          },
        ],
      };
    }
    if (path == '/api/v2/files' || path.endsWith('/files')) {
      final dir = query?['path'] ?? '.';
      if (!folders.contains(dir)) {
        throw const LightIsleApiException(
          code: 'not_found',
          message: '目录不存在',
          statusCode: 404,
        );
      }
      final entries = <Map<String, Object>>[
        for (final f in folders)
          if (f != '.' && _parentOf(f) == dir)
            {'name': _nameOf(f), 'path': f, 'type': 'folder', 'size': 0},
        for (final e in files.entries)
          if (_parentOf(e.key) == dir)
            {
              'name': _nameOf(e.key),
              'path': e.key,
              'type': 'file',
              'size': e.value.length,
            },
      ];
      return {'path': dir, 'canWrite': true, 'entries': entries, 'nextCursor': ''};
    }
    if (path.contains('/uploads/')) {
      final id = path.split('/').last;
      final up = _uploads[id];
      if (up == null) {
        throw const LightIsleApiException(
          code: 'not_found',
          message: '不存在',
          statusCode: 404,
        );
      }
      return {'id': id, 'path': up.path, 'size': up.size, 'offset': up.bytes.length};
    }
    throw StateError('Unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    if (method == 'POST' && path.endsWith('/files/folders')) {
      folders.add((body! as Map)['path'].toString());
      return {'created': true};
    }
    if (method == 'POST' && path.endsWith('/uploads')) {
      final req = body! as Map;
      final id = req['uploadID']?.toString() ?? 'u-${_uploads.length}';
      final target = req['path'].toString();
      final size = req['size'] as int;
      _uploads[id] = (path: target, size: size, bytes: BytesBuilder(copy: false));
      return {'id': id, 'path': target, 'size': size, 'offset': 0};
    }
    if (method == 'POST' && path.endsWith('/complete')) {
      final parts = path.split('/');
      final id = parts[parts.length - 2];
      final up = _uploads.remove(id)!;
      files[up.path] = up.bytes.takeBytes();
      return {'completed': true, 'path': up.path};
    }
    throw StateError('Unexpected $method $path');
  }

  @override
  Future<Map<String, dynamic>> uploadChunk(
    String id,
    Stream<List<int>> data,
    int length,
    int offset,
  ) async {
    final up = _uploads[id]!;
    await for (final chunk in data) {
      up.bytes.add(chunk);
    }
    return {'id': id, 'path': up.path, 'size': up.size, 'offset': up.bytes.length};
  }

  @override
  Future<bool> remoteFileMatchesSHA256(
    String path,
    int expectedSize,
    String expectedSHA256, {
    List<String>? chunkSHA256s,
    void Function()? checkActive,
  }) async {
    final data = files[path];
    if (data == null || data.length != expectedSize) return false;
    return sha256.convert(data).toString() == expectedSHA256;
  }
}

class _DirectLocalAccess extends DesktopDirectoryAccess {
  const _DirectLocalAccess(this.path);
  final String path;

  @override
  Future<DesktopPickedFolder?> pickDirectory() async =>
      DesktopPickedFolder(path: path);

  @override
  Future<DesktopDirectoryLease> startAccess(DesktopBackupTask task) async =>
      DesktopDirectoryLease(resolvedPath: task.localPath, stop: () async {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DesktopBackupIgnoreMatcher', () {
    test('dev preset matches node_modules, .git, target, build, .venv, __pycache__', () {
      final matcher = DesktopBackupIgnoreMatcher(
        ignoreHidden: false,
        ignorePresets: const ['dev'],
      );
      expect(matcher.shouldSkipDirectory('node_modules'), isTrue);
      expect(matcher.shouldSkipDirectory('web/node_modules'), isTrue);
      expect(matcher.shouldSkipFile('web/node_modules/pkg/index.js'), isTrue);
      expect(matcher.shouldSkipDirectory('.git'), isTrue);
      expect(matcher.shouldSkipFile('repo/.git/HEAD'), isTrue);
      expect(matcher.shouldSkipDirectory('rust/target'), isTrue);
      expect(matcher.shouldSkipDirectory('app/build'), isTrue);
      expect(matcher.shouldSkipDirectory('.venv'), isTrue);
      expect(matcher.shouldSkipDirectory('pkg/__pycache__'), isTrue);
      expect(matcher.shouldSkipFile('src/main.dart'), isFalse);
      expect(matcher.shouldSkipFile('src/builder.dart'), isFalse);
    });

    test('temp preset matches *.tmp, ~\$*, *.part, .DS_Store, Thumbs.db', () {
      final matcher = DesktopBackupIgnoreMatcher(
        ignoreHidden: false,
        ignorePresets: const ['temp'],
      );
      expect(matcher.shouldSkipFile('draft.tmp'), isTrue);
      expect(matcher.shouldSkipFile('docs/~\$Report.docx'), isTrue);
      expect(matcher.shouldSkipFile('video.mp4.part'), isTrue);
      expect(matcher.shouldSkipFile('.DS_Store'), isTrue);
      expect(matcher.shouldSkipFile('photos/Thumbs.db'), isTrue);
      expect(matcher.shouldSkipFile('docs/Report.docx'), isFalse);
      expect(matcher.shouldSkipFile('docs/part1.txt'), isFalse);
    });

    test('custom globs handle *, **, ?, trailing slash, anchored leading slash, comments', () {
      final patterns = parseCustomIgnoreText('''
        # comment line
        *.log
        cache/**
        dist/
        /root-only.txt
        a/**/b?.txt
      ''');
      final matcher = DesktopBackupIgnoreMatcher(
        ignoreHidden: true,
        customIgnorePatterns: patterns,
      );

      expect(matcher.shouldSkipFile('app.log'), isTrue);
      expect(matcher.shouldSkipFile('nested/server.log'), isTrue);
      expect(matcher.shouldSkipFile('nested/logger.txt'), isFalse);

      // cache/** prunes cache directory and matches files inside, not a plain file named cache
      expect(matcher.shouldSkipDirectory('cache'), isTrue);
      expect(matcher.shouldSkipFile('cache/a/b.bin'), isTrue);
      expect(matcher.shouldSkipFile('cache'), isFalse);

      // dist/ is directory-only
      expect(matcher.shouldSkipDirectory('dist'), isTrue);
      expect(matcher.shouldSkipDirectory('packages/ui/dist'), isTrue);
      expect(matcher.shouldSkipFile('packages/ui/dist/bundle.js'), isTrue);
      expect(matcher.shouldSkipFile('dist'), isFalse);

      // Anchored /root-only.txt matches only at root
      expect(matcher.shouldSkipFile('root-only.txt'), isTrue);
      expect(matcher.shouldSkipFile('sub/root-only.txt'), isFalse);

      // a/**/b?.txt matches zero or more directories and single char wildcard
      expect(matcher.shouldSkipFile('a/b1.txt'), isTrue);
      expect(matcher.shouldSkipFile('a/x/y/bZ.txt'), isTrue);
      expect(matcher.shouldSkipFile('a/x/b12.txt'), isFalse);

      // Windows backslash normalization
      expect(matcher.shouldSkipFile(r'nested\server.log'), isTrue);
    });

    test('hidden toggle, reserved .lightisle-*, and maxFileSizeMiB boundaries', () {
      final hiddenOff = DesktopBackupIgnoreMatcher(
        ignoreHidden: false,
        maxFileSizeMiB: 2,
      );
      expect(hiddenOff.shouldSkipFile('.env'), isFalse);
      expect(hiddenOff.shouldSkipFile('.lightisle-tmp'), isTrue);
      expect(hiddenOff.shouldSkipFile('.DS_Store'), isTrue);
      expect(hiddenOff.exceedsSizeLimit(2 * kBytesPerMiB), isFalse);
      expect(hiddenOff.exceedsSizeLimit(2 * kBytesPerMiB + 1), isTrue);
      expect(
        hiddenOff.shouldSkipFile('big.bin', sizeBytes: 2 * kBytesPerMiB + 1),
        isTrue,
      );

      final unlimited = DesktopBackupIgnoreMatcher(maxFileSizeMiB: 0);
      expect(unlimited.exceedsSizeLimit(1024 * kBytesPerMiB), isFalse);
      expect(unlimited.shouldSkipFile('.env'), isTrue);
    });
  });

  group('DesktopBackupTask backward compatibility & filtered sync', () {
    test('legacy JSON without new fields deserializes cleanly and round-trips new fields', () {
      final legacy = DesktopBackupTask.tryFromJson(const {
        'id': 't1',
        'label': 'Legacy',
        'localPath': '/tmp/legacy',
        'rootId': 'r1',
        'rootGeneration': 2,
        'rootName': '主盘',
        'remoteBasePath': 'Docs',
      });
      expect(legacy, isNotNull);
      expect(legacy!.ignorePresets, isEmpty);
      expect(legacy.customIgnorePatterns, isEmpty);
      expect(legacy.maxFileSizeMiB, 0);
      expect(legacy.watchOnChange, isFalse);
      expect(legacy.localDisplayPath, isNull);
      expect(legacy.displayLocalPath, '/tmp/legacy');

      final enhanced = legacy.copyWith(
        ignorePresets: const ['dev', 'temp'],
        customIgnorePatterns: const ['*.log', 'cache/**'],
        maxFileSizeMiB: 100,
        watchOnChange: true,
        localDisplayPath: '内部存储/Docs',
      );
      final roundTrip = DesktopBackupTask.tryFromJson(enhanced.toJson());
      expect(roundTrip, isNotNull);
      expect(roundTrip!.ignorePresets, const ['dev', 'temp']);
      expect(roundTrip.customIgnorePatterns, const ['*.log', 'cache/**']);
      expect(roundTrip.maxFileSizeMiB, 100);
      expect(roundTrip.watchOnChange, isTrue);
      expect(roundTrip.localDisplayPath, '内部存储/Docs');
      expect(roundTrip.displayLocalPath, '内部存储/Docs');
    });

    test('engine sync skips preset dirs, custom patterns, and oversized files', () async {
      SharedPreferences.setMockInitialValues({});
      final tempDir = await Directory.systemTemp.createTemp('li-ignore-sync-');
      final api = _IgnoreTestNasApi();
      addTearDown(() async {
        api.close();
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      await File('${tempDir.path}/keep.txt').writeAsString('keep me');
      await File('${tempDir.path}/debug.log').writeAsString('ignore log');
      await File('${tempDir.path}/draft.tmp').writeAsString('ignore tmp');
      await Directory('${tempDir.path}/node_modules/pkg').create(recursive: true);
      await File('${tempDir.path}/node_modules/pkg/a.js').writeAsString('js');
      await Directory('${tempDir.path}/cache').create(recursive: true);
      await File('${tempDir.path}/cache/blob.dat').writeAsString('cache');
      // 1 MiB + 1 byte file should be skipped when maxFileSizeMiB == 1
      await File('${tempDir.path}/oversized.bin')
          .writeAsBytes(Uint8List(kBytesPerMiB + 1));

      final controller = DesktopBackupController(
        api: api,
        userId: 7,
        accountName: 'leo',
        directoryAccess: _DirectLocalAccess(tempDir.path),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.upsertTask(
        DesktopBackupTask(
          id: 't-filter',
          label: '项目源码',
          localPath: tempDir.path,
          rootId: 'r1',
          rootGeneration: 1,
          rootName: '主盘',
          remoteBasePath: 'backup',
          ignorePresets: const ['dev', 'temp'],
          customIgnorePatterns: const ['*.log', 'cache/**'],
          maxFileSizeMiB: 1,
        ),
      );

      final summary = await controller.runTask('t-filter');
      expect(summary, isNotNull);
      expect(summary!.uploadedNew, 1);
      expect(summary.skippedIgnored, greaterThanOrEqualTo(4));
      expect(summary.skippedOversized, 1);
      expect(summary.failedCount, 0);
      expect(api.files.keys, ['backup/keep.txt']);
    });
  });
}
