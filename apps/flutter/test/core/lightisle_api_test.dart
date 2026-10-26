import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/lightisle_api.dart';

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
          case '/api/v1/files/sha256':
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
          case '/api/v1/uploads/upload-123':
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

    test('encodes query values and rejects unsafe paths and URLs', () {
      final requestUri = api.uri('/api/v1/files', <String, String>{
        'path': 'Photos/A&B + C.jpg',
        'search': 'a/b?c',
      });
      expect(requestUri.queryParameters['path'], 'Photos/A&B + C.jpg');
      expect(requestUri.queryParameters['search'], 'a/b?c');
      expect(requestUri.origin, baseUri.origin);

      expect(() => api.uri('//attacker.example/path'), throwsArgumentError);
      expect(() => api.uri('/api/v1/../auth/me'), throwsArgumentError);
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
      expect(await fake.get('/api/v1/files'), <String, dynamic>{'entries': []});
      fake.close();
    });
  });

  group('LightIsleApi pinned HTTPS', () {
    late Directory certificateDirectory;
    late String certificatePath;
    late String privateKeyPath;
    late String certificatePem;
    late String fingerprint;
    late HttpServer server;
    late LightIsleApi api;
    late Uri baseUri;
    var requestCount = 0;
    String? upstreamCookie;
    String? upstreamRange;

    setUpAll(() async {
      certificateDirectory = await Directory.systemTemp.createTemp(
        'lightisle-api-cert-',
      );
      certificatePath = '${certificateDirectory.path}/server-cert.pem';
      privateKeyPath = '${certificateDirectory.path}/server-key.pem';
      final generated = await Process.run('openssl', <String>[
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-keyout',
        privateKeyPath,
        '-out',
        certificatePath,
        '-days',
        '2',
        '-subj',
        '/CN=127.0.0.1',
        '-addext',
        'subjectAltName=IP:127.0.0.1',
        '-addext',
        'basicConstraints=critical,CA:TRUE',
      ]);
      expect(
        generated.exitCode,
        0,
        reason: 'The local OpenSSL certificate fixture must be generated.',
      );
      certificatePem = await File(certificatePath).readAsString();
      final encoded = certificatePem
          .split('\n')
          .where((line) => !line.startsWith('-----'))
          .join();
      final der = base64.decode(encoded);
      fingerprint = sha256.convert(der).toString();
    });

    tearDownAll(() async {
      await certificateDirectory.delete(recursive: true);
    });

    setUp(() async {
      requestCount = 0;
      upstreamCookie = null;
      upstreamRange = null;
      final serverContext = SecurityContext()
        ..useCertificateChain(certificatePath)
        ..usePrivateKey(privateKeyPath);
      server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
      );
      baseUri = Uri(
        scheme: 'https',
        host: InternetAddress.loopbackIPv4.address,
        port: server.port,
      );
      server.listen((request) async {
        requestCount++;
        if (request.uri.path == '/login') {
          request.response.headers.add(
            HttpHeaders.setCookieHeader,
            'lightisle_session=$_sessionToken; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=3600',
          );
          await _json(request.response, <String, Object>{
            'authenticated': true,
          });
          return;
        }
        if (request.uri.path == '/media') {
          upstreamCookie = request.headers.value(HttpHeaders.cookieHeader);
          upstreamRange = request.headers.value(HttpHeaders.rangeHeader);
          final range = upstreamRange;
          if (range case final value? when value == 'bytes=2-4') {
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes 2-4/8',
            );
            request.response.headers.contentLength = 3;
            request.response.headers.contentType = ContentType.text;
            request.response.write('cde');
          } else {
            request.response.headers.contentLength = 8;
            request.response.headers.contentType = ContentType.text;
            request.response.write('abcdefgh');
          }
          await request.response.close();
          return;
        }
        if (request.uri.path == '/redirect') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '${baseUri.origin}/login',
          );
          await request.response.close();
          return;
        }
        request.response.statusCode = HttpStatus.notFound;
        await _json(request.response, <String, Object>{'error': 'not_found'});
      });
      api = LightIsleApi(
        baseUri.toString(),
        certificateFingerprint: fingerprint,
      );
    });

    tearDown(() async {
      api.close();
      await server.close(force: true);
    });

    test('normalizes a pin and verifies it before sending a session', () async {
      final formatted = fingerprint.toUpperCase().replaceAllMapped(
        RegExp(r'.{2}'),
        (match) => '${match[0]}:',
      );
      final pinned = LightIsleApi(
        baseUri.toString(),
        certificateFingerprint: formatted,
      );
      addTearDown(pinned.close);

      expect(pinned.certificateFingerprint, fingerprint);
      expect((await pinned.get('/login'))['authenticated'], isTrue);
      expect(pinned.authenticated, isTrue);
      expect(requestCount, 1);
    });

    test('explains unpinned self-signed HTTPS certificate failures', () async {
      final unpinned = LightIsleApi(baseUri.toString());
      addTearDown(unpinned.close);

      await expectLater(
        unpinned.get('/login'),
        throwsA(
          isA<LightIsleApiException>()
              .having((error) => error.code, 'code', 'certificate_untrusted')
              .having(
                (error) => error.message,
                'message',
                contains('SHA-256 指纹'),
              ),
        ),
      );
      expect(requestCount, 0);
    });

    test('rejects an untrusted wrong pin before sending the request', () async {
      final wrongPin = List<String>.filled(64, '0').join();
      expect(wrongPin, isNot(fingerprint));
      final mismatched = LightIsleApi(
        baseUri.toString(),
        certificateFingerprint: wrongPin,
      );
      addTearDown(mismatched.close);

      await expectLater(
        mismatched.get('/login'),
        throwsA(
          isA<LightIsleApiException>()
              .having((error) => error.code, 'code', 'certificate_mismatch')
              .having(
                (error) => error.toString(),
                'message',
                isNot(contains(wrongPin)),
              ),
        ),
      );
      expect(requestCount, 0);
    });

    test(
      'checks pins on trusted certificates before sending credentials',
      () async {
        final wrongPin = List<String>.filled(64, '0').join();
        final trustPinnedFixture = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificatesBytes(utf8.encode(certificatePem));
        final mismatched = LightIsleApi(
          baseUri.toString(),
          certificateFingerprint: wrongPin,
          securityContext: trustPinnedFixture,
        );
        addTearDown(mismatched.close);

        await expectLater(
          mismatched.get('/login'),
          throwsA(
            isA<LightIsleApiException>().having(
              (error) => error.code,
              'code',
              'certificate_mismatch',
            ),
          ),
        );
        expect(requestCount, 0);
      },
    );

    test(
      'relays range requests with a local token and server cookie',
      () async {
        await api.get('/login');
        final media = await api.mediaUri('/media');
        final headers = api.nativeMediaHeaders;
        expect(media.scheme, 'http');
        expect(media.host, InternetAddress.loopbackIPv4.address);
        expect(media.port, isNot(baseUri.port));
        expect(media.query, isEmpty);
        expect(media.toString(), isNot(contains(_sessionToken)));
        expect(headers.keys, contains('X-LightIsle-Media-Token'));
        expect(headers.values.join(), isNot(contains(_sessionToken)));
        expect(headers.containsKey(HttpHeaders.cookieHeader), isFalse);

        final client = HttpClient();
        try {
          final request = await client.getUrl(media);
          headers.forEach(request.headers.set);
          request.headers.set(HttpHeaders.rangeHeader, 'bytes=2-4');
          final response = await request.close();
          expect(response.statusCode, HttpStatus.partialContent);
          expect(
            response.headers.value(HttpHeaders.contentRangeHeader),
            'bytes 2-4/8',
          );
          expect(await utf8.decoder.bind(response).join(), 'cde');
        } finally {
          client.close(force: true);
        }

        expect(upstreamRange, 'bytes=2-4');
        expect(upstreamCookie, 'lightisle_session=$_sessionToken');
      },
    );

    test('rejects relay requests without its per-client token', () async {
      await api.get('/login');
      final media = await api.mediaUri('/media');
      final before = requestCount;
      final client = HttpClient();
      try {
        final request = await client.getUrl(media);
        request.headers.set('X-LightIsle-Media-Token', 'wrong-token');
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, HttpStatus.forbidden);

        final duplicateRange = await client.getUrl(media);
        api.nativeMediaHeaders.forEach(duplicateRange.headers.set);
        duplicateRange.headers.add(HttpHeaders.rangeHeader, 'bytes=0-1');
        duplicateRange.headers.add(HttpHeaders.rangeHeader, 'bytes=2-3');
        final malformedResponse = await duplicateRange.close();
        await malformedResponse.drain<void>();
        expect(malformedResponse.statusCode, HttpStatus.badRequest);
      } finally {
        client.close(force: true);
      }
      expect(requestCount, before);
    });

    test('rejects duplicate relay authentication headers safely', () async {
      await api.get('/login');
      final media = await api.mediaUri('/media');
      final before = requestCount;
      final client = HttpClient();
      try {
        final request = await client.getUrl(media);
        request.headers.add(
          'X-LightIsle-Media-Token',
          api.nativeMediaHeaders['X-LightIsle-Media-Token']!,
        );
        request.headers.add('X-LightIsle-Media-Token', 'duplicate');
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, HttpStatus.forbidden);
      } finally {
        client.close(force: true);
      }
      expect(requestCount, before);
    });

    test('rejects malformed pins without echoing their value', () {
      const invalidPin = 'not-a-fingerprint';
      try {
        LightIsleApi(baseUri.toString(), certificateFingerprint: invalidPin);
        fail('invalid certificate fingerprint should be rejected');
      } on ArgumentError catch (error) {
        expect(error.toString(), isNot(contains(invalidPin)));
      }
    });

    test('requires HTTPS for pins and pins for custom trust contexts', () {
      expect(
        () => LightIsleApi(
          'http://127.0.0.1:8080',
          certificateFingerprint: fingerprint,
        ),
        throwsArgumentError,
      );
      expect(
        () => LightIsleApi(
          baseUri.toString(),
          securityContext: SecurityContext(withTrustedRoots: false),
        ),
        throwsArgumentError,
      );
    });

    test(
      'allows large media ranges and never follows upstream redirects',
      () async {
        await api.get('/login');
        final before = requestCount;
        final media = await api.mediaUri('/media');
        final client = HttpClient();
        try {
          final largeRange = await client.getUrl(media);
          api.nativeMediaHeaders.forEach(largeRange.headers.set);
          largeRange.headers.set(HttpHeaders.rangeHeader, 'bytes=0-67108864');
          final largeRangeResponse = await largeRange.close();
          await largeRangeResponse.drain<void>();
          expect(largeRangeResponse.statusCode, HttpStatus.ok);
          expect(upstreamRange, 'bytes=0-67108864');
          expect(requestCount, before + 1);

          final redirectedMedia = await api.mediaUri('/redirect');
          final redirected = await client.getUrl(redirectedMedia);
          api.nativeMediaHeaders.forEach(redirected.headers.set);
          final redirectResponse = await redirected.close();
          await redirectResponse.drain<void>();
          expect(redirectResponse.statusCode, HttpStatus.badGateway);
          expect(
            redirectResponse.headers.value(HttpHeaders.locationHeader),
            isNull,
          );
        } finally {
          client.close(force: true);
        }
        // The large range and /redirect reached the origin. The redirect target
        // was never contacted.
        expect(requestCount, before + 2);
      },
    );
  });
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
