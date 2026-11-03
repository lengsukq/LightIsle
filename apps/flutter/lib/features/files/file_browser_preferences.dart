import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Non-sensitive, device-local file browser presentation settings.
/// Keep settings separate for each NAS, account, physical root and entry point
/// so switching identities never carries a previous user's layout over.
class FileBrowserPreferences {
  const FileBrowserPreferences({
    this.view = 'list',
    this.sort = 'name',
    this.direction = 'asc',
    this.autoRename = false,
  });

  final String view;
  final String sort;
  final String direction;
  final bool autoRename;

  static String scope({
    required Uri server,
    required String account,
    required String rootIdentity,
    required String initialPath,
  }) {
    final identity = [
      server.origin,
      account,
      rootIdentity,
      initialPath,
    ].join('\u0000');
    return 'lightisle.files.presentation.v1.${sha256.convert(utf8.encode(identity))}';
  }

  static Future<FileBrowserPreferences> load(String scope) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(scope);
    if (raw == null) return const FileBrowserPreferences();
    final Map<String, dynamic> values;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return const FileBrowserPreferences();
      }
      values = decoded;
    } on FormatException {
      return const FileBrowserPreferences();
    }
    final view = values['view'];
    final sort = values['sort'];
    final direction = values['direction'];
    return FileBrowserPreferences(
      view: view == 'grid' ? 'grid' : 'list',
      sort: {'name', 'mtime', 'size'}.contains(sort) ? sort as String : 'name',
      direction: direction == 'desc' ? 'desc' : 'asc',
      autoRename: values['autoRename'] == true,
    );
  }

  Future<void> save(String scope) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      scope,
      jsonEncode({
        'view': view,
        'sort': sort,
        'direction': direction,
        'autoRename': autoRename,
      }),
    );
  }
}
