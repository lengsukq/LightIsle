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
    'files' => 'files', 'photos' => 'photos', 'cinema' => 'videos', _ => null,
  };
  if (category == null) return const PersonalStorageRoute(PersonalRouteKind.shared);
  final items = policy?['locations'];
  if (items is! List) return const PersonalStorageRoute(PersonalRouteKind.shared);
  Map? location;
  for (final item in items) {
    if (item is Map && item['category'] == category) {
      location = item;
      break;
    }
  }
  if (location == null) return const PersonalStorageRoute(PersonalRouteKind.shared);
  final rootID = location['rootID'];
  final generation = location['rootGeneration'];
  final path = location['relativePath'];
  final userID = policy?['userId'];
  final expected = userID is int && userID > 0 ? 'Users/u$userID/$category' : null;
  if (rootID is! String || generation is! num || path != expected) {
    return const PersonalStorageRoute(PersonalRouteKind.offline);
  }
  for (final root in roots) {
    if (root.id == rootID && root.generation == generation && root.online) {
      return PersonalStorageRoute(PersonalRouteKind.personal, root: root, path: path as String);
    }
  }
  return const PersonalStorageRoute(PersonalRouteKind.offline);
}
