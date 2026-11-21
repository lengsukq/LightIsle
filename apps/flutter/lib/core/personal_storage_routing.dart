import 'lightisle_api.dart';

enum PersonalRouteKind { shared, personal, offline }

class PersonalStorageRoute {
  const PersonalStorageRoute(this.kind, {this.root, this.path});
  final PersonalRouteKind kind;
  final LightIsleRoot? root;
  final String? path;
}

/// Physical locations are resolved against authenticated discovery; a missing
/// or replaced disk must not silently redirect writes to the default share.
PersonalStorageRoute resolvePersonalRoute(
  Map<String, dynamic>? policy,
  List<LightIsleRoot> roots,
  String section,
) {
  final category = switch (section) {
    'files' => 'files',
    'photos' => 'photos',
    'cinema' => 'videos',
    _ => null,
  };
  if (category == null) {
    return const PersonalStorageRoute(PersonalRouteKind.shared);
  }
  final items = policy?['locations'];
  if (items is! List) {
    return const PersonalStorageRoute(PersonalRouteKind.shared);
  }
  Map? location;
  for (final item in items) {
    if (item is Map && item['category'] == category) {
      location = item;
      break;
    }
  }
  if (location == null) {
    return const PersonalStorageRoute(PersonalRouteKind.shared);
  }
  final rootID = location['rootID'];
  final generation = location['rootGeneration'];
  final path = location['relativePath'];
  final userID = policy?['userId'];
  if (userID is! int ||
      userID <= 0 ||
      rootID is! String ||
      rootID.isEmpty ||
      generation is! num ||
      path is! String ||
      !_isValidAssignedRelativePath(path, userID)) {
    return const PersonalStorageRoute(PersonalRouteKind.offline);
  }
  for (final root in roots) {
    if (root.id == rootID && root.generation == generation && root.online) {
      return PersonalStorageRoute(
        PersonalRouteKind.personal,
        root: root,
        path: path,
      );
    }
  }
  return const PersonalStorageRoute(PersonalRouteKind.offline);
}

final RegExp _canonicalUserNamespace = RegExp(r'^Users/u(\d+)(?:/|$)');

/// Trusts the server-supplied relativePath (including custom directory layouts)
/// while failing closed on empty, traversal, or cross-user `Users/uN` paths.
bool _isValidAssignedRelativePath(String rawPath, int userID) {
  final trimmed = rawPath.trim();
  if (trimmed.isEmpty ||
      trimmed != rawPath ||
      trimmed.startsWith('/') ||
      trimmed.endsWith('/') ||
      trimmed.contains('\\') ||
      trimmed.runes.any((r) => r < 32)) {
    return false;
  }
  final segments = trimmed.split('/');
  if (segments.any((s) => s.isEmpty || s == '.' || s == '..')) {
    return false;
  }
  final match = _canonicalUserNamespace.firstMatch(trimmed);
  if (match != null && int.tryParse(match.group(1) ?? '') != userID) {
    return false;
  }
  return true;
}
