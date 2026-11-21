import 'package:flutter/material.dart';

import '../../core/authenticated_media_image.dart';
import '../../core/isle_cache_manager.dart';
import '../../core/lightisle_api.dart';
import '../../core/media_image_memory_cache.dart';
import 'media_models.dart';

final RegExp _safeTmdbImageUrl = RegExp(
  r'^https://image\.tmdb\.org/t/p/(?:w185|w342|w500|w780|original)/[a-zA-Z0-9_-]{1,110}\.(?:jpg|jpeg|png|webp)$',
);

bool isSafeCinemaTmdbPosterUrl(String url) =>
    url.isNotEmpty && _safeTmdbImageUrl.hasMatch(url.trim());

/// Unified Cinema poster widget for films, aggregated TV series, and TMDB
/// search candidates.
///
/// Loads primarily through the authenticated NAS poster endpoint (which serves
/// scraped TMDB posters from local NAS disk cache, local sidecar artwork, or
/// video frame grabs) and falls back to direct `image.tmdb.org` HTTPS without
/// NAS credentials if the host has not cached an external poster yet.
class CinemaPosterImage extends StatefulWidget {
  const CinemaPosterImage._({
    super.key,
    required this.api,
    required this.nasPath,
    required this.nasQuery,
    required this.directFallbackUrl,
    this.memoryCache,
    this.fit = BoxFit.cover,
    this.maxBytes = 4 * 1024 * 1024,
    this.loadingBuilder,
    this.errorBuilder,
  });

  factory CinemaPosterImage.film({
    Key? key,
    required LightIsleApi api,
    required CinemaFilm film,
    MediaImageMemoryCache? memoryCache,
    BoxFit fit = BoxFit.cover,
    int maxBytes = 4 * 1024 * 1024,
    WidgetBuilder? loadingBuilder,
    Widget Function(BuildContext context, Object error, VoidCallback retry)?
    errorBuilder,
  }) {
    final posterUrl = film.posterURL.trim();
    return CinemaPosterImage._(
      key: key,
      api: api,
      nasPath: '/api/v2/cinema/${film.id}/poster',
      nasQuery: posterUrl.isNotEmpty ? <String, String>{'v': posterUrl} : null,
      directFallbackUrl: isSafeCinemaTmdbPosterUrl(posterUrl) ? posterUrl : '',
      memoryCache: memoryCache,
      fit: fit,
      maxBytes: maxBytes,
      loadingBuilder: loadingBuilder,
      errorBuilder: errorBuilder,
    );
  }

  factory CinemaPosterImage.series({
    Key? key,
    required LightIsleApi api,
    required CinemaSeriesInfo series,
    MediaImageMemoryCache? memoryCache,
    BoxFit fit = BoxFit.cover,
    int maxBytes = 4 * 1024 * 1024,
    WidgetBuilder? loadingBuilder,
    Widget Function(BuildContext context, Object error, VoidCallback retry)?
    errorBuilder,
  }) {
    final posterUrl = series.posterURL.trim();
    return CinemaPosterImage._(
      key: key,
      api: api,
      nasPath: '/api/v2/series/${series.id}/poster',
      nasQuery: posterUrl.isNotEmpty ? <String, String>{'v': posterUrl} : null,
      directFallbackUrl: isSafeCinemaTmdbPosterUrl(posterUrl) ? posterUrl : '',
      memoryCache: memoryCache,
      fit: fit,
      maxBytes: maxBytes,
      loadingBuilder: loadingBuilder,
      errorBuilder: errorBuilder,
    );
  }

