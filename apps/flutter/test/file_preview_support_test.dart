import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_filex/open_filex.dart';
import 'package:lightisle/features/files/external_file_opener.dart';
import 'package:lightisle/features/files/file_preview_support.dart';
import 'package:lightisle/core/lightisle_api.dart';

class _TestDocumentApi extends LightIsleApi {
  _TestDocumentApi() : super('http://127.0.0.1');
  int downloads = 0;
  String? lastPath;
  @override
  Future<void> download(
    String path,
    String destination, {
    Map<String, String>? query,
    void Function(int, int)? onProgress,
  }) async {
    downloads++;
    lastPath = query?['path'];
    await File(destination).writeAsBytes(const [0x25, 0x50, 0x44, 0x46]);
    onProgress?.call(4, 4);
  }
}

void main() {
  test('file classification retains in-app media/PDF/text support', () {
    for (final name in ['a.HEIC', 'b.jpeg', 'c.webp']) {
      expect(classifyFilePreview(name), FilePreviewKind.image);
    }
    for (final name in ['movie.MKV', 'video.mp4', 'clip.mov', 'movie.avi']) {
      expect(classifyFilePreview(name), FilePreviewKind.video);
    }
    for (final name in ['a.txt', 'b.md', 'test.yaml', 'srt.srt', 'source.dart']) {
      expect(classifyFilePreview(name), FilePreviewKind.text);
    }
    expect(classifyFilePreview('manual.pdf'), FilePreviewKind.pdf);
    for (final name in ['office.docx', 'sheet.xlsx', 'archive.zip']) {
      expect(classifyFilePreview(name), FilePreviewKind.external);
    }
  });

  test('text decoding is strict and supports UTF8 BOM and UTF16', () {
    expect(decodePreviewText(Uint8List.fromList(utf8.encode('中文 hello'))),
        '中文 hello');
    expect(decodePreviewText(Uint8List.fromList([0xef, 0xbb, 0xbf, 0x41])),
        'A');
    expect(decodePreviewText(Uint8List.fromList([
      0xff, 0xfe, 0x2d, 0x4e, 0x00, 0xd8, 0x00, 0xdc
    ])), '中𐀀');
    expect(decodePreviewText(Uint8List.fromList([0xfe, 0xff, 0x4e, 0x2d])),
        '中');
    expect(() => decodePreviewText(Uint8List.fromList([0xc3, 0x28])),
        throwsFormatException);
    expect(() => decodePreviewText(Uint8List.fromList([0xff, 0xfe, 0x41])),
        throwsFormatException);
  });

  test('external opener rejects invalid names and large files before fetch', () async {
    final api = _TestDocumentApi();
    addTearDown(api.close);
    expect(ExternalFileOpener.safeBasename('../hello.pdf'), 'hello.pdf');
    expect(ExternalFileOpener.safeBasename('../../.lightisle-config'), isNull);
    expect(ExternalFileOpener.safeBasename('evil\n.pdf'), isNull);
    await expectLater(
      ExternalFileOpener.open(
        api: api, path: 'data/file.pdf',
        name: 'file.pdf', size: 1024 * 1024 * 1024,
      ),
      throwsStateError,
    );
    expect(api.downloads, 0);
  });

  test('external opener passes only the verified local path and cleans failures', () async {
    final api = _TestDocumentApi();
    addTearDown(api.close);
    final root = await Directory.systemTemp.createTemp('lightisle-opener-test-');
    addTearDown(() => root.delete(recursive: true));
    String? openedPath;
    final answer = await ExternalFileOpener.open(
      api: api,
      path: 'personal/notes.pdf',
      name: 'notes.pdf',
      size: 4,
      temporaryRoot: root,
      opener: (local) async {
        openedPath = local;
        expect(await File(local).readAsBytes(), [0x25, 0x50, 0x44, 0x46]);
        return OpenResult(type: ResultType.done);
      },
    );
    expect(answer, contains('原文件未修改'));
    expect(api.lastPath, 'personal/notes.pdf');
    expect(openedPath, isNotNull);
    expect(openedPath, isNot(contains('127.0.0.1')));
    await expectLater(
      ExternalFileOpener.open(
        api: api, path: 'personal/notes.pdf',
        name: 'notes.pdf', size: 4,
        temporaryRoot: root,
        opener: (local) async => OpenResult(type: ResultType.noAppToOpen),
      ),
      throwsStateError,
    );
    expect((await root.list().toList()).length, 1,
        reason: 'failed handoff removed its sandbox copy');
  });
}
