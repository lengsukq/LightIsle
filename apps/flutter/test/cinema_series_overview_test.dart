import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lightisle/features/media/cinema_series_overview.dart';
import 'package:lightisle/features/media/media_models.dart';

void main() {
  testWidgets('series page groups episodes by season and retains navigation', (
    tester,
  ) async {
    final selected = <int>[];
    final films = <CinemaFilm>[
      for (final row in [
        {'id': 11, 'title': 'Episode one', 'season': 1, 'episode': 1},
        {'id': 22, 'title': 'Episode two', 'season': 2, 'episode': 1},
      ])
        CinemaFilm.fromJson(<String, Object>{
          ...row,
          'path': 'Shows/episode.mp4',
          'kind': 'series',
          'playable': true,
          'browserPlayback': 'verified-direct',
        }),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: CinemaSeriesOverview(
          series: const CinemaSeriesInfo(
            id: 1,
            name: 'Family Series',
            episodeCount: 2,
            watchedCount: 1,
          ),
          episodes: films,
          onEpisode: (film) async => selected.add(film.id),
        ),
      ),
    );

    expect(find.text('第 1 季'), findsOneWidget);
    expect(find.text('第 2 季'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('cinemaEpisode_22')));
    await tester.tap(find.byKey(const ValueKey('cinemaEpisode_22')));
    expect(selected, [22]);
    // Selecting an episode does not pop the season page.
    expect(find.byKey(const ValueKey('cinemaSeriesEpisodes')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
