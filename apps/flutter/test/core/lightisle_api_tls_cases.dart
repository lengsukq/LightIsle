part of 'lightisle_api_test.dart';

void _registerPinnedHttpsTests() {
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
