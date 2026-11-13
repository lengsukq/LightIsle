import 'dart:convert';

import '../../core/lightisle_api.dart';
import 'media_models.dart';
import 'subtitle_import.dart';

/// Resolves subtitles only. The detail screen owns captions, film identity,
/// language selection, and stale-response rejection.
class CinemaSubtitleRepository {
  const CinemaSubtitleRepository(
    this.api, {
    this.pickLocal = pickLocalSubtitle,
  });

  final LightIsleApi api;
  final Future<LocalSubtitle?> Function() pickLocal;

  Future<List<SubtitleCue>> load(int filmId, String language) async {
    if (language == 'off') return const [];
    final embedded = language.startsWith('emb:');
    final query = embedded
        ? <String, String>{'track': language.substring(4)}
        : language == 'auto'
        ? null
        : <String, String>{'lang': language};
    final bytes = await api.bytes(
      embedded
          ? '/api/v2/cinema/$filmId/embedded-subtitles'
          : '/api/v2/cinema/$filmId/subtitles',
      query: query,
      maxBytes: 1 << 20,
    );
    return List.unmodifiable(
      parseSubtitleText(utf8.decode(bytes, allowMalformed: true)),
    );
  }

  /// The selected file is never uploaded. Only the local subtitle timeline
  /// enters the current playback session.
  Future<({String name, List<SubtitleCue> cues})?> importLocal() async {
    final selected = await pickLocal();
    if (selected == null) return null;
    final cues = parseSubtitleText(selected.contents);
    if (cues.isEmpty) {
      throw const FormatException('没有找到有效的字幕时间轴');
    }
    return (name: selected.name, cues: List<SubtitleCue>.unmodifiable(cues));
  }
}
