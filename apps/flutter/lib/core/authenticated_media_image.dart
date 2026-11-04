import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'lightisle_api.dart';
import 'media_image_memory_cache.dart';

/// Limits the number of in-flight thumbnail downloads across the visible
/// galleries. The queue holds no image bytes or user credentials.
class _MediaFetchGate {
  static const int limit = 6;
  static int active = 0;
  static final Queue<Completer<bool>> waiting = Queue<Completer<bool>>();

  static Future<bool> acquire(Completer<bool> ticket) {
    if (active < limit) {
      active++;
      ticket.complete(true);
    } else {
      waiting.addLast(ticket);
    }
    return ticket.future;
  }

  static void cancel(Completer<bool>? ticket) {
    if (ticket != null && waiting.remove(ticket)) ticket.complete(false);
  }

  static void release() {
    if (waiting.isNotEmpty) {
      // Ownership of the active slot passes directly to the oldest waiter.
      waiting.removeFirst().complete(true);
    } else {
      active--;
    }
  }
}

/// Displays an image fetched through the authenticated, same-origin API client.
///
/// Keeping the response in memory means image requests use the same certificate
/// validation, redirect restrictions, and session handling as other API calls.
class AuthenticatedMediaImage extends StatefulWidget {
  const AuthenticatedMediaImage({
    required this.api,
    required this.path,
    this.query,
    this.maxBytes = 4 * 1024 * 1024,
    this.fit = BoxFit.contain,
    this.loadingBuilder,
    this.errorBuilder,
    this.excludeFromSemantics = true,
    this.semanticsLabel,
    this.disableMemoryCacheLimit = false,
    this.memoryCache,
    super.key,
  }) : assert(maxBytes > 0);

  final LightIsleApi api;
  final String path;
  final Map<String, String>? query;
  final int maxBytes;
  final BoxFit fit;
  final WidgetBuilder? loadingBuilder;
  final Widget Function(BuildContext context, Object error, VoidCallback retry)?
  errorBuilder;
  final bool excludeFromSemantics;
  final String? semanticsLabel;
  final bool disableMemoryCacheLimit;

  /// Optional route-owned cache; omitted for thumbnails outside a viewer.
  final MediaImageMemoryCache? memoryCache;

  @override
  State<AuthenticatedMediaImage> createState() =>
      _AuthenticatedMediaImageState();
}

class _AuthenticatedMediaImageState extends State<AuthenticatedMediaImage> {
  Uint8List? _data;
  Object? _error;
  bool _loading = true;
  int _generation = 0;
  Completer<bool>? _ticket;

  @override
  void initState() {
    super.initState();
    unawaited(_fetch(++_generation));
  }

  @override
  void didUpdateWidget(covariant AuthenticatedMediaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.path != widget.path ||
        !mapEquals(oldWidget.query, widget.query) ||
        oldWidget.maxBytes != widget.maxBytes ||
        oldWidget.memoryCache != widget.memoryCache) {
      _startFetch();
    }
  }

  @override
  void dispose() {
    _generation++;
    _MediaFetchGate.cancel(_ticket);
    super.dispose();
  }

  void _startFetch() {
    final generation = ++_generation;
    _MediaFetchGate.cancel(_ticket);
    setState(() {
      _data = null;
      _error = null;
      _loading = true;
    });
    unawaited(_fetch(generation));
  }

  void _retryFetch() {
    widget.memoryCache?.invalidate(
      widget.api,
      widget.path,
      widget.query,
      widget.maxBytes,
    );
    _startFetch();
  }

  Future<void> _fetch(int generation) async {
    try {
      // A rebuilt PageView cell should paint previously fetched original
      // bytes immediately, without waiting for the thumbnail fetch queue.
      final cached = widget.memoryCache?.get(
        widget.api,
        widget.path,
        widget.query,
        widget.maxBytes,
      );
      if (cached != null) {
        if (!mounted || generation != _generation) return;
        setState(() {
          _data = cached;
          _error = null;
          _loading = false;
        });
        return;
      }
      final ticket = _ticket = Completer<bool>();
      if (!await _MediaFetchGate.acquire(ticket)) return;
      if (identical(_ticket, ticket)) _ticket = null;
      late final Uint8List data;
      try {
        if (!mounted || generation != _generation) return;
        data =
            await (widget.memoryCache?.load(
                  widget.api,
                  widget.path,
                  widget.query,
                  widget.maxBytes,
                  () => widget.api.bytes(
                    widget.path,
                    query: widget.query,
                    maxBytes: widget.maxBytes,
                  ),
                ) ??
                widget.api.bytes(
                  widget.path,
                  query: widget.query,
                  maxBytes: widget.maxBytes,
                ));
      } finally {
        _MediaFetchGate.release();
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _data = data;
        _error = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _data = null;
        _error = error;
        _loading = false;
      });
    }
  }

  Widget _showError(BuildContext context, Object error) {
    final builder = widget.errorBuilder;
    if (builder != null) return builder(context, error, _retryFetch);
    return Center(
      child: IconButton(
        tooltip: '重新加载媒体',
        onPressed: _retryFetch,
        icon: const Icon(Icons.refresh),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return widget.loadingBuilder?.call(context) ??
          ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
    }
    final error = _error;
    if (error != null) return _showError(context, error);
    final data = _data;
    if (data == null) {
      return _showError(context, StateError('媒体图片为空。'));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final targetWidth =
            !widget.disableMemoryCacheLimit && width.isFinite && width > 0
            ? (width * MediaQuery.devicePixelRatioOf(context)).ceil().clamp(
                64,
                4096,
              )
            : null;
        return Image.memory(
          data,
          cacheWidth: targetWidth,
          fit: widget.fit,
          filterQuality: widget.disableMemoryCacheLimit
              ? FilterQuality.high
              : FilterQuality.low,
          gaplessPlayback: true,
          excludeFromSemantics: widget.excludeFromSemantics,
          semanticLabel: widget.semanticsLabel,
          errorBuilder: (context, error, stackTrace) =>
              _showError(context, error),
        );
      },
    );
  }
}
