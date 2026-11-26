import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'file_epub_parser.dart';
import 'file_extras_api.dart';
import 'file_models.dart';

export 'file_epub_parser.dart'
    show
        EpubChapterContent,
        EpubTextBlock,
        parseSafeEpubDocument,
        parseEpubOpfSpine;

/// Lightweight comic (`.cbz`/`.zip`) and EPUB (`.epub`) reader backed by
/// `/files/archive-entries`, `/files/archive-entry`, and `/files/reading-progress`.
class FileComicEpubReaderPage extends StatefulWidget {
  const FileComicEpubReaderPage({
    super.key,
    required this.api,
    required this.item,
  });

  final LightIsleApi api;
  final FileEntry item;

  @override
  State<FileComicEpubReaderPage> createState() =>
      _FileComicEpubReaderPageState();
}

class _FileComicEpubReaderPageState extends State<FileComicEpubReaderPage> {
  static const int _maxCachedImages = 16;

  late FileExtrasApi _extrasApi = FileExtrasApi(widget.api);
  final LinkedHashMap<String, Uint8List> _imageCache =
      LinkedHashMap<String, Uint8List>();
  final Map<String, Future<Uint8List>> _inflightImages =
      <String, Future<Uint8List>>{};
  final Map<String, EpubChapterContent> _chapterCache =
      <String, EpubChapterContent>{};
  final Map<String, Future<EpubChapterContent>> _inflightChapters =
      <String, Future<EpubChapterContent>>{};

  PageController? _pageController;
  final ScrollController _epubScrollController = ScrollController();

  bool _loading = true;
  String? _error;
  bool _isEpub = false;
  bool _verticalScroll = false;
  double _fontSize = 17;

  List<ArchiveEntryDescriptor> _comicPages = const [];
  List<ArchiveEntryDescriptor> _epubChapters = const [];
  int _currentIndex = 0;
  Future<EpubChapterContent>? _currentChapterFuture;
  int _loadGeneration = 0;

