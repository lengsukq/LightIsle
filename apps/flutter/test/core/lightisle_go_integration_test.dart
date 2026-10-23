import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';

final String? _coreBinary = Platform.environment['LIGHTISLE_TEST_CORE'];

void main() {
  test(
    'LightIsleApi interoperates with a temporary real Go core service',
    skip: _isAbsolutePath(_coreBinary) ? false : 'Set LIGHTISLE_TEST_CORE to an absolute path to a built Go core binary.',
    () async {
      final binary = _coreBinary!;
      final dataDirectory = await Directory.systemTemp.createTemp(
        'lightisle-go-api-data-',
      );
      final downloadDirectory = await Directory.systemTemp.createTemp(
        'lightisle-go-api-download-',
      );
      final sharedDirectory = Directory('${dataDirectory.path}/SharedFiles');
      await sharedDirectory.create(recursive: true);
      await File('${sharedDirectory.path}/api-fixture.png')
          .writeAsBytes(await _pngFixture());

      Process? process;
      LightIsleApi? ownerApi;
      LightIsleApi? memberApi;
      var exitedNormally = false;
      final stderr = StringBuffer();
      try {
        process = await Process.start(binary, <String>[
          '-port',
          '0',
          '-data-dir',
          dataDirectory.path,
        ], runInShell: false);
        process.stderr
            .transform(utf8.decoder)
            .listen(stderr.write, onError: (Object _) {});
        final output = StreamIterator<String>(
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter()),
        );

        final readyLine = await _nextLine(output, 'server ready');
        expect(readyLine, startsWith('LIGHTISLE_READY http://127.0.0.1:'));
        final serverUrl = readyLine.substring('LIGHTISLE_READY '.length);
        expect(
          await _nextLine(output, 'initial account state'),
          'LIGHTISLE_CONFIGURED 0',
        );
        expect(
          await _nextLine(output, 'shared folder state'),
          startsWith('LIGHTISLE_SHARE_ON '),
        );
        expect(
          await _nextLine(output, 'shared folder path'),
          startsWith('LIGHTISLE_SHARE_PATH '),
        );

        const ownerUsername = 'api_owner';
        const ownerPassword = 'integration-owner-password-123';
        final setupJson = jsonEncode(<String, String>{
          'username': ownerUsername,
          'password': ownerPassword,
        });
        final setupToken = base64Url
            .encode(utf8.encode(setupJson))
            .replaceAll('=', '');
        process.stdin.writeln('admin init $setupToken');
        await process.stdin.flush();
        expect(
          await _nextLine(output, 'admin initialization'),
          'LIGHTISLE_INITIALIZED',
        );
        final adminAccountLine = await _nextLine(
          output,
          'admin account confirmation',
        );
        expect(adminAccountLine, startsWith('LIGHTISLE_ADMIN_ACCOUNT '));
        final initializedAccount = utf8.decode(
          base64Url.decode(
            _padBase64Url(
              adminAccountLine.substring('LIGHTISLE_ADMIN_ACCOUNT '.length),
            ),
          ),
        );
        expect(initializedAccount, ownerUsername);

        ownerApi = LightIsleApi(serverUrl);
        final ownerIdentity = await ownerApi.send(
          'POST',
          '/api/v1/auth/login',
          body: <String, String>{
            'username': ownerUsername,
            'password': ownerPassword,
          },
        );
        expect(ownerIdentity['role'], 'admin');
        expect(ownerApi.authenticated, isTrue);
        expect(
          (await ownerApi.get('/api/v1/auth/me'))['username'],
          ownerUsername,
        );
        final ownerSessions = await ownerApi.get('/api/v1/auth/sessions');
        final sessionRows = ownerSessions['sessions'] as List<dynamic>;
        expect(
          sessionRows.cast<Map<String, dynamic>>().any(
            (session) => session['current'] == true,
          ),
          isTrue,
        );
        expect(ownerSessions['truncated'], isFalse);

        final initialAlerts = await ownerApi.get('/api/v1/alerts');
        expect(initialAlerts['alerts'], isA<List<dynamic>>());

        await ownerApi.send(
          'POST',
          '/api/v1/files/folders',
          body: <String, String>{'path': 'Integration'},
        );
        final folderListing = await ownerApi.get(
          '/api/v1/files',
          query: <String, String>{'path': 'Integration'},
        );
        expect(folderListing['entries'], isA<List<dynamic>>());

        final payload = Uint8List.fromList(
          List<int>.generate(131_071, (index) => (index * 31 + 7) & 0xff),
        );
        final upload = await ownerApi.send(
          'POST',
          '/api/v1/uploads',
          body: <String, Object>{
            'path': 'Integration/original.bin',
            'size': payload.length,
          },
        );
        final uploadId = upload['id'] as String;
        final uploadProgress = await ownerApi.uploadChunk(
          uploadId,
          Stream<List<int>>.value(payload),
          payload.length,
          0,
        );
        expect(uploadProgress['offset'], payload.length);
        await ownerApi.send('POST', '/api/v1/uploads/$uploadId/complete');

        final shareResponse = await ownerApi.send(
          'POST',
          '/api/v1/file-shares',
          body: <String, Object>{
            'path': 'Integration/original.bin',
            'hours': 1,
          },
        );
        final createdShare = shareResponse['share'] as Map<String, dynamic>;
        final shareId = createdShare['id'] as String;
        expect(shareResponse['token'], isA<String>());
        final listedShares = await ownerApi.get('/api/v1/file-shares');
        expect(
          (listedShares['shares'] as List<dynamic>)
              .cast<Map<String, dynamic>>()
              .any((share) => share['id'] == shareId),
          isTrue,
        );
        await ownerApi.send('DELETE', '/api/v1/file-shares/$shareId');
        final remainingShares = await ownerApi.get('/api/v1/file-shares');
        expect(
          (remainingShares['shares'] as List<dynamic>)
              .cast<Map<String, dynamic>>()
              .any((share) => share['id'] == shareId),
          isFalse,
        );

        final downloadedPath = '${downloadDirectory.path}/verified.bin';
        await ownerApi.download(
          '/api/v1/files/content',
          downloadedPath,
          query: <String, String>{'path': 'Integration/original.bin'},
        );
        expect(await File(downloadedPath).readAsBytes(), payload);

        await ownerApi.send(
          'POST',
          '/api/v1/files/operations',
          body: <String, String>{
            'action': 'move',
            'from': 'Integration/original.bin',
            'to': 'Integration/renamed.bin',
          },
        );
        await ownerApi.send(
          'DELETE',
          '/api/v1/files',
          query: <String, String>{'path': 'Integration/renamed.bin'},
        );
        final trash = await ownerApi.get('/api/v1/files/trash');
        final trashEntries = trash['entries'] as List<dynamic>;
        final trashedFile = trashEntries
            .cast<Map<String, dynamic>>()
            .firstWhere(
              (entry) => entry['originalPath'] == 'Integration/renamed.bin',
            );
        await ownerApi.send(
          'POST',
          '/api/v1/files/trash/${Uri.encodeComponent(trashedFile['id'] as String)}/restore',
        );
        final restoredListing = await ownerApi.get(
          '/api/v1/files',
          query: <String, String>{'path': 'Integration'},
        );
        expect(
          (restoredListing['entries'] as List<dynamic>)
              .cast<Map<String, dynamic>>()
              .any((entry) => entry['name'] == 'renamed.bin'),
          isTrue,
        );

        final scan = await ownerApi.send('POST', '/api/v1/photos/scan');
        expect(scan['started'], isTrue);
        Map<String, dynamic>? galleryStatus;
        for (var attempt = 0; attempt < 200; attempt++) {
          galleryStatus = await ownerApi.get('/api/v1/photos/status');
          if (galleryStatus['count'] == 1 &&
              galleryStatus['status'] is Map &&
              (galleryStatus['status'] as Map)['running'] == false) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(galleryStatus?['count'], 1);
        final gallery = await ownerApi.get('/api/v1/photos');
        final assets = (gallery['assets'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        final photo = assets.singleWhere(
          (asset) => asset['path'] == 'api-fixture.png',
        );
        final photoId = photo['id'].toString();
        await ownerApi.send(
          'POST',
          '/api/v1/photos/$photoId/personal-favorite',
          body: <String, bool>{'favorite': true},
        );
        final ownerFavorites = await ownerApi.get(
          '/api/v1/photos',
          query: <String, String>{'personal': '1'},
        );
        expect((ownerFavorites['assets'] as List<dynamic>).length, 1);
        final privateAlbum = await ownerApi.send(
          'POST',
          '/api/v1/photos/private-albums',
          body: <String, String>{'name': 'API owner album'},
        );
        final privateAlbumId = privateAlbum['id'].toString();
        await ownerApi.send(
          'POST',
          '/api/v1/photos/private-albums/$privateAlbumId/items',
          body: <String, int>{'assetId': int.parse(photoId)},
        );
        final ownerPrivateAlbums = await ownerApi.get(
          '/api/v1/photos/private-albums',
        );
        expect(
          (ownerPrivateAlbums['albums'] as List<dynamic>)
              .cast<Map<String, dynamic>>()
              .any((album) => album['id'].toString() == privateAlbumId),
          isTrue,
        );
        final ownerPrivateItems = await ownerApi.get(
          '/api/v1/photos',
          query: <String, String>{'privateAlbum': privateAlbumId},
        );
        expect((ownerPrivateItems['assets'] as List<dynamic>).length, 1);

        final member = await ownerApi.send(
          'POST',
          '/api/v1/users',
          body: <String, String>{
            'username': 'api_viewer',
            'password': 'integration-viewer-password-456',
            'role': 'member',
          },
        );
        final memberId = member['id'].toString();
        await ownerApi.send(
          'PUT',
          '/api/v1/users/$memberId/file-grants',
          body: <String, Object>{'path': '.', 'canWrite': false},
        );

        final tasks = await ownerApi.get('/api/v1/tasks');
        expect(tasks['tasks'], isA<List<dynamic>>());
        final history = await ownerApi.get('/api/v1/tasks/history');
        expect(history['runs'], isA<List<dynamic>>());
        expect(history['nextCursor'], isA<String>());

        memberApi = LightIsleApi(serverUrl);
        final memberIdentity = await memberApi.send(
          'POST',
          '/api/v1/auth/login',
          body: <String, String>{
            'username': 'api_viewer',
            'password': 'integration-viewer-password-456',
          },
        );
        expect(memberIdentity['role'], 'member');
        expect(memberApi.authenticated, isTrue);
        final memberListing = await memberApi.get(
          '/api/v1/files',
          query: <String, String>{'path': '.'},
        );
        expect(memberListing['canWrite'], isFalse);
        final memberSessions = await memberApi.get('/api/v1/auth/sessions');
        expect(
          (memberSessions['sessions'] as List<dynamic>)
              .cast<Map<String, dynamic>>()
              .any((session) => session['current'] == true),
          isTrue,
        );
        final memberPrivateAlbums = await memberApi.get(
          '/api/v1/photos/private-albums',
        );
        expect(memberPrivateAlbums['albums'], isEmpty);
        final memberFavorites = await memberApi.get(
          '/api/v1/photos',
          query: <String, String>{'personal': '1'},
        );
        expect(memberFavorites['assets'], isEmpty);
        await expectLater(
          memberApi.get(
            '/api/v1/photos',
            query: <String, String>{'privateAlbum': privateAlbumId},
          ),
          throwsA(
            isA<LightIsleApiException>().having(
              (error) => error.statusCode,
              'statusCode',
              404,
            ),
          ),
        );
        final adminAudit = await ownerApi.get('/api/v1/audit');
        expect(adminAudit['events'], isA<List<dynamic>>());
        expect((adminAudit['events'] as List<dynamic>), isNotEmpty);
        final historicalAlerts = await ownerApi.get(
          '/api/v1/alerts',
          query: <String, String>{'history': '1'},
        );
        expect(historicalAlerts['alerts'], isA<List<dynamic>>());
        await expectLater(
          memberApi.send(
            'POST',
            '/api/v1/files/folders',
            body: <String, String>{'path': 'Denied'},
          ),
          throwsA(
            isA<LightIsleApiException>()
                .having((error) => error.statusCode, 'statusCode', 403)
                .having(
                  (error) => error.code,
                  'code',
                  'file_permission_denied',
                ),
          ),
        );

        await ownerApi.send('POST', '/api/v1/auth/logout');
        expect(ownerApi.authenticated, isFalse);
        await expectLater(
          ownerApi.get('/api/v1/auth/me'),
          throwsA(
            isA<LightIsleApiException>().having(
              (error) => error.code,
              'code',
              'authentication_required',
            ),
          ),
        );
        expect(ownerApi.authenticated, isFalse);

        await memberApi.send('POST', '/api/v1/auth/logout');
        expect(memberApi.authenticated, isFalse);

        ownerApi.close();
        memberApi.close();
        process.stdin.close();
        final exitCode = await process.exitCode.timeout(
          const Duration(seconds: 15),
          onTimeout: () => -1,
        );
        expect(exitCode, 0, reason: 'Go service stderr: $stderr');
        exitedNormally = exitCode == 0;
      } finally {
        ownerApi?.close();
        memberApi?.close();
        if (process != null && !exitedNormally) {
          try {
            process.stdin.close();
          } on Object {
            // The process may already have closed its input pipe.
          }
          process.kill(ProcessSignal.sigkill);
          try {
            await process.exitCode.timeout(const Duration(seconds: 5));
          } on Object {
            // Cleanup must continue even if the test process did not exit.
          }
        }
        await dataDirectory.delete(recursive: true);
        await downloadDirectory.delete(recursive: true);
      }
    },
  );
}

Future<Uint8List> _pngFixture() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final paint = ui.Paint()..color = const ui.Color(0xff4287f5);
  canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 32, 24), paint);
  final picture = recorder.endRecording();
  final image = await picture.toImage(32, 24);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  if (data == null) throw StateError('Could not generate a PNG test fixture.');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

bool _isAbsolutePath(String? value) =>
    value != null && value.isNotEmpty && File(value).isAbsolute;

String _padBase64Url(String value) {
  final remainder = value.length % 4;
  if (remainder == 0) return value;
  return value.padRight(value.length + (4 - remainder), '=');
}

Future<String> _nextLine(StreamIterator<String> output, String stage) async {
  try {
    if (!await output.moveNext().timeout(const Duration(seconds: 15))) {
      throw StateError('Go core closed stdout before $stage.');
    }
    return output.current;
  } on TimeoutException {
    throw StateError('Timed out waiting for Go core $stage.');
  }
}
