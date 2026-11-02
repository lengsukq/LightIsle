import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/authenticated_media_image.dart';
import 'package:lightisle/core/lightisle_api.dart';

class _GatedImageApi extends LightIsleApi {
  _GatedImageApi() : super('http://127.0.0.1');

  final Completer<void> released = Completer<void>();
  int requests = 0;
  int active = 0;
  int peak = 0;

  @override
  Future<Uint8List> bytes(
    String path, {
    Map<String, String>? query,
    int? maxBytes,
  }) async {
    requests++;
    active++;
    if (active > peak) peak = active;
    await released.future;
    active--;
    return Uint8List(0);
  }
}

void main() {
  testWidgets('thumbnail requests have a bounded in-flight concurrency', (
    tester,
  ) async {
    final api = _GatedImageApi();
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (var i = 0; i < 10; i++)
                SizedBox(
                  width: 80,
                  height: 55,
                  child: AuthenticatedMediaImage(
                    api: api,
                    path: '/api/v2/photos/${i + 1}/thumbnail',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(api.requests, 6);
    expect(api.peak, 6);

    api.released.complete();
    await tester.pumpAndSettle();
    expect(api.requests, 10);
    expect(api.peak, 6);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
