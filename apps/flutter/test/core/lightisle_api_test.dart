import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';

part 'lightisle_api_tls_cases.dart';

const _sessionToken = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';

void main() {
  group('LightIsleApi', () {
    late HttpServer server;
    late HttpServer redirectTarget;
    late LightIsleApi api;
    late Uri baseUri;
    late String? lastCookie;
    late String? lastRequestHeader;
    late String? lastOffset;
    late String? lastBody;
    late String? lastQuery;
    var redirectHits = 0;
    var downloadHits = 0;
    var rangedVerificationSize = 0;
    var rangedVerificationRequests = 0;
    var rangedVerificationMismatchIndex = -1;
    var rangedVerificationVersionChangeIndex = -1;
    String rangedVerificationVersion = 'a' * 64;
    String defaultVerificationDigest = 'b' * 64;
    int defaultVerificationSize = 6;
    String? rangedVerificationFractionalField;
    List<String> rangedVerificationChunkDigests = <String>[];
    final rangedVerificationQueries = <Map<String, String>>[];
    String? firstVerificationQuery;
    final blockedDownloadRelease = Completer<void>();
    final blockedDownloadStarted = Completer<void>();
    final blockedDownloadFlushed = Completer<void>();
    final slowDownloadComplete = Completer<void>();

    setUp(() async {
      lastCookie = null;
      lastRequestHeader = null;
      lastOffset = null;
      lastBody = null;
      lastQuery = null;
      redirectHits = 0;
      downloadHits = 0;
      rangedVerificationSize = 0;
      rangedVerificationRequests = 0;
      rangedVerificationMismatchIndex = -1;
      rangedVerificationVersionChangeIndex = -1;
      rangedVerificationVersion = 'a' * 64;
      defaultVerificationDigest = 'b' * 64;
      defaultVerificationSize = 6;
      rangedVerificationFractionalField = null;
      rangedVerificationChunkDigests = <String>[];
      rangedVerificationQueries.clear();
      firstVerificationQuery = null;
      redirectTarget = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      redirectTarget.listen((request) async {
        redirectHits++;
        await _json(request.response, <String, Object>{'unexpected': true});
      });

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUri = Uri(scheme: 'http', host: '127.0.0.1', port: server.port);
      server.listen((request) async {
        switch (request.uri.path) {
          case '/login':
            request.response.headers.add(
              HttpHeaders.setCookieHeader,
              'lightisle_session=$_sessionToken; Path=/; HttpOnly; SameSite=Strict; Max-Age=3600',
            );
            await _json(request.response, <String, Object>{
              'authenticated': true,
            });
          case '/cookie-secure':
            request.response.headers.add(
              HttpHeaders.setCookieHeader,
              'lightisle_session=ZYXWVUTSRQPONMLKJIHGFEDCBA987654321; Path=/; HttpOnly; Secure',
            );
            await _json(request.response, <String, Object>{'ok': true});
          case '/cookie-domain':
            request.response.headers.add(
              HttpHeaders.setCookieHeader,
              'lightisle_session=ZYXWVUTSRQPONMLKJIHGFEDCBA987654321; Domain=wrong.example; Path=/; HttpOnly',
            );
            await _json(request.response, <String, Object>{'ok': true});
          case '/me':
            lastCookie = request.headers.value(HttpHeaders.cookieHeader);
            lastQuery = request.uri.query;
            await _json(request.response, <String, Object>{
              'authenticated': lastCookie != null,
            });
          case '/mutate':
            lastRequestHeader = request.headers.value('X-LightIsle-Request');
            lastCookie = request.headers.value(HttpHeaders.cookieHeader);
            lastBody = await utf8.decoder.bind(request).join();
            await _json(request.response, <String, Object>{'saved': true});
          case '/unauthorized':
            request.response.statusCode = HttpStatus.unauthorized;
            await _json(request.response, <String, Object>{
              'error': 'authentication_required',
            });
          case '/tmdb-auth-failed':
            request.response.statusCode = HttpStatus.unauthorized;
            await _json(request.response, <String, Object>{
              'error': 'tmdb_auth_failed',
            });
          case '/tmdb-access-denied':
            request.response.statusCode = HttpStatus.forbidden;
            await _json(request.response, <String, Object>{
              'error': 'tmdb_access_denied',
            });
          case '/invalid-login':
            request.response.statusCode = HttpStatus.unauthorized;
            await _json(request.response, <String, Object>{
              'error': 'invalid_credentials',
            });
          case '/malicious-error':
            request.response.statusCode = HttpStatus.internalServerError;
            await _json(request.response, <String, Object>{
              'error': _sessionToken,
            });
          case '/redirect':
            request.response.statusCode = HttpStatus.found;
            request.response.headers.set(
              HttpHeaders.locationHeader,
              'http://${InternetAddress.loopbackIPv4.address}:${redirectTarget.port}/steal',
            );
            await request.response.close();
          case '/large':
            request.response.headers.contentLength = 10;
            request.response.add(utf8.encode('0123456789'));
            await request.response.close();
          case '/binary':
            request.response.headers.contentType = ContentType(
              'application',
              'octet-stream',
            );
            request.response.add(<int>[0, 1, 2, 255]);
            await request.response.close();
          case '/api/v2/files/sha256':
            lastCookie = request.headers.value(HttpHeaders.cookieHeader);
            final query = request.uri.queryParameters;
            firstVerificationQuery ??= request.uri.query;
            if (query['mode'] == 'range') {
              rangedVerificationRequests++;
              rangedVerificationQueries.add(Map<String, String>.from(query));
              final offset = int.parse(query['offset']!);
              final length = int.parse(query['length']!);
              final index = offset ~/ (4 * 1024 * 1024);
              var digest = rangedVerificationChunkDigests[index];
              if (index == rangedVerificationMismatchIndex) {
                digest = 'c' * 64;
              }
              final version = index == rangedVerificationVersionChangeIndex
                  ? 'd' * 64
                  : rangedVerificationVersion;
              final body = <String, Object>{
                'algorithm': 'sha256',
                'sha256': digest,
                'size': rangedVerificationSize,
                'offset': offset,
                'length': length,
                'version': version,
              };
              final fractional = rangedVerificationFractionalField;
              if (fractional != null) body[fractional] = 1.5;
              await _json(request.response, body);
            } else {
              await _json(request.response, <String, Object>{
                'algorithm': 'sha256',
                'sha256': defaultVerificationDigest,
                'size': defaultVerificationSize,
              });
            }
          case '/download':
            downloadHits++;
            request.response.headers.contentLength = 6;
            request.response.add(utf8.encode('abc'));
            await request.response.flush();
            request.response.add(utf8.encode('def'));
            await request.response.close();
          case '/slow-download':
            request.response.add(utf8.encode('partial'));
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 250));
            try {
              await request.response.close();
            } on Object {
              // The test client may already have timed out and cancelled.
            } finally {
              if (!slowDownloadComplete.isCompleted) {
                slowDownloadComplete.complete();
              }
            }
          case '/blocked-download':
            request.response.bufferOutput = false;
            if (!blockedDownloadStarted.isCompleted) {
              blockedDownloadStarted.complete();
            }
            request.response.add(List<int>.filled(64 * 1024, 0x5a));
            await request.response.flush();
            if (!blockedDownloadFlushed.isCompleted) {
              blockedDownloadFlushed.complete();
            }
            await blockedDownloadRelease.future;
            try {
              await request.response.close();
            } on Object {
              // The test client is expected to force-close this response.
            }
          case '/api/v2/uploads/upload-123':
            lastCookie = request.headers.value(HttpHeaders.cookieHeader);
            lastRequestHeader = request.headers.value('X-LightIsle-Request');
            lastOffset = request.headers.value('X-Upload-Offset');
            try {
              lastBody = await utf8.decoder.bind(request).join();
            } on HttpException {
              // The exact-length client deliberately aborts malformed chunks.
              return;
            }
            await _json(request.response, <String, Object>{'offset': 3});
          default:
            request.response.statusCode = HttpStatus.notFound;
            await _json(request.response, <String, Object>{
              'error': 'not_found',
            });
        }
      });
      api = LightIsleApi(baseUri.toString());
    });

    tearDown(() async {
      api.close();
      await server.close(force: true);
      await redirectTarget.close(force: true);
    });

    test(
      'public share URL uses exact disk root instead of legacy global route',
      () {
        final token = 'capability-token_abc123';
        expect(
          api.publicFileShareUri(token).path,
          '/api/v2/public/file/$token',
        );
        api.selectRoot(
          const LightIsleRoot(
            id: 'disk_family',
            name: '家庭盘',
            generation: 7,
            online: true,
          ),
        );
        final url = api.publicFileShareUri(token);
        expect(url.origin, baseUri.origin);
        expect(url.path, '/api/v2/roots/disk_family/public/file/$token');
        expect(url.query, isEmpty);
        expect(() => api.publicFileShareUri(''), throwsArgumentError);
        expect(() => api.publicFileShareUri('../other'), throwsArgumentError);
      },
    );

    test('encodes query values and rejects unsafe paths and URLs', () {
      final requestUri = api.uri('/api/v2/files', <String, String>{
        'path': 'Photos/A&B + C.jpg',
        'search': 'a/b?c',
      });
      expect(requestUri.queryParameters['path'], 'Photos/A&B + C.jpg');
      expect(requestUri.queryParameters['search'], 'a/b?c');
      expect(requestUri.origin, baseUri.origin);

      expect(() => api.uri('//attacker.example/path'), throwsArgumentError);
      expect(() => api.uri('/api/v2/../auth/me'), throwsArgumentError);
      expect(() => LightIsleApi('http://example.com'), throwsArgumentError);
      expect(
        () => LightIsleApi('http://192.168.1.20:8080'),
        throwsArgumentError,
      );
      expect(
        LightIsleApi(
          'http://192.168.1.20:8080',
          allowInsecureHttp: true,
        ).uri('/api').host,
        '192.168.1.20',
      );
      expect(
        () => LightIsleApi('http://example.com', allowInsecureHttp: true),
        throwsArgumentError,
      );
      try {
        LightIsleApi('https://owner:very-secret@server.example/private');
        fail('invalid URL should be rejected');
      } on ArgumentError catch (error) {
        expect(error.toString(), isNot(contains('very-secret')));
        expect(error.toString(), isNot(contains('private')));
      }
    });

    test(
      'keeps the session cookie in memory and sends it only as a header',
      () async {
        await api.get('/login');
        expect(api.authenticated, isTrue);
        expect(
          api.mediaHeaders[HttpHeaders.cookieHeader],
          'lightisle_session=$_sessionToken',
        );
        expect(
          () => api.uri('/me', <String, String>{
            'lightisle_session': _sessionToken,
          }),
          throwsArgumentError,
        );
        expect(() => api.uri('/$_sessionToken'), throwsArgumentError);

        await api.get('/me', query: <String, String>{'name': 'Isle & Light'});
        expect(lastCookie, 'lightisle_session=$_sessionToken');
        expect(lastQuery, 'name=Isle+%26+Light');
        expect(api.uri('/me').query, isEmpty);
        expect(await api.mediaUri('/binary'), api.uri('/binary'));
        expect(api.nativeMediaHeaders, api.mediaHeaders);
      },
    );

    test(
      'keeps small remote SHA verification on the legacy endpoint',
      () async {
        final digest = sha256.convert(utf8.encode('small original')).toString();
        defaultVerificationDigest = digest;
        defaultVerificationSize = 6;

        expect(
          await api.remoteFileMatchesSHA256('PhonePhotos/small.jpg', 6, digest),
          isTrue,
        );
        expect(rangedVerificationRequests, 0);
        expect(firstVerificationQuery, 'path=PhonePhotos%2Fsmall.jpg');
      },
    );

    test(
      'checks large originals by bounded contiguous ranges and one version',
      () async {
        rangedVerificationSize = (2 << 30) + 1;
        final count =
            (rangedVerificationSize + 4 * 1024 * 1024 - 1) ~/ (4 * 1024 * 1024);
        rangedVerificationChunkDigests = List<String>.generate(
          count,
          (index) => sha256.convert(utf8.encode('range-$index')).toString(),
        );
        final wholeDigest = sha256
            .convert(utf8.encode('complete local digest'))
            .toString();

        expect(
          await api.remoteFileMatchesSHA256(
            'PhonePhotos/large.mov',
            rangedVerificationSize,
            wholeDigest,
            chunkSHA256s: rangedVerificationChunkDigests,
          ),
          isTrue,
        );
        expect(rangedVerificationRequests, count);
        expect(rangedVerificationQueries.first['offset'], '0');
        expect(rangedVerificationQueries.first['length'], '${4 * 1024 * 1024}');
        expect(rangedVerificationQueries.first.containsKey('version'), isFalse);
        expect(
          rangedVerificationQueries[1]['version'],
          rangedVerificationVersion,
        );
        expect(rangedVerificationQueries.last['offset'], '${2 << 30}');
        expect(rangedVerificationQueries.last['length'], '1');
      },
    );

    test(
      'large range verification rejects changed bytes or generation',
      () async {
        rangedVerificationSize = (2 << 30) + 1;
        final count =
            (rangedVerificationSize + 4 * 1024 * 1024 - 1) ~/ (4 * 1024 * 1024);
        rangedVerificationChunkDigests = List<String>.generate(
          count,
          (index) => sha256.convert(utf8.encode('range-$index')).toString(),
        );
        final wholeDigest = sha256
            .convert(utf8.encode('complete local digest'))
            .toString();
        rangedVerificationMismatchIndex = 1;

        expect(
          await api.remoteFileMatchesSHA256(
            'PhonePhotos/large.mov',
            rangedVerificationSize,
            wholeDigest,
            chunkSHA256s: rangedVerificationChunkDigests,
          ),
          isFalse,
        );
        expect(rangedVerificationRequests, 2);

        rangedVerificationRequests = 0;
        rangedVerificationQueries.clear();
        rangedVerificationMismatchIndex = -1;
        rangedVerificationVersionChangeIndex = 1;
        expect(
          await api.remoteFileMatchesSHA256(
            'PhonePhotos/large.mov',
            rangedVerificationSize,
            wholeDigest,
            chunkSHA256s: rangedVerificationChunkDigests,
          ),
          isFalse,
        );
        expect(rangedVerificationRequests, 2);
      },
    );

    test(
      'large range verification stops before the next request when canceled',
      () async {
        rangedVerificationSize = (2 << 30) + 1;
        final count =
            (rangedVerificationSize + 4 * 1024 * 1024 - 1) ~/ (4 * 1024 * 1024);
        rangedVerificationChunkDigests = List<String>.generate(
          count,
          (index) => sha256.convert(utf8.encode('range-$index')).toString(),
        );
        final wholeDigest = sha256
            .convert(utf8.encode('complete local digest'))
            .toString();

        await expectLater(
          api.remoteFileMatchesSHA256(
            'PhonePhotos/large.mov',
            rangedVerificationSize,
            wholeDigest,
            chunkSHA256s: rangedVerificationChunkDigests,
            checkActive: () {
              if (rangedVerificationRequests > 0) {
                throw const _VerificationCancelled();
              }
            },
          ),
          throwsA(isA<_VerificationCancelled>()),
        );
        expect(rangedVerificationRequests, 1);
      },
    );

    test('large range response requires exact integer metadata', () async {
      rangedVerificationSize = (2 << 30) + 1;
      final count =
          (rangedVerificationSize + 4 * 1024 * 1024 - 1) ~/ (4 * 1024 * 1024);
      rangedVerificationChunkDigests = List<String>.generate(
        count,
        (index) => sha256.convert(utf8.encode('range-$index')).toString(),
      );
      rangedVerificationFractionalField = 'offset';

      await expectLater(
        api.remoteFileMatchesSHA256(
          'PhonePhotos/large.mov',
          rangedVerificationSize,
          sha256.convert(utf8.encode('complete local digest')).toString(),
          chunkSHA256s: rangedVerificationChunkDigests,
        ),
        throwsA(
          isA<LightIsleApiException>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );
      expect(rangedVerificationRequests, 1);
      await expectLater(
        api.remoteFileMatchesSHA256(
          'PhonePhotos/large.mov',
          (32 << 30) + 1,
          'f' * 64,
        ),
        throwsArgumentError,
      );
    });

    test('adds the application header and JSON body to mutations', () async {
      await api.get('/login');
      await api.send(
        'post',
        '/mutate',
        body: <String, Object>{'name': '家庭 相册'},
      );

      expect(lastRequestHeader, '1');
      expect(lastCookie, 'lightisle_session=$_sessionToken');
      expect(jsonDecode(lastBody!), <String, Object>{'name': '家庭 相册'});
    });

    test('clears the cookie only for authentication_required', () async {
      var unauthorizedCalls = 0;
      api.onUnauthorized = () => unauthorizedCalls++;
      await api.get('/login');

      await expectLater(
        api.get('/invalid-login'),
        throwsA(
          isA<LightIsleApiException>().having(
            (error) => error.code,
            'code',
            'invalid_credentials',
          ),
        ),
      );
      expect(api.authenticated, isTrue);
      expect(unauthorizedCalls, 0);

      for (final entry in const <String, String>{
        '/tmdb-auth-failed': 'tmdb_auth_failed',
        '/tmdb-access-denied': 'tmdb_access_denied',
      }.entries) {
        await expectLater(
          api.get(entry.key),
          throwsA(
            isA<LightIsleApiException>().having(
              (error) => error.code,
              'code',
              entry.value,
            ),
          ),
        );
        expect(api.authenticated, isTrue);
        expect(
          api.mediaHeaders[HttpHeaders.cookieHeader],
          'lightisle_session=$_sessionToken',
        );
        expect(unauthorizedCalls, 0);
      }

      await expectLater(
        api.get('/unauthorized'),
        throwsA(
          isA<LightIsleApiException>().having(
            (error) => error.code,
            'code',
            'authentication_required',
          ),
        ),
      );
      expect(api.authenticated, isFalse);
      expect(api.mediaHeaders, isEmpty);
      expect(unauthorizedCalls, 1);
    });

    test('does not follow redirects with an authentication cookie', () async {
      await api.get('/login');

      await expectLater(
        api.get('/redirect'),
        throwsA(
          isA<LightIsleApiException>().having(
            (error) => error.code,
            'code',
            'redirect_not_allowed',
          ),
        ),
      );
      expect(redirectHits, 0);
    });

    test('redacts a server error that echoes the session token', () async {
      await api.get('/login');

      await expectLater(
        api.get('/malicious-error'),
        throwsA(
          isA<LightIsleApiException>()
              .having((error) => error.code, 'code', 'server_error')
              .having(
                (error) => error.toString(),
                'message',
                isNot(contains(_sessionToken)),
              ),
        ),
      );
    });

    test('closes oversized responses without waiting for their body', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final disconnected = Completer<void>();
      Socket? peer;
      addTearDown(() async {
        peer?.destroy();
        await server.close();
      });
      server.listen((socket) {
        peer = socket;
        var request = '';
        socket.listen((chunk) {
          request += ascii.decode(chunk);
          if (!request.contains('\r\n\r\n')) return;
          socket.write('HTTP/1.1 200 OK\r\nContent-Length: 1048576\r\n\r\nx');
        }, onDone: () => disconnected.complete());
      });
      final client = LightIsleApi('http://127.0.0.1:${server.port}');
      addTearDown(client.close);

      await expectLater(
        client.bytes('/oversized', maxBytes: 5),
        throwsA(
          isA<LightIsleApiException>().having(
            (error) => error.code,
            'code',
            'response_too_large',
          ),
        ),
      );
      await disconnected.future.timeout(const Duration(seconds: 3));
    });

    test('bounds binary reads and returns binary data', () async {
      expect(
        await api.bytes('/binary'),
        Uint8List.fromList(<int>[0, 1, 2, 255]),
      );
      await expectLater(
        api.bytes('/large', maxBytes: 5),
        throwsA(
          isA<LightIsleApiException>().having(
            (error) => error.code,
            'code',
            'response_too_large',
          ),
        ),
      );
    });

    test(
      'streams downloads with progress without overwriting an existing file',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'lightisle-api-test-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final destination = '${directory.path}/nested/media.bin';
        final progress = <(int, int)>[];

        await api.download(
          '/download',
          destination,
          onProgress: (received, total) => progress.add((received, total)),
        );

        expect(await File(destination).readAsString(), 'abcdef');
        expect(progress.first, (0, 6));
        expect(progress.last, (6, 6));

        final existingDestination = '${directory.path}/keep.bin';
        await File(existingDestination).writeAsString('keep me');
        final requestsBefore = downloadHits;
        await expectLater(
          api.download('/download', existingDestination),
          throwsA(
            isA<LightIsleApiException>().having(
              (error) => error.code,
              'code',
              'destination_exists',
            ),
          ),
        );
        expect(await File(existingDestination).readAsString(), 'keep me');
        expect(downloadHits, requestsBefore);
      },
    );

    test('ignores Secure and foreign Domain session cookies', () async {
      await api.get('/login');
      await api.get('/cookie-secure');
      expect(api.authenticated, isTrue);
      expect(
        api.mediaHeaders[HttpHeaders.cookieHeader],
        'lightisle_session=$_sessionToken',
      );

      await api.get('/cookie-domain');
      expect(api.authenticated, isTrue);
      expect(
        api.mediaHeaders[HttpHeaders.cookieHeader],
        'lightisle_session=$_sessionToken',
      );
    });

    test('times out a stalled download and removes its partial file', () async {
      final directory = await Directory.systemTemp.createTemp(
        'lightisle-api-timeout-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final destination = '${directory.path}/stalled.bin';
      final shortTimeoutApi = LightIsleApi(
        baseUri.toString(),
        requestTimeout: const Duration(milliseconds: 60),
      );
      addTearDown(shortTimeoutApi.close);

      await expectLater(
        shortTimeoutApi.download('/slow-download', destination),
        throwsA(
          isA<LightIsleApiException>().having(
            (error) => error.code,
            'code',
            'network_timeout',
          ),
        ),
      );
      await slowDownloadComplete.future.timeout(const Duration(seconds: 2));
      expect(await File(destination).exists(), isFalse);
      expect(await _partialFiles(directory), isEmpty);
    });

    test('force-close aborts a download and removes partial files', () async {
      final directory = await Directory.systemTemp.createTemp(
        'lightisle-api-abort-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final destination = '${directory.path}/aborted.bin';
      final closingApi = LightIsleApi(baseUri.toString());
      final firstChunk = Completer<void>();
      final transfer = closingApi.download(
        '/blocked-download',
        destination,
        onProgress: (received, _) {
          if (received > 0 && !firstChunk.isCompleted) firstChunk.complete();
        },
      );
      final transferExpectation = expectLater(
        transfer,
        throwsA(isA<LightIsleApiException>()),
      );

      try {
        await blockedDownloadStarted.future.timeout(const Duration(seconds: 2));
        await blockedDownloadFlushed.future.timeout(const Duration(seconds: 2));
        await firstChunk.future.timeout(const Duration(seconds: 2));
        closingApi.close();
        await transferExpectation;
      } finally {
        if (!blockedDownloadRelease.isCompleted) {
          blockedDownloadRelease.complete();
        }
        closingApi.close();
      }

      expect(await File(destination).exists(), isFalse);
      expect(await _partialFiles(directory), isEmpty);
    });

    test(
      'uploads exact chunk lengths with offset and session headers',
      () async {
        await api.get('/login');
        final result = await api.uploadChunk(
          'upload-123',
          Stream<List<int>>.value(utf8.encode('abc')),
          3,
          7,
        );

        expect(result['offset'], 3);
        expect(lastCookie, 'lightisle_session=$_sessionToken');
        expect(lastRequestHeader, '1');
        expect(lastOffset, '7');
        expect(lastBody, 'abc');
        await expectLater(
          api.uploadChunk(
            'upload-123',
            Stream<List<int>>.value(<int>[1]),
            2,
            0,
          ),
          throwsA(
            isA<LightIsleApiException>().having(
              (error) => error.code,
              'code',
              'upload_length_mismatch',
            ),
          ),
        );
        await expectLater(
          api.uploadChunk(
            'upload-123',
            Stream<List<int>>.value(<int>[1, 2, 3]),
            2,
            0,
          ),
          throwsA(
            isA<LightIsleApiException>().having(
              (error) => error.code,
              'code',
              'upload_length_mismatch',
            ),
          ),
        );
      },
    );

    test('LightIsleApi can be subclassed for feature tests', () async {
      final fake = _FakeLightIsleApi();
      expect(await fake.get('/api/v2/files'), <String, dynamic>{'entries': []});
      fake.close();
    });
  });

  _registerPinnedHttpsTests();
}

Future<void> _json(HttpResponse response, Map<String, Object> body) async {
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(body));
  await response.close();
}

Future<List<File>> _partialFiles(Directory directory) async => directory
    .listSync()
    .whereType<File>()
    .where((file) => file.path.endsWith('.part'))
    .toList();

class _FakeLightIsleApi extends LightIsleApi {
  _FakeLightIsleApi() : super('http://127.0.0.1');

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async => <String, dynamic>{'entries': <dynamic>[]};
}

class _VerificationCancelled implements Exception {
  const _VerificationCancelled();
}
