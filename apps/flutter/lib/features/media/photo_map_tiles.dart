/// Only display preferences are local. The Tianditu key is owned by the NAS
/// administrator's Mac Keychain and never reaches this Flutter app.
enum PhotoMapTileSource {
  tianditu('tianditu', '天地图（国内推荐）'),
  openStreetMap('osm', 'OpenStreetMap'),
  custom('custom', '自定义瓦片');

  const PhotoMapTileSource(this.storageValue, this.label);
  final String storageValue;
  final String label;

  static PhotoMapTileSource? fromStorage(String? value) {
    for (final source in values) {
      if (source.storageValue == value) return source;
    }
    return null;
  }
}

class PhotoMapTiles {
  static const sourceKey = 'lightisle_flutter_map_tile_source';
  static const customUrlKey = 'lightisle_flutter_map_tile_url';

  /// Old insecure preference key; clear on upgrade without reading its value.
  static const legacyTiandituKey = 'lightisle_flutter_map_tianditu_key';
  static const consentKey = 'lightisle_flutter_map_tiles_enabled';

  static const openStreetMapUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  /// Same-origin authenticated NAS proxy; no map provider Key in the URL.
  static String tiandituUrl(String layer) {
    if (layer != 'vec' && layer != 'cva') {
      throw ArgumentError.value(layer, 'layer', 'Unsupported Tianditu layer');
    }
    return '/api/v2/map/tiles/tianditu/$layer/{z}/{x}/{y}';
  }

  static String? validateCustomUrl(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.userInfo.isNotEmpty ||
        !input.contains('{z}') ||
        !input.contains('{x}') ||
        !input.contains('{y}')) {
      return '请输入 http(s) 瓦片链接，包含 {z}、{x}、{y} 三个占位符。';
    }
    return null;
  }

  static bool isReady({
    required PhotoMapTileSource source,
    required bool tiandituConfigured,
    required String customUrl,
  }) => switch (source) {
    PhotoMapTileSource.tianditu => tiandituConfigured,
    PhotoMapTileSource.openStreetMap => true,
    PhotoMapTileSource.custom => validateCustomUrl(customUrl) == null,
  };

  /// Preserve the earlier Flutter map setting instead of silently replacing
  /// an already configured source on upgrade. Fresh installs recommend TDT.
  static PhotoMapTileSource migratedSource({
    required String? storedSource,
    required String? legacyCustomUrl,
    required bool previouslyEnabled,
  }) {
    final selected = PhotoMapTileSource.fromStorage(storedSource);
    if (selected != null) return selected;
    if (legacyCustomUrl != null &&
        legacyCustomUrl != openStreetMapUrl &&
        validateCustomUrl(legacyCustomUrl) == null) {
      return PhotoMapTileSource.custom;
    }
    return previouslyEnabled || legacyCustomUrl != null
        ? PhotoMapTileSource.openStreetMap
        : PhotoMapTileSource.tianditu;
  }
}
