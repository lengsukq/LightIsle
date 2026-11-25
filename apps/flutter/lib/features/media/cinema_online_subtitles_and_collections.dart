import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'media_models.dart';

/// Admin panel inside [CinemaFilmOverview] for one-click online subtitle
/// search/download (.zh.srt saved in-place) and family custom collections.
class CinemaOnlineSubtitlesAndCollectionsCard extends StatefulWidget {
  const CinemaOnlineSubtitlesAndCollectionsCard({
    super.key,
    required this.api,
    required this.film,
  });

  final LightIsleApi api;
  final CinemaFilm film;

  @override
  State<CinemaOnlineSubtitlesAndCollectionsCard> createState() =>
      _CinemaOnlineSubtitlesAndCollectionsCardState();
}

class _CinemaOnlineSubtitlesAndCollectionsCardState
    extends State<CinemaOnlineSubtitlesAndCollectionsCard> {
  late final TextEditingController _subQueryCtrl = TextEditingController(
    text: widget.film.title,
  );
  final TextEditingController _newColCtrl = TextEditingController();

  bool _subOpen = false;
  bool _subBusy = false;
  String? _subDownloadingUrl;
  String? _subError;
  String? _subNotice;
  List<Map<String, dynamic>> _subCandidates = const [];

  bool _colOpen = false;
  bool _colBusy = false;
  String? _colError;
  String? _colNotice;
  List<Map<String, dynamic>> _collections = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadCollections());
  }

  @override
  void dispose() {
    _subQueryCtrl.dispose();
    _newColCtrl.dispose();
    super.dispose();
  }

  Future<void> _searchSubtitles() async {
    if (_subBusy) return;
    setState(() {
      _subBusy = true;
      _subError = null;
      _subNotice = null;
    });
    try {
      final res = await widget.api.send(
        'POST',
        '/api/v2/cinema/${widget.film.id}/subtitles/search',
        body: {'query': _subQueryCtrl.text.trim()},
      );
      if (!mounted) return;
      final raw = res['candidates'];
      final list = raw is List
          ? raw
                .whereType<Map>()
                .map((m) => Map<String, dynamic>.from(m))
                .toList()
          : <Map<String, dynamic>>[];
      setState(() {
        _subCandidates = list;
        if (list.isEmpty) {
          _subNotice = '未找到匹配的在线字幕，可尝试缩短或改用英文原名搜索。';
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() => _subError = '搜索在线字幕失败：${userFacingError(e)}');
      }
    } finally {
      if (mounted) setState(() => _subBusy = false);
    }
  }

  Future<void> _downloadSubtitle(Map<String, dynamic> item) async {
    final url = item['url']?.toString() ?? '';
    if (url.isEmpty || _subDownloadingUrl != null) return;
    setState(() {
      _subDownloadingUrl = url;
      _subError = null;
      _subNotice = null;
    });
    try {
      final res = await widget.api.send(
        'POST',
        '/api/v2/cinema/${widget.film.id}/subtitles/download',
        body: {
          'url': url,
          'language': item['language']?.toString() ?? 'zh',
          'ext': item['ext']?.toString() ?? 'srt',
        },
      );
      if (!mounted) return;
      final saved = res['fileName']?.toString() ?? '字幕文件';
      setState(() => _subNotice = '已原位保存外挂字幕「$saved」至影片同目录，播放时自动加载。');
    } catch (e) {
      if (mounted) {
        setState(() => _subError = '下载字幕失败：${userFacingError(e)}');
      }
    } finally {
      if (mounted) setState(() => _subDownloadingUrl = null);
    }
  }

  Future<void> _loadCollections() async {
    try {
      final res = await widget.api.get('/api/v2/cinema-collections');
      if (!mounted) return;
      final raw = res['collections'];
      setState(() {
        _collections = raw is List
            ? raw
                  .whereType<Map>()
                  .map((m) => Map<String, dynamic>.from(m))
                  .toList()
            : const [];
      });
    } catch (e) {
      if (mounted) {
        setState(() => _colError = '读取影单失败：${userFacingError(e)}');
      }
    }
  }

  Future<void> _createCollection() async {
    final name = _newColCtrl.text.trim();
    if (name.isEmpty || _colBusy) return;
    setState(() {
      _colBusy = true;
      _colError = null;
      _colNotice = null;
    });
    try {
      final created = await widget.api.send(
        'POST',
        '/api/v2/cinema-collections',
        body: {'name': name},
      );
      _newColCtrl.clear();
      final newId = created['id'] is num
          ? (created['id'] as num).toInt()
          : int.tryParse('${created['id']}') ?? 0;
      if (newId > 0) {
        await widget.api.send(
          'POST',
          '/api/v2/cinema-collections/$newId/items',
          body: {'filmId': widget.film.id},
        );
      }
      if (!mounted) return;
      await _loadCollections();
      setState(() => _colNotice = '已创建影单「$name」并将当前影片加入其中。');
    } catch (e) {
      if (mounted) {
        setState(() => _colError = '创建影单失败：${userFacingError(e)}');
      }
    } finally {
      if (mounted) setState(() => _colBusy = false);
    }
  }

  Future<void> _addToCollection(Map<String, dynamic> col) async {
    final id = col['id'] is num ? (col['id'] as num).toInt() : 0;
    if (id <= 0 || _colBusy) return;
    setState(() {
      _colBusy = true;
      _colError = null;
      _colNotice = null;
    });
    try {
      await widget.api.send(
        'POST',
        '/api/v2/cinema-collections/$id/items',
        body: {'filmId': widget.film.id},
      );
      if (!mounted) return;
      await _loadCollections();
      setState(() => _colNotice = '已加入影单「${col['name'] ?? ''}」。');
    } catch (e) {
      if (mounted) {
        setState(() => _colError = '加入影单失败：${userFacingError(e)}');
      }
    } finally {
      if (mounted) setState(() => _colBusy = false);
    }
  }

  Future<void> _deleteCollection(Map<String, dynamic> col) async {
    final id = col['id'] is num ? (col['id'] as num).toInt() : 0;
    if (id <= 0 || _colBusy) return;
    setState(() {
      _colBusy = true;
      _colError = null;
      _colNotice = null;
    });
    try {
      await widget.api.send('DELETE', '/api/v2/cinema-collections/$id');
      if (!mounted) return;
      await _loadCollections();
      setState(() => _colNotice = '已删除影单「${col['name'] ?? ''}」。');
    } catch (e) {
      if (mounted) {
        setState(() => _colError = '删除影单失败：${userFacingError(e)}');
      }
    } finally {
      if (mounted) setState(() => _colBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IsleSurface(
      margin: EdgeInsets.zero,
      radius: IsleRadius.card,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => setState(() => _subOpen = !_subOpen),
                icon: const Icon(Icons.subtitles_outlined, size: 17),
                label: Text(_subOpen ? '收起在线字幕' : '在线搜刮字幕'),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () {
                  setState(() => _colOpen = !_colOpen);
                  if (_colOpen && _collections.isEmpty) {
                    unawaited(_loadCollections());
                  }
                },
                icon: const Icon(Icons.video_library_outlined, size: 17),
                label: Text(
                  _colOpen ? '收起家庭影单' : '家庭影单 (${_collections.length})',
                ),
              ),
            ],
          ),
          if (_subOpen) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _subQueryCtrl,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '搜索中英文字幕关键词',
                    ),
                    onSubmitted: (_) => unawaited(_searchSubtitles()),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: _subBusy ? null : _searchSubtitles,
                  child: Text(_subBusy ? '搜索中…' : '搜刮'),
                ),
              ],
            ),
            if (_subError != null) ...[
              const SizedBox(height: 8),
              Notice(_subError!, error: true),
            ],
            if (_subNotice != null) ...[
              const SizedBox(height: 8),
              Notice(_subNotice!),
            ],
            for (final item in _subCandidates)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  item['name']?.toString() ?? '未命名字幕',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '.${item['ext'] ?? 'srt'} · ${item['language'] ?? 'zh'}',
                ),
                trailing: FilledButton.tonal(
                  onPressed: _subDownloadingUrl != null
                      ? null
                      : () => _downloadSubtitle(item),
                  child: Text(
                    _subDownloadingUrl == item['url'] ? '保存中…' : '下载挂载',
                  ),
                ),
              ),
          ],
          if (_colOpen) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newColCtrl,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '新建家庭影单（如：宫崎骏全集 / 给孩子看）',
                    ),
                    onSubmitted: (_) => unawaited(_createCollection()),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: _colBusy ? null : _createCollection,
                  child: const Text('新建并加入'),
                ),
              ],
            ),
            if (_colError != null) ...[
              const SizedBox(height: 8),
              Notice(_colError!, error: true),
            ],
            if (_colNotice != null) ...[
              const SizedBox(height: 8),
              Notice(_colNotice!),
            ],
            if (_collections.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '暂无家庭影单，可在上方创建一个主题影单。',
                  style: theme.textTheme.bodySmall,
                ),
              )
            else
              for (final col in _collections)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(col['name']?.toString() ?? ''),
                  subtitle: Text('${col['count'] ?? 0} 部影片'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: _colBusy
                            ? null
                            : () => _addToCollection(col),
                        child: const Text('加入'),
                      ),
                      IconButton(
                        tooltip: '删除影单',
                        icon: const Icon(Icons.delete_outline_rounded, size: 18),
                        onPressed: _colBusy
                            ? null
                            : () => _deleteCollection(col),
                      ),
                    ],
                  ),
                ),
          ],
        ],
      ),
    );
  }
}
