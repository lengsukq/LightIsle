import 'media_models.dart';

/// The photo viewer uses original image bytes by default, not a thumbnail.
/// Loading extremely large files into a Dart heap AND the image decoder can
/// exhaust memory on a phone, so those stay as a labeled preview and remain
/// available via the independent original-file download action.
const int photoViewerOriginalMaxBytes = 64 * 1024 * 1024;

bool photoViewerCanOpenOriginal(PhotoAsset asset) {
  if (asset.isVideo || asset.isRaw || asset.size > photoViewerOriginalMaxBytes) {
    return false;
  }
  return RegExp(
    r'\.(jpe?g|png|webp|gif)$',
    caseSensitive: false,
  ).hasMatch(asset.name);
}

bool photoViewerOriginalTooLarge(PhotoAsset asset) =>
    !asset.isVideo &&
    !asset.isRaw &&
    asset.size > photoViewerOriginalMaxBytes &&
    RegExp(r'\.(jpe?g|png|webp|gif)$', caseSensitive: false)
        .hasMatch(asset.name);
