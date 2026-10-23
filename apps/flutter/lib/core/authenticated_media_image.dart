import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'lightisle_api.dart';

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

  @override
  State<AuthenticatedMediaImage> createState() =>
      _AuthenticatedMediaImageState();
}

class _AuthenticatedMediaImageState extends State<AuthenticatedMediaImage> {
  Uint8List? _data;
  Object? _error;
  bool _loading = true;
  int _generation = 0;

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
        oldWidget.maxBytes != widget.maxBytes) {
      _startFetch();
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  void _startFetch() {
    final generation = ++_generation;
    setState(() {
      _data = null;
      _error = null;
      _loading = true;
    });
    unawaited(_fetch(generation));
  }

  Future<void> _fetch(int generation) async {
    try {
      final data = await widget.api.bytes(
        widget.path,
        query: widget.query,
        maxBytes: widget.maxBytes,
      );
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
    if (builder != null) return builder(context, error, _startFetch);
    return Center(
      child: IconButton(
        tooltip: '重新加载媒体',
        onPressed: _startFetch,
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
    return Image.memory(
      data,
      fit: widget.fit,
      gaplessPlayback: true,
      excludeFromSemantics: widget.excludeFromSemantics,
      semanticLabel: widget.semanticsLabel,
      errorBuilder: (context, error, stackTrace) => _showError(context, error),
    );
  }
}
