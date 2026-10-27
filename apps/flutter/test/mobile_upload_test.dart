import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
// The declared file_picker package exposes this platform interface.
// ignore: depend_on_referenced_packages
import 'package:file_picker_platform_interface/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/core/lightisle_api.dart';
import 'package:lightisle/features/files/files_page.dart';
import 'package:lightisle/features/media/photos_page.dart';
import 'package:lightisle/features/media/cinema_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FilePickerPlatform previousPicker;
  late _Picker picker;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    previousPicker = FilePickerPlatform.instance;
    picker = _Picker();
    FilePickerPlatform.instance = picker;
  });
  tearDown(() => FilePickerPlatform.instance = previousPicker);

  for (final cinema in [false, true]) {
    testWidgets(
      '${cinema ? 'video' : 'photo'} upload uses its category directory and original bytes',
      (tester) async {
        final api = _UploadApi();
        addTearDown(api.close);
        final directory = 'Users/u7/${cinema ? 'videos' : 'photos'}';
        picker.files = [
          _MemoryFile(cinema ? 'clip.mov' : 'holiday.heic', [1, 4, 7, 9]),
        ];
        await tester.pumpWidget(
          MaterialApp(
            theme: buildIsleTheme(Brightness.light),
            home: Scaffold(
              body: cinema
                  ? CinemaPage(
                      api: api,
                      isAdmin: false,
                      uploadDirectory: directory,
                    )
                  : PhotosPage(
                      api: api,
                      isAdmin: false,
                      uploadDirectory: directory,
                    ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip(cinema ? '上传视频' : '上传照片与视频'));
        await tester.pumpAndSettle();
        expect(picker.types, [cinema ? FileType.video : FileType.media]);
        expect(
          picker.options!.assetRepresentationMode,
          DarwinAssetRepresentationMode.current,
        );
        expect(picker.compression, 0);
        expect(
          api.begun.single['path'],
          '$directory/${picker.files.single.name}',
        );
        expect(api.bytesSent, [1, 4, 7, 9]);
        expect(api.completed, 1);
        expect(find.textContaining('上传完成'), findsWidgets);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.textContaining('已上传 1'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'file upload exposes system files and media without crowding the browser',
    (tester) async {
      final api = _UploadApi();
      addTearDown(api.close);
      picker.files = [
        _MemoryFile('report.pdf', [5, 6]),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FilesPage(
              api: api,
              isAdmin: false,
              initialPath: 'Users/u7/files',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('新建文件夹'), findsNothing);
      await tester.tap(find.text('上传文件'));
      await tester.pumpAndSettle();
      expect(find.text('照片与视频'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, '文件'));
      await tester.pumpAndSettle();
      expect(picker.types, [FileType.any]);
      expect(api.begun.single['path'], 'Users/u7/files/report.pdf');
      expect(api.completed, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'same-name uploads accept the safe renamed destination and show it',
    (tester) async {
      final api = _UploadApi()
        ..renamedPath = 'Users/u7/photos/holiday (2).heic';
      addTearDown(api.close);
      picker.files = [
        _MemoryFile('holiday.heic', [1, 3, 5]),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FilesPage(
              api: api,
              isAdmin: false,
              uploadOnly: true,
              initialPath: 'Users/u7/photos',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.completed, 1);
      expect(find.textContaining('holiday (2).heic'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a returned destination in another directory is rejected before bytes are sent',
    (tester) async {
      final api = _UploadApi()..renamedPath = 'Users/u8/photos/holiday.heic';
      addTearDown(api.close);
      picker.files = [
        _MemoryFile('holiday.heic', [1, 3, 5]),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FilesPage(
              api: api,
              isAdmin: false,
              uploadOnly: true,
              initialPath: 'Users/u7/photos',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.bytesSent, isEmpty);
      expect(api.completed, 0);
      expect(find.textContaining('上传位置无效'), findsOneWidget);
    },
  );

  testWidgets(
    'a read-only upload destination never opens the picker or writes',
    (tester) async {
      final api = _UploadApi()..writable = false;
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FilesPage(api: api, isAdmin: false, uploadOnly: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(picker.types, isEmpty);
      expect(api.begun, isEmpty);
      expect(find.textContaining('没有上传权限'), findsOneWidget);
    },
  );

  testWidgets(
    'failed uploads keep retry controls and never report completion',
    (tester) async {
      final api = _UploadApi()..failBegin = true;
      addTearDown(api.close);
      picker.files = [
        _MemoryFile('holiday.heic', [2, 3]),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FilesPage(api: api, isAdmin: false, uploadOnly: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.completed, 0);
      expect(find.textContaining('上传完成'), findsNothing);
      await tester.ensureVisible(find.byTooltip('重试上传'));
      api.failBegin = false;
      await tester.tap(find.byTooltip('重试上传'));
      await tester.pumpAndSettle();
      expect(api.completed, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'leaving active upload requires a choice and preserves device source',
    (tester) async {
      final api = _UploadApi()..holdChunk = Completer<void>();
      addTearDown(api.close);
      picker.files = [
        _MemoryFile('clip.mov', [2, 3]),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('上传'),
                onPressed: () => openFileUpload(
                  context,
                  api: api,
                  isAdmin: false,
                  directory: 'Users/u7/videos',
                  type: FileType.video,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('上传'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      for (var i = 0; i < 10 && api.begun.isEmpty; i++) {
        await tester.pump();
      }
      await tester.pageBack();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('结束本次上传？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(api.aborted, 0);
      api.holdChunk!.complete();
      await tester.pumpAndSettle();
      expect(api.completed, 1);
      expect(picker.files.single.readAsBytes(), completion([2, 3]));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}

final class _MemoryFile extends PlatformFile {
  _MemoryFile(this.name, List<int> bytes) : data = Uint8List.fromList(bytes);
  @override
  final String name;
  final Uint8List data;
  @override
  Uri get uri => Uri(scheme: 'memory', path: name);
  @override
  Never get xFile => throw UnimplementedError();
  @override
  int lengthSync() => data.length;
  @override
  Future<int> length() async => data.length;
  @override
  Future<Uint8List> readAsBytes() async => data;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(data);
}

class _Picker extends FilePickerPlatform {
  List<PlatformFile> files = [];
  final types = <FileType>[];
  DarwinOptions? options;
  int? compression;
  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    types.add(type);
    options = darwinOptions;
    compression = compressionQuality;
    return files;
  }
}

class _UploadApi extends LightIsleApi {
  _UploadApi() : super('http://127.0.0.1');
  bool writable = true, failBegin = false;
  final begun = <Map<String, dynamic>>[];
  final bytesSent = <int>[];
  int completed = 0, aborted = 0;
  Completer<void>? holdChunk;
  String? renamedPath;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async => switch (path) {
    '/api/v2/files/root' => {'name': '家庭硬盘'},
    '/api/v2/files' => {'entries': [], 'canWrite': writable},
    '/api/v2/photos' => {'assets': [], 'nextCursor': 0},
    '/api/v2/cinema' => {'films': [], 'nextCursor': 0},
    '/api/v2/photos/albums' ||
    '/api/v2/photos/private-albums' => {'albums': []},
    '/api/v2/photos/status' || '/api/v2/cinema/status' => {
      'status': {'running': false},
    },
    _ => {},
  };
  @override
  Future<Map<String, dynamic>> send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/uploads') {
      if (failBegin) {
        throw const LightIsleApiException(
          code: 'volume_offline',
          message: '硬盘已离线，请检查连接后重试。',
        );
      }
      final state = Map<String, dynamic>.from(body as Map)
        ..addAll({'id': 'upload-${begun.length}', 'offset': 0});
      if (renamedPath != null) state['path'] = renamedPath;
      begun.add(state);
      return state;
    }
    if (path.endsWith('/complete')) {
      completed++;
      return {'completed': true};
    }
    if (method == 'DELETE') {
      aborted++;
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> uploadChunk(
    String id,
    Stream<List<int>> bytes,
    int length,
    int offset,
  ) async {
    await for (final chunk in bytes) {
      bytesSent.addAll(chunk);
    }
    if (holdChunk != null) {
      await holdChunk!.future;
    }
    return {...begun.last, 'offset': offset + length};
  }
}
