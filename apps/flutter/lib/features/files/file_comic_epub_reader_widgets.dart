import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/isle_style.dart';
import 'file_extras_api.dart';

/// Frosted Liquid Glass bottom navigation bar for comic & EPUB reader pages.
class ReaderBottomNavigationBar extends StatelessWidget {
  const ReaderBottomNavigationBar({
    super.key,
    required this.isEpub,
    required this.currentIndex,
    required this.total,
    required this.onJump,
  });

  final bool isEpub;
  final int currentIndex;
  final int total;
  final ValueChanged<int> onJump;

  @override
  Widget build(BuildContext context) {
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
                      tooltip: isEpub ? '上一章' : '上一页',
                      onPressed: currentIndex > 0
                          ? () => onJump(currentIndex - 1)
                          : null,
                      icon: const Icon(Icons.chevron_left_rounded),
                    ),
                    Expanded(
                      child: Slider(
                        value: currentIndex.toDouble(),
                        min: 0,
                        max: (total - 1).toDouble(),
                        divisions: total > 1 ? total - 1 : null,
                        onChanged: (v) => onJump(v.round()),
                      ),
                    ),
                    IconButton(
                      tooltip: isEpub ? '下一章' : '下一页',
                      onPressed: currentIndex < total - 1
                          ? () => onJump(currentIndex + 1)
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

/// Async image tile for single-page interactive and vertical-strip comic modes.
class ComicPageTile extends StatefulWidget {
  const ComicPageTile({
    super.key,
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
  State<ComicPageTile> createState() => _ComicPageTileState();
}

class _ComicPageTileState extends State<ComicPageTile> {
  Future<Uint8List>? _future;

  @override
  void initState() {
    super.initState();
    if (widget.cachedBytes == null) _future = widget.loader();
  }

  @override
  void didUpdateWidget(covariant ComicPageTile oldWidget) {
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
        ? InteractiveViewer(
            minScale: 1.0,
            maxScale: 4.0,
            child: Center(child: image),
          )
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