  Timer? _progressDebounce;
  String? _lastSavedLocator;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  @override
  void didUpdateWidget(covariant FileComicEpubReaderPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.path != widget.item.path || oldWidget.api != widget.api) {
      _progressDebounce?.cancel();
      _flushProgressNow(
        pathOverride: oldWidget.item.path,
        apiOverride: FileExtrasApi(oldWidget.api),
      );
      _extrasApi = FileExtrasApi(widget.api);
      _loadGeneration++;
      _imageCache.clear();
      _inflightImages.clear();
      _chapterCache.clear();
      _inflightChapters.clear();
      _currentChapterFuture = null;
      _comicPages = const [];
      _epubChapters = const [];
      _currentIndex = 0;
      _lastSavedLocator = null;
      unawaited(_initialize());
    }
  }

  @override
  void dispose() {
    _progressDebounce?.cancel();
    _flushProgressNow();
    _pageController?.dispose();
    _epubScrollController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    final generation = ++_loadGeneration;
    final path = widget.item.path;
    final extras = _extrasApi;
    setState(() {
      _loading = true;
      _error = null;
      _currentChapterFuture = null;
    });
    try {
      final response = await extras.listArchiveEntries(path);
      if (!mounted || generation != _loadGeneration) return;
      final isEpub = response.format == 'epub' ||
          widget.item.name.toLowerCase().endsWith('.epub');
      List<ArchiveEntryDescriptor> comicPages = const [];
      List<ArchiveEntryDescriptor> epubChapters = const [];

      if (isEpub) {
        epubChapters = await _resolveEpubChapters(
          response.entries,
          path: path,
          extras: extras,
        );
      } else {
        comicPages = response.entries.where((e) => e.isImage).toList();
      }
      if (!mounted || generation != _loadGeneration) return;

      var initialIndex = 0;
      try {
        final saved = await extras.getReadingProgress(path);
        if (saved != null) {
          initialIndex = _indexFromLocator(
            saved.locator,
            isEpub ? epubChapters.length : comicPages.length,
            epubChapters,
          );
        }
      } catch (_) {
        // Never block reading if progress lookup fails.
      }

      if (!mounted || generation != _loadGeneration) return;
      _pageController?.dispose();
      _pageController = PageController(initialPage: initialIndex);
      Future<EpubChapterContent>? chapterFuture;
      if (isEpub && epubChapters.isNotEmpty) {
        chapterFuture = _loadEpubChapterFor(
          epubChapters[initialIndex],
          initialIndex,
          generation: generation,
        );
      }
      setState(() {
        _isEpub = isEpub;
        _comicPages = comicPages;
        _epubChapters = epubChapters;
        _currentIndex = initialIndex;
        _currentChapterFuture = chapterFuture;
        _loading = false;
      });

      if (chapterFuture != null) {
        unawaited(chapterFuture.then<void>((_) {}, onError: (Object _) {}));
      } else if (!isEpub && comicPages.isNotEmpty) {
        _prefetchComicImage(comicPages[initialIndex]);
        if (initialIndex + 1 < comicPages.length) {
          _prefetchComicImage(comicPages[initialIndex + 1]);
        }
      }
    } catch (err) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = '打开轻阅读器失败：${userFacingError(err)}';
        _loading = false;
      });
    }
  }

  Future<List<ArchiveEntryDescriptor>> _resolveEpubChapters(
    List<ArchiveEntryDescriptor> entries, {
    required String path,
    required FileExtrasApi extras,
  }) async {
    final docByName = <String, ArchiveEntryDescriptor>{
      for (final e in entries)
        if (e.isDocument) e.name: e,
    };
    final opfEntry = entries.where(
      (e) => e.name.toLowerCase().endsWith('.opf'),
    );
    if (opfEntry.isNotEmpty) {
      try {
        final opfBytes = await extras.fetchArchiveEntryBytes(
          path,
          opfEntry.first.name,
          entryIndex: opfEntry.first.index,
          maxBytes: 2 * 1024 * 1024,
        );
        final opfXml = utf8.decode(opfBytes, allowMalformed: true);
        final spinePaths = parseEpubOpfSpine(opfXml, opfEntry.first.name);
        final ordered = <ArchiveEntryDescriptor>[];
        for (final spinePath in spinePaths) {
          final match = docByName[spinePath];
          if (match != null) ordered.add(match);
        }
        if (ordered.isNotEmpty) return ordered;
      } catch (_) {
        // Fall back to naturally sorted document entries.
      }
    }
    return entries.where((e) => e.isDocument).toList();
  }

  int _indexFromLocator(
    String locator,
    int total,
    List<ArchiveEntryDescriptor> chapters,
  ) {
    if (total <= 0) return 0;
    if (locator.startsWith('page:')) {
      final idx = int.tryParse(locator.substring(5)) ?? 0;
      return idx.clamp(0, total - 1);
    }
    if (locator.startsWith('chapter:')) {
      final rest = locator.substring(8);
      final colon = rest.indexOf(':');
      if (colon > 0) {
        final name = rest.substring(colon + 1);
        final byName = chapters.indexWhere((c) => c.name == name);
        if (byName >= 0) return byName;
        final idx = int.tryParse(rest.substring(0, colon)) ?? 0;
        return idx.clamp(0, total - 1);
      }
      final idx = int.tryParse(rest) ?? 0;
      return idx.clamp(0, total - 1);
    }
    return 0;
  }

  void _prefetchComicImage(ArchiveEntryDescriptor entry) {
    unawaited(
      _loadComicImage(entry).then<void>((_) {}, onError: (Object _) {}),
    );
  }

  Future<Uint8List> _loadComicImage(ArchiveEntryDescriptor entry) {
    final key = entry.cacheKey;
    final cached = _imageCache.remove(key);
    if (cached != null) {
      _imageCache[key] = cached;
      return Future<Uint8List>.value(cached);
    }
    final existing = _inflightImages[key];
    if (existing != null) return existing;
    final generation = _loadGeneration;
    final future = _extrasApi
        .fetchArchiveEntryBytes(
          widget.item.path,
          entry.name,
          entryIndex: entry.index,
        )
        .then((bytes) {
          if (generation == _loadGeneration) {
            _imageCache[key] = bytes;
            while (_imageCache.length > _maxCachedImages) {
              _imageCache.remove(_imageCache.keys.first);
            }
          }
          return bytes;
        })
        .whenComplete(() {
          if (generation == _loadGeneration) {
            _inflightImages.remove(key);
          }
        });
    _inflightImages[key] = future;
    return future;
  }

  Future<EpubChapterContent> _loadEpubChapter(int index) {
    final entry = _epubChapters[index];
    return _loadEpubChapterFor(entry, index, generation: _loadGeneration);
  }

  Future<EpubChapterContent> _loadEpubChapterFor(
    ArchiveEntryDescriptor entry,
    int index, {
    required int generation,
  }) {
    final key = entry.cacheKey;
    final cached = _chapterCache[key];
    if (cached != null) {
      return Future<EpubChapterContent>.value(cached);
    }
    final inflight = _inflightChapters[key];
    if (inflight != null) return inflight;
    final future = _extrasApi
        .fetchArchiveEntryBytes(
          widget.item.path,
          entry.name,
          entryIndex: entry.index,
          maxBytes: 8 * 1024 * 1024,
        )
        .then((bytes) {
          final raw = utf8.decode(bytes, allowMalformed: true);
          final parsed = parseSafeEpubDocument(
            raw,
            fallbackTitle: '第 ${index + 1} 章',
          );
          if (generation == _loadGeneration) {
            _chapterCache[key] = parsed;
          }
          return parsed;
        })
        .whenComplete(() {
          if (generation == _loadGeneration) {
            _inflightChapters.remove(key);
          }
        });
    _inflightChapters[key] = future;
    return future;
  }

  void _onPositionChanged(int index) {
    final total = _isEpub ? _epubChapters.length : _comicPages.length;
    if (total == 0) return;
    final clamped = index.clamp(0, total - 1);
    final chapterFuture = _isEpub ? _loadEpubChapter(clamped) : null;
    if (_currentIndex != clamped || _isEpub) {
      setState(() {
        _currentIndex = clamped;
        if (_isEpub) _currentChapterFuture = chapterFuture;
      });
    }
    if (!_isEpub && clamped + 1 < _comicPages.length) {
      _prefetchComicImage(_comicPages[clamped + 1]);
    }
    if (_isEpub) {
      if (chapterFuture != null) {
        unawaited(chapterFuture.then<void>((_) {}, onError: (Object _) {}));
      }
      if (_epubScrollController.hasClients) {
        _epubScrollController.jumpTo(0);
      }
    }
    _scheduleProgressSave();
  }

  String _buildLocator() {
    if (_isEpub && _epubChapters.isNotEmpty) {
      final entry = _epubChapters[_currentIndex];
      return 'chapter:$_currentIndex:${entry.name}';
    }
    return 'page:$_currentIndex';
  }

  double _buildPercent() {
    final total = _isEpub ? _epubChapters.length : _comicPages.length;
    if (total <= 1) return 100.0;
    return ((_currentIndex + 1) / total * 100.0).clamp(0.0, 100.0);
  }

  void _scheduleProgressSave() {
    _progressDebounce?.cancel();
    _progressDebounce = Timer(
      const Duration(milliseconds: 600),
      _flushProgressNow,
    );
  }

  void _flushProgressNow({
    String? pathOverride,
    FileExtrasApi? apiOverride,
  }) {
    final total = _isEpub ? _epubChapters.length : _comicPages.length;
    if (total == 0) return;
    final locator = _buildLocator();
    if (locator == _lastSavedLocator) return;
    _lastSavedLocator = locator;
    final targetPath = pathOverride ?? widget.item.path;
    final targetApi = apiOverride ?? _extrasApi;
    unawaited(
      targetApi
          .saveReadingProgress(
            path: targetPath,
            locator: locator,
            percent: _buildPercent(),
          )
          .catchError((Object _) => null),
    );
  }

  void _jumpToIndex(int index) {
    final total = _isEpub ? _epubChapters.length : _comicPages.length;
    if (total == 0) return;
    final target = index.clamp(0, total - 1);
    if (!_isEpub && !_verticalScroll && _pageController?.hasClients == true) {
      _pageController!.jumpToPage(target);
    }
    _onPositionChanged(target);
  }

  void _showEpubToc() {
    final theme = Theme.of(context);
    final borderColor = IsleGlass.rimBorderColor(
      theme.brightness == Brightness.dark,
    );
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetCtx) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '章节目录（共 ${_epubChapters.length} 章）',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭目录',
                  onPressed: () => Navigator.pop(sheetCtx),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: borderColor),
          Expanded(
            child: ListView.builder(
              itemCount: _epubChapters.length,
              itemBuilder: (_, idx) {
                final entry = _epubChapters[idx];
                final cachedTitle = _chapterCache[entry.cacheKey]?.title;
                final label = cachedTitle != null && cachedTitle.isNotEmpty
                    ? cachedTitle
                    : entry.name.split('/').last;
                return ListTile(
                  dense: true,
                  selected: idx == _currentIndex,
                  title: Text(
                    '${idx + 1}. $label',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _jumpToIndex(idx);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = _isEpub ? _epubChapters.length : _comicPages.length;
    final progressLabel = total > 0 ? '${_currentIndex + 1} / $total' : '';

    return Scaffold(
      appBar: IsleAppBar(
        title: Text(
          widget.item.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (!_loading && _error == null && !_isEpub && _comicPages.isNotEmpty)
            IconButton(
              key: const ValueKey('comicModeToggleBtn'),
              tooltip: _verticalScroll ? '切换单页翻页' : '切换竖滑条漫模式',
              onPressed: () {
                setState(() => _verticalScroll = !_verticalScroll);
                if (!_verticalScroll) {
                  _pageController?.dispose();
                  _pageController = PageController(initialPage: _currentIndex);
                }
              },
              icon: Icon(
                _verticalScroll
                    ? Icons.auto_stories_outlined
                    : Icons.view_day_outlined,
              ),
            ),
          if (!_loading && _error == null && _isEpub && _epubChapters.isNotEmpty) ...[
            IconButton(
              tooltip: '减小字号',
              onPressed: _fontSize <= 14
                  ? null
                  : () => setState(() => _fontSize -= 1.5),
              icon: const Icon(Icons.text_decrease_rounded),
            ),
            IconButton(
              tooltip: '增大字号',
              onPressed: _fontSize >= 24
                  ? null
                  : () => setState(() => _fontSize += 1.5),
              icon: const Icon(Icons.text_increase_rounded),
            ),
            IconButton(
              key: const ValueKey('epubTocBtn'),
              tooltip: '章节目录',
              onPressed: _showEpubToc,
              icon: const Icon(Icons.menu_book_rounded),
            ),
          ],
          if (progressLabel.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  progressLabel,
                  key: const ValueKey('readerProgressLabel'),
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
        ],
      ),
      body: _buildBody(context),
      bottomNavigationBar: (!_loading && _error == null && total > 1)
          ? _buildBottomBar(context, total)
          : null,
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(
        child: IsleLoadingState(compact: true, label: '正在解析文档目录…'),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Notice(_error!, error: true, onRetry: _initialize),
      );
    }
    if (_isEpub) {
      if (_epubChapters.isEmpty) {
        return const Center(
          child: IsleEmptyStateCard(
            '该 EPUB 中未找到可安全阅读的文本章节。',
            icon: Icons.menu_book_outlined,
          ),
        );
      }
      return _buildEpubBody(context);
    }
    if (_comicPages.isEmpty) {
      return const Center(
        child: IsleEmptyStateCard(
          '该压缩包中未包含可预览的漫画图片。如需查看其他文件，可在文件菜单中选择「解压到同名文件夹」。',
          icon: Icons.collections_outlined,
        ),
      );
    }
    return _verticalScroll ? _buildComicVertical() : _buildComicPager();
  }

  Widget _buildComicPager() {
    return PageView.builder(
      key: const ValueKey('comicPageView'),
      controller: _pageController,
      itemCount: _comicPages.length,
      onPageChanged: _onPositionChanged,
      itemBuilder: (context, index) => _ComicPageTile(
        entry: _comicPages[index],
        cachedBytes: _imageCache[_comicPages[index].cacheKey],
        loader: () => _loadComicImage(_comicPages[index]),
        interactive: true,
      ),
    );
  }

  Widget _buildComicVertical() {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification && _comicPages.isNotEmpty) {
          final max = notification.metrics.maxScrollExtent;
          if (max > 0) {
            final ratio = (notification.metrics.pixels / max).clamp(0.0, 1.0);
            final approx = (ratio * (_comicPages.length - 1)).round();
            if (approx != _currentIndex) {
              setState(() => _currentIndex = approx);
              _scheduleProgressSave();
            }
          }
        }
        return false;
      },
      child: ListView.builder(
        key: const ValueKey('comicVerticalList'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _comicPages.length,
        itemBuilder: (context, index) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: _ComicPageTile(
            entry: _comicPages[index],
            cachedBytes: _imageCache[_comicPages[index].cacheKey],
            loader: () => _loadComicImage(_comicPages[index]),
            interactive: false,
          ),
        ),
      ),
    );
  }

  Widget _buildEpubBody(BuildContext context) {
    final entry = _epubChapters[_currentIndex];
    final cached = _chapterCache[entry.cacheKey];
    return FutureBuilder<EpubChapterContent>(
      future: cached != null
          ? Future<EpubChapterContent>.value(cached)
          : _currentChapterFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            cached == null) {
          return const Center(
            child: IsleLoadingState(compact: true, label: '正在加载章节内容…'),
          );
        }
        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Notice(
              '加载章节失败：${userFacingError(snapshot.error!)}',
              error: true,
              onRetry: () {
                final retryFuture = _loadEpubChapter(_currentIndex);
                setState(() => _currentChapterFuture = retryFuture);
                unawaited(
                  retryFuture.then<void>((_) {}, onError: (Object _) {}),
                );
              },
            ),
          );
        }
        final chapter = snapshot.data;
        if (chapter == null || chapter.blocks.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('本章节暂无可显示正文内容，可切换下一章继续阅读。'),
            ),
          );
        }
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 740),
            child: ListView.builder(
              key: ValueKey('epub-chapter-$_currentIndex'),
              controller: _epubScrollController,
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 36),
              itemCount: chapter.blocks.length,
              itemBuilder: (context, idx) {
                final block = chapter.blocks[idx];
                return Padding(
                  padding: EdgeInsets.only(
                    top: block.isHeading ? 14 : 0,
                    bottom: block.isHeading ? 10 : 12,
                  ),
                  child: SelectableText(
                    block.text,
                    style: TextStyle(
                      fontSize: block.isHeading ? _fontSize + 3.5 : _fontSize,
                      fontWeight: block.isHeading
                          ? FontWeight.w800
                          : FontWeight.w400,
                      height: block.isHeading ? 1.35 : 1.75,
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildBottomBar(BuildContext context, int total) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = IsleGlass.rimBorderColor(isDark);
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(
              alpha: isDark ? 0.82 : 0.90,
            ),
            border: Border(top: BorderSide(color: borderColor)),
          ),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 56,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: _isEpub ? '上一章' : '上一页',
                      onPressed: _currentIndex > 0
                          ? () => _jumpToIndex(_currentIndex - 1)
                          : null,
                      icon: const Icon(Icons.chevron_left_rounded),
                    ),
                    Expanded(
                      child: Slider(
                        value: _currentIndex.toDouble(),
                        min: 0,
                        max: (total - 1).toDouble(),
                        divisions: total > 1 ? total - 1 : null,
                        onChanged: (v) => _jumpToIndex(v.round()),
                      ),
                    ),
                    IconButton(
                      tooltip: _isEpub ? '下一章' : '下一页',
                      onPressed: _currentIndex < total - 1
                          ? () => _jumpToIndex(_currentIndex + 1)
                          : null,
                      icon: const Icon(Icons.chevron_right_rounded),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ComicPageTile extends StatefulWidget {
  const _ComicPageTile({
    required this.entry,
    required this.cachedBytes,
    required this.loader,
    required this.interactive,
  });

  final ArchiveEntryDescriptor entry;
  final Uint8List? cachedBytes;
  final Future<Uint8List> Function() loader;
  final bool interactive;

  @override
  State<_ComicPageTile> createState() => _ComicPageTileState();
}

class _ComicPageTileState extends State<_ComicPageTile> {
  Future<Uint8List>? _future;

  @override
  void initState() {
    super.initState();
    if (widget.cachedBytes == null) _future = widget.loader();
  }

  @override
  void didUpdateWidget(covariant _ComicPageTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.cacheKey != widget.entry.cacheKey) {
      _future = widget.cachedBytes == null ? widget.loader() : null;
    }
  }

  Widget _renderImage(Uint8List data) {
    final image = Image.memory(
      data,
      fit: widget.interactive ? BoxFit.contain : BoxFit.fitWidth,
      gaplessPlayback: true,
    );
    return widget.interactive
        ? InteractiveViewer(minScale: 1.0, maxScale: 4.0, child: Center(child: image))
        : image;
  }

  @override
  Widget build(BuildContext context) {
    final cached = widget.cachedBytes;
    if (cached != null) return _renderImage(cached);
    return FutureBuilder<Uint8List>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            height: 280,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        if (snapshot.hasError || snapshot.data == null) {
          return SizedBox(
            height: 200,
            child: Center(
              child: Text(
                '无法加载图片：${widget.entry.name}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          );
        }
        return _renderImage(snapshot.data!);
      },
    );
  }
}
