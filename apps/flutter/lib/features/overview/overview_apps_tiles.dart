import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/widgets.dart';
import '../settings/apps_center_helpers.dart';

/// Home-screen tile launcher section displaying authorized web-enabled light apps.
class HomeAppsTileSection extends StatelessWidget {
  const HomeAppsTileSection({
    super.key,
    required this.apps,
    required this.isAdmin,
    required this.loaded,
    this.error,
    required this.onOpenApp,
    required this.onOpenAppsCenter,
    this.onRetry,
  });

  final List<Map<String, dynamic>> apps;
  final bool isAdmin;
  final bool loaded;
  final String? error;
  final ValueChanged<Map<String, dynamic>> onOpenApp;
  final VoidCallback onOpenAppsCenter;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final launchable = filterHomeLaunchableApps(apps);
    final hasError = error != null && error!.isNotEmpty;
    if (!isAdmin && launchable.isEmpty && !hasError) {
      return const SizedBox.shrink();
    }
    if (isAdmin && !loaded && launchable.isEmpty && !hasError) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IsleSectionHeader(
          title: '家庭轻应用',
          action: TextButton(
            key: const ValueKey('homeAppsManageButton'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              minimumSize: const Size(40, 32),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            onPressed: onOpenAppsCenter,
            child: Text(isAdmin ? '管理应用' : '全部应用'),
          ),
        ),
        if (hasError) Notice('轻应用列表读取失败：$error', error: true, onRetry: onRetry),
        if (launchable.isNotEmpty)
          _buildGrid(context, launchable)
        else if (isAdmin && !hasError)
          _buildAdminGuideTile(context),
        const SizedBox(height: 10),
      ],
    );
  }

  Widget _buildGrid(BuildContext context, List<Map<String, dynamic>> items) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bigText = MediaQuery.textScalerOf(context).scale(14) > 19;
        final width = constraints.maxWidth;
        final columns = bigText
            ? (width >= 640 ? 2 : 1)
            : width >= 680
            ? 4
            : width >= 300
            ? 2
            : 1;
        final gap = width < IsleLayout.compactPageWidth ? 8.0 : 10.0;
        final cardWidth = (width - (columns - 1) * gap) / columns;
        final compactCard = cardWidth < 210 || bigText;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final app in items)
              SizedBox(
                width: cardWidth,
                child: _HomeAppTileCard(
                  app: app,
                  isAdmin: isAdmin,
                  compact: compactCard,
                  onTap: () => onOpenApp(app),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildAdminGuideTile(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return IsleSurface(
      key: const ValueKey('homeAppsAdminGuideTile'),
      onTap: onOpenAppsCenter,
      radius: IsleRadius.item,
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          IsleSquircleBadge(
            icon: Icons.auto_awesome_rounded,
            color: colors.primary,
            size: 38,
            iconSize: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '安装或添加家庭轻应用',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '内置 0 MB 纯静态官方精选模板，进入应用中心即可一键安装并授权家人。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            Icons.arrow_forward_ios_rounded,
            size: 14,
            color: colors.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

class _HomeAppTileCard extends StatelessWidget {
  const _HomeAppTileCard({
    required this.app,
    required this.isAdmin,
    required this.compact,
    required this.onTap,
  });

  final Map<String, dynamic> app;
  final bool isAdmin;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final id = app['id']?.toString() ?? '';
    final name = app['name']?.toString().trim().isNotEmpty == true
        ? app['name'].toString().trim()
        : id;
    final description = app['description']?.toString().trim().isNotEmpty == true
        ? app['description'].toString().trim()
        : '轻屿本地家庭轻应用';
    final category = app['category']?.toString();
    final catColor = appCategoryColor(category, colors);
    final ready = isHomeAppReady(app);

    final (String badgeText, Color badgeColor) = () {
      if (!isAdmin) return (appCategoryLabel(category), catColor);
      if (app['pendingActivation'] == true) {
        return ('待首次激活', const Color(0xFFD97706));
      }
      if (!ready) return ('启动异常', colors.error);
      return appRuntimeBadge(app, appWebMode(app));
    }();

    return IsleSurface(
      key: ValueKey('homeAppTile_$id'),
      onTap: onTap,
      radius: IsleRadius.item,
      margin: EdgeInsets.zero,
      padding: EdgeInsets.all(compact ? 11 : 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IsleSquircleBadge(
                icon: appCategoryIcon(category),
                color: catColor,
                size: compact ? 30 : 34,
                iconSize: compact ? 16 : 18,
              ),
              const Spacer(),
              Icon(
                Icons.arrow_outward_rounded,
                size: 15,
                color: colors.onSurfaceVariant,
              ),
            ],
          ),
          SizedBox(height: compact ? 7 : 9),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                (compact
                        ? theme.textTheme.titleSmall
                        : theme.textTheme.titleMedium)
                    ?.copyWith(fontWeight: FontWeight.w700, height: 1.2),
          ),
          const SizedBox(height: 2),
          Text(
            description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
              fontSize: compact ? 11.5 : 12.2,
              height: 1.25,
            ),
          ),
          SizedBox(height: compact ? 7 : 9),
          Row(
            children: [
              Flexible(
                child: IsleStatusBadge(label: badgeText, color: badgeColor),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