  factory CinemaPosterImage.tmdbCandidate({
    Key? key,
    required LightIsleApi api,
    required String posterURL,
    MediaImageMemoryCache? memoryCache,
    BoxFit fit = BoxFit.cover,
    int maxBytes = 2 * 1024 * 1024,
    WidgetBuilder? loadingBuilder,
    Widget Function(BuildContext context, Object error, VoidCallback retry)?
    errorBuilder,
  }) {
    final clean = posterURL.trim();
    return CinemaPosterImage._(
      key: key,
      api: api,
      nasPath: '/api/v2/cinema/tmdb-poster',
      nasQuery: <String, String>{'url': clean},
      directFallbackUrl: isSafeCinemaTmdbPosterUrl(clean) ? clean : '',
      memoryCache: memoryCache,
      fit: fit,
      maxBytes: maxBytes,
      loadingBuilder: loadingBuilder,
      errorBuilder: errorBuilder,
    );
  }

  final LightIsleApi api;
  final String nasPath;
  final Map<String, String>? nasQuery;
  final String directFallbackUrl;
  final MediaImageMemoryCache? memoryCache;
  final BoxFit fit;
  final int maxBytes;
  final WidgetBuilder? loadingBuilder;
  final Widget Function(BuildContext context, Object error, VoidCallback retry)?
  errorBuilder;

  @override
  State<CinemaPosterImage> createState() => _CinemaPosterImageState();
}

class _CinemaPosterImageState extends State<CinemaPosterImage> {
  bool _useDirectFallback = false;
  int _retryNonce = 0;

  @override
  void didUpdateWidget(covariant CinemaPosterImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.nasPath != widget.nasPath ||
        oldWidget.directFallbackUrl != widget.directFallbackUrl ||
        oldWidget.nasQuery?['v'] != widget.nasQuery?['v'] ||
        oldWidget.nasQuery?['url'] != widget.nasQuery?['url']) {
      _useDirectFallback = false;
    }
  }

  void _retryFromScratch() {
    final cache =
        widget.memoryCache ?? IsleCacheManager.instance.sharedPosters;
    cache.invalidate(
      widget.api,
      widget.nasPath,
      widget.nasQuery,
      widget.maxBytes,
    );
    setState(() {
      _useDirectFallback = false;
      _retryNonce++;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_useDirectFallback && widget.directFallbackUrl.isNotEmpty) {
      return Image.network(
        widget.directFallbackUrl,
        key: ValueKey('direct:${widget.directFallbackUrl}:$_retryNonce'),
        fit: widget.fit,
        gaplessPlayback: true,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return widget.loadingBuilder?.call(context) ??
              const SizedBox.expand();
        },
        errorBuilder: (context, error, stackTrace) {
          final builder = widget.errorBuilder;
          if (builder != null) {
            return builder(context, error, _retryFromScratch);
          }
          return Center(
            child: IconButton(
              tooltip: '重新加载海报',
              onPressed: _retryFromScratch,
              icon: const Icon(Icons.refresh_rounded, size: 18),
            ),
          );
        },
      );
    }

    return AuthenticatedMediaImage(
      key: ValueKey(
        'nas:${widget.nasPath}:${widget.nasQuery?['v'] ?? widget.nasQuery?['url'] ?? ''}:$_retryNonce',
      ),
      api: widget.api,
      memoryCache:
          widget.memoryCache ?? IsleCacheManager.instance.sharedPosters,
      path: widget.nasPath,
      query: widget.nasQuery,
      maxBytes: widget.maxBytes,
      fit: widget.fit,
      loadingBuilder: widget.loadingBuilder,
      errorBuilder: (context, error, retryNas) {
        if (widget.directFallbackUrl.isNotEmpty && !_useDirectFallback) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_useDirectFallback) {
              setState(() => _useDirectFallback = true);
            }
          });
          return widget.loadingBuilder?.call(context) ??
              const SizedBox.expand();
        }
        final builder = widget.errorBuilder;
        if (builder != null) {
          return builder(context, error, retryNas);
        }
        return Center(
          child: IconButton(
            tooltip: '重新加载海报',
            onPressed: retryNas,
            icon: const Icon(Icons.refresh_rounded, size: 18),
          ),
        );
      },
    );
  }
}
