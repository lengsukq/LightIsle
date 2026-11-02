import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/core/isle_theme.dart';
import 'package:lightisle/features/media/cinema_page.dart';
import 'package:lightisle/features/media/photos_page.dart';

import 'client_shell_test.dart' show FixtureApi;

class _MediaDataApi extends FixtureApi {
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/api/v2/photos') {
      return {
        'assets': List.generate(
          24,
          (i) => {
            'id': i + 1,
            'path': '家庭照片/冬日旅行与海边的夕阳_${i + 1}.jpg',
            'name': '冬日旅行与海边的夕阳_${i + 1}.jpg',
            'type': 'photo',
            'size': 2048000,
            'takenAt': 1793600000 - i * 86400,
            'canWrite': true,
            'favorite': i % 5 == 0,
          },
        ),
        'nextCursor': 0,
      };
    }
    if (path == '/api/v2/cinema') {
      return {
        'films': List.generate(
          16,
          (i) => {
            'id': i + 1,
            'title': '家庭电影收藏_${i + 1}_特别加长的影片标题与副标题',
            'path': '视频/电影_${i + 1}.mp4',
            'kind': 'movie',
            'size': 2150000000,
            'year': 2026,
            'duration': 5400,
            'position': i % 4 == 0 ? 120 : 0,
            'playable': true,
            'mime': 'video/mp4',
          },
        ),
        'nextCursor': 0,
      };
    }
    return super.get(path, query: query);
  }
}

void main() {
  for (final size in <Size>[
    const Size(320, 568),
    const Size(600, 840),
    const Size(1280, 800),
  ]) {
    for (final scale in <double>[1, 2]) {
      for (final cinema in <bool>[false, true]) {
        testWidgets(
          '${cinema ? 'Cinema' : 'Photos'} populated grid at $size / ${scale}x',
          (tester) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final api = _MediaDataApi();
            addTearDown(api.close);
            await tester.pumpWidget(
              MaterialApp(
                theme: buildIsleTheme(Brightness.light),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    disableAnimations: true,
                  ),
                  child: IsleCanvas(child: child!),
                ),
                home: Scaffold(
                  body: cinema
                      ? CinemaPage(
                          api: api,
                          isAdmin: true,
                          accountName: 'uid:1',
                        )
                      : PhotosPage(
                          api: api,
                          isAdmin: true,
                          accountName: 'owner',
                          offlineAccountId: 'uid:1',
                        ),
                ),
              ),
            );
            await tester.pump(const Duration(milliseconds: 600));
            expect(
              tester.takeException(),
              isNull,
              reason: 'initial populated grid at $size / $scale',
            );
            await tester.drag(
              find.byType(CustomScrollView).first,
              const Offset(0, -350),
            );
            await tester.pump(const Duration(milliseconds: 350));
            expect(
              tester.takeException(),
              isNull,
              reason: 'scrolling populated grid at $size / $scale',
            );
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
}
