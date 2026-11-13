import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists device-local recent file search queries scoped strictly per
/// server origin, account identity, and physical storage root so switching
/// users or roots never leaks another account's search history.
class FileSearchHistoryStore {
  static const int maxItems = 8;

  static String scope({
    required Uri server,
    required String account,
    required String rootIdentity,
  }) {
    final identity = [server.origin, account, rootIdentity].join('\u0000');
    return 'lightisle.files.search_history.v1.${sha256.convert(utf8.encode(identity))}';
  }

  static Future<List<String>> load(String scope) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(scope);
    if (raw == null || raw.isEmpty) return const <String>[];
    final cleaned = <String>[];
    final seen = <String>{};
    for (final entry in raw) {
      final term = entry.trim();
      if (term.isEmpty) continue;
      final normalized = term.toLowerCase();
      if (seen.add(normalized)) {
        cleaned.add(term);
        if (cleaned.length >= maxItems) break;
      }
    }
    return List.unmodifiable(cleaned);
  }

  static Future<List<String>> record(String scope, String rawTerm) async {
    final term = rawTerm.trim();
    final current = await load(scope);
    if (term.isEmpty) return current;
    final lower = term.toLowerCase();
    final next = <String>[
      term,
      ...current.where((item) => item.trim().toLowerCase() != lower),
    ];
    final capped = next.take(maxItems).toList(growable: false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(scope, capped);
    return List.unmodifiable(capped);
  }

  static Future<List<String>> remove(String scope, String rawTerm) async {
    final lower = rawTerm.trim().toLowerCase();
    final current = await load(scope);
    final next = current
        .where((item) => item.trim().toLowerCase() != lower)
        .toList(growable: false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(scope, next);
    return List.unmodifiable(next);
  }

  static Future<void> clear(String scope) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(scope);
  }
}
