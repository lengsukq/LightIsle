import 'package:flutter/material.dart';

double? asDoubleOrNull(Object? value) {
  if (value is num) return value.toDouble();
  if (value == null) return null;
  return double.tryParse(value.toString());
}

String appWebMode(Map<String, dynamic> app) {
  final web = app['web'];
  final raw = (web is Map ? web['mode'] : null) ?? app['mode'] ?? 'on-demand';
  return raw.toString();
}

/// Whether an app exposes an enabled Web UI entry for launcher tiles.
bool isHomeAppWebEnabled(Map<String, dynamic> app) {
  final web = app['web'];
  if (web is Map && web['enabled'] == false) return false;
  return appWebMode(app) != 'none';
}

/// Whether an app can launch immediately without admin activation or repair.
bool isHomeAppReady(Map<String, dynamic> app) {
  if (app['pendingActivation'] == true || app['valid'] == false) return false;
  final web = app['web'] is Map ? app['web'] as Map : const {};
  final err =
      (app['lastError'] ?? app['validationError'] ?? web['lastError'])
          ?.toString()
          .trim() ??
      '';
  if (err.isNotEmpty || app['diagnostic'] is Map) return false;
  return true;
}

/// Filters `/api/v2/apps` items for home tiles and places ready apps first.
List<Map<String, dynamic>> filterHomeLaunchableApps(
  List<Map<String, dynamic>> apps,
) {
  final launchable = apps.where(isHomeAppWebEnabled).toList();
  launchable.sort((a, b) {
    final aReady = isHomeAppReady(a);
    final bReady = isHomeAppReady(b);
    if (aReady != bReady) return aReady ? -1 : 1;
    final aId = a['id']?.toString() ?? '';
    final bId = b['id']?.toString() ?? '';
    return aId.compareTo(bId);
  });
  return launchable;
}

(String, Color) appRuntimeBadge(Map<String, dynamic> app, String mode) {
  final web = app['web'] is Map
      ? Map<String, dynamic>.from(app['web'] as Map)
      : const <String, dynamic>{};
  final runtime = app['runtime'] is Map
      ? Map<String, dynamic>.from(app['runtime'] as Map)
      : const <String, dynamic>{};
  final status =
      app['status']?.toString() ??
      web['status']?.toString() ??
      runtime['status']?.toString() ??
      (mode == 'static' ? 'static' : 'sleeping');
  final memBytes = asDoubleOrNull(
    app['memoryBytes'] ??
        app['rssBytes'] ??
        web['rssBytes'] ??
        runtime['memoryBytes'] ??
        runtime['rssBytes'],
  );
  final memMbRaw = asDoubleOrNull(
    app['memoryMB'] ?? web['memoryMB'] ?? runtime['memoryMB'],
  );
  final mb = memMbRaw != null
      ? memMbRaw.round()
      : (memBytes != null && memBytes > 0
            ? (memBytes / (1024 * 1024)).ceil()
            : 0);
  if (mode == 'static' || status == 'static') {
    return ('纯静态 0 MB', const Color(0xFF10B981));
  }
  if (status == 'running') {
    return mode == 'persistent' && mb <= 0
        ? ('常驻守护', const Color(0xFF0A84FF))
        : ('运行中 $mb MB', const Color(0xFF10B981));
  }
  return mode == 'persistent'
      ? ('常驻守护', const Color(0xFF0A84FF))
      : ('按需休眠 0 MB', const Color(0xFF64748B));
}

String appCategoryLabel(String? category) => switch (category) {
  'network' => '网络监控',
  'media' => '影音工具',
  'home' => '家庭看板',
  'finance' => '账单记账',
  'system' => '系统扩展',
  'automation' => '数据看板',
  _ => '实用工具',
};

IconData appCategoryIcon(String? category) => switch (category) {
  'network' => Icons.router_rounded,
  'media' => Icons.movie_filter_rounded,
  'home' => Icons.home_work_outlined,
  'finance' => Icons.account_balance_wallet_outlined,
  'system' => Icons.memory_rounded,
  'automation' => Icons.insights_rounded,
  _ => Icons.widgets_rounded,
};

Color appCategoryColor(String? category, ColorScheme colors) =>
    switch (category) {
      'network' => colors.primary,
      'media' => const Color(0xFFF97316),
      'home' => const Color(0xFF10B981),
      'finance' => const Color(0xFF059669),
      'system' || 'automation' => const Color(0xFF0D9488),
      _ => const Color(0xFF7C3AED),
    };
