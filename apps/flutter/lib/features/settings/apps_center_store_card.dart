part of 'apps_center_page.dart';

extension _AppsCenterStoreCard on _AppsCenterPageState {
  static const String _defaultOfficialStoreUrl =
      'https://raw.githubusercontent.com/lengsukq/LightIsle/main/plugins-store/registry.json';

  static const List<(String, String)> _mirrorPresets = <(String, String)>[
    ('直连 GitHub', ''),
    ('ghfast.top', 'https://ghfast.top/'),
    ('gh-proxy.com', 'https://gh-proxy.com/'),
  ];

  List<Map<String, dynamic>> get _effectiveStorePlugins {
    if (_store != null) {
      return objectList(_store?['plugins']);
    }
    return _templates;
  }

  Map<String, dynamic>? _storePluginFor(String appId) {
    if (appId.isEmpty) return null;
    for (final plugin in _effectiveStorePlugins) {
      if (plugin['id']?.toString() == appId) return plugin;
    }
    return null;
  }

  String _formatPluginSize(Object? rawBytes) {
    final bytes = rawBytes is num ? rawBytes.toInt() : 0;
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024.0;
    if (kb < 1024) return '${kb.round()} KB';
    return '${(kb / 1024.0).toStringAsFixed(1)} MB';
  }

  Widget _buildOnlineStoreCard(BuildContext context) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final violet = palette['brandViolet'];
    final plugins = _effectiveStorePlugins;
    final isOfficial = _store == null || _store?['isOfficial'] != false;
    final mirrorPrefix = _store?['mirrorPrefix']?.toString().trim() ?? '';
    final storeError = _store?['error']?.toString().trim() ?? '';
    final updatableCount = plugins
        .where((p) => p['updateAvailable'] == true)
        .length;

    final categories = <String>[];
    for (final plugin in plugins) {
      final cat = plugin['category']?.toString().trim() ?? '';
      if (cat.isNotEmpty && !categories.contains(cat)) {
        categories.add(cat);
      }
    }
    final activeCategory =
        _storeCategoryFilter == 'all' ||
            categories.contains(_storeCategoryFilter)
        ? _storeCategoryFilter
        : 'all';
    final visiblePlugins = activeCategory == 'all'
        ? plugins
        : plugins
              .where((p) => p['category']?.toString() == activeCategory)
              .toList();

    return IsleSurface(
      key: const ValueKey('onlinePluginStoreCard'),
      radius: IsleRadius.hero,
      tint: violet,
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IsleSquircleBadge(
                    icon: Icons.storefront_rounded,
                    color: violet,
                    size: 36,
                    iconSize: 18,
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '在线插件商店',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            IsleStatusBadge(
                              label: isOfficial ? '官方 Git 仓库' : '自定义 Git 源',
                              color: isOfficial ? violet : palette['brandBlue'],
                            ),
                            if (mirrorPrefix.isNotEmpty)
                              IsleStatusBadge(
                                label: '已启用镜像加速',
                                color: palette['brandSage'],
                              ),
                            if (updatableCount > 0)
                              IsleStatusBadge(
                                label: '$updatableCount 个可更新',
                                color: palette['brandAmber'],
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (_store != null)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('storeConfigButton'),
                      onPressed: _busy || _storeBusy
                          ? null
                          : () => _showStoreConfigDialog(context),
                      icon: const Icon(Icons.tune_rounded, size: 16),
                      label: const Text('商店源'),
                    ),
                    FilledButton.tonalIcon(
                      key: const ValueKey('refreshStoreButton'),
                      onPressed: _busy || _storeBusy
                          ? null
                          : () => _refreshStore(),
                      icon: const Icon(Icons.sync_rounded, size: 16),
                      label: Text(_storeBusy ? '同步中…' : '刷新商店'),
                    ),
                  ],
                ),
            ],
          ),
          if (storeError.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.errorContainer.withValues(alpha: 0.45),
                borderRadius: IsleRadius.brMd,
              ),
              child: Row(
                children: [
                  Icon(Icons.wifi_off_rounded, size: 18, color: colors.error),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      storeError,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onErrorContainer,
                      ),
                    ),
                  ),
                  if (_store != null)
                    TextButton(
                      onPressed: _busy || _storeBusy
                          ? null
                          : () => _showStoreConfigDialog(context),
                      child: const Text('配置镜像'),
                    ),
                ],
              ),
            ),
          ],
          if (_appStorage != null &&
              objectList(_appStorage?['locations']).length > 1) ...[
            const SizedBox(height: 12),
            KeyedSubtree(
              key: ValueKey('location_$_selectedInstallLocationId'),
              child: DropdownButtonFormField<String>(
                key: const ValueKey('templateInstallLocationDropdown'),
                initialValue: _selectedInstallLocationId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '插件安装目标位置',
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem(
                    value: '',
                    child: Text(
                      '跟随默认位置',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  for (final loc in objectList(_appStorage?['locations']))
                    DropdownMenuItem(
                      value: loc['id']?.toString() ?? '',
                      enabled: loc['online'] == true && loc['writable'] == true,
                      child: Text(
                        '${loc['kind'] == 'external' ? '其他盘' : '内置盘'} · ${loc['name'] ?? ''}'
                        '${loc['online'] == true ? '' : '（离线）'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (v) => _updateState(
                        () => _selectedInstallLocationId = v ?? '',
                      ),
              ),
            ),
          ],
          if (categories.length > 1) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  label: Text('全部 (${plugins.length})'),
                  selected: activeCategory == 'all',
                  onSelected: (_) =>
                      _updateState(() => _storeCategoryFilter = 'all'),
                ),
                for (final cat in categories)
                  ChoiceChip(
                    label: Text(appCategoryLabel(cat)),
                    selected: activeCategory == cat,
                    onSelected: (_) =>
                        _updateState(() => _storeCategoryFilter = cat),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          if (visiblePlugins.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: IsleDecorations.recessedWell(context, radius: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '尚未拉取在线商店目录',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '基础轻应用托管在 Git 仓库（plugins-store），按需下载并通过 SHA-256 校验安装。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (_store != null) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: _busy || _storeBusy
                              ? null
                              : () => _refreshStore(),
                          icon: const Icon(Icons.download_rounded, size: 16),
                          label: const Text('立即拉取目录'),
                        ),
                        OutlinedButton(
                          onPressed: _busy || _storeBusy
                              ? null
                              : () => _showStoreConfigDialog(context),
                          child: const Text('配置镜像 / 商店源'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            )
          else
            IsleResponsiveGrid(
              minItemWidth: 250,
              maxColumns: 4,
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final plugin in visiblePlugins)
                  _buildStorePluginTile(context, plugin),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildStorePluginTile(
    BuildContext context,
    Map<String, dynamic> plugin,
  ) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final id = plugin['id']?.toString() ?? '';
    final name = plugin['name']?.toString() ?? id;
    final version = plugin['version']?.toString().trim() ?? '';
    final installedVersion = plugin['installedVersion']?.toString().trim() ?? '';
    final description = plugin['description']?.toString() ?? '';
    final category = plugin['category']?.toString();
    final sizeLabel = _formatPluginSize(plugin['sizeBytes']);
    final installed = plugin['installed'] == true;
    final updateAvailable = plugin['updateAvailable'] == true;
    final catColor = appCategoryColor(category, colors);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette['cardTop'],
        borderRadius: IsleRadius.brMd,
        border: Border.all(
          color: IsleGlass.rimBorderColor(theme.brightness == Brightness.dark),
          width: 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (updateAvailable)
                IsleStatusBadge(label: '可更新', color: palette['brandAmber'])
              else if (installed)
                IsleStatusBadge(label: '已安装', color: palette['brandSage'])
              else if (category != null && category.isNotEmpty)
                IsleStatusBadge(
                  label: appCategoryLabel(category),
                  color: catColor,
                ),
            ],
          ),
          if (version.isNotEmpty || sizeLabel.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              [
                if (version.isNotEmpty) 'v$version',
                if (plugin['mode'] == 'static') '0 MB 纯静态',
                if (sizeLabel.isNotEmpty) sizeLabel,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          if (updateAvailable)
            FilledButton.icon(
              key: ValueKey('upgradeStorePlugin_$id'),
              onPressed: _busy || _storeBusy
                  ? null
                  : () => _upgradeStorePlugin(plugin),
              icon: const Icon(Icons.system_update_alt_rounded, size: 16),
              label: Text(
                installedVersion.isNotEmpty
                    ? '更新 v$installedVersion → v$version'
                    : '更新 v$version',
              ),
            )
          else
            FilledButton.tonal(
              key: ValueKey('installStorePlugin_$id'),
              onPressed: _busy || _storeBusy || installed
                  ? null
                  : () => _installStorePlugin(plugin),
              child: Text(installed ? '已安装' : '下载安装'),
            ),
        ],
      ),
    );
  }

  Future<void> _showStoreConfigDialog(BuildContext context) async {
    final isOfficial = _store?['isOfficial'] != false;
    final registryCtrl = TextEditingController(
      text: isOfficial ? '' : (_store?['registryUrl']?.toString() ?? ''),
    );
    final mirrorCtrl = TextEditingController(
      text: _store?['mirrorPrefix']?.toString() ?? '',
    );
    final defaultUrl =
        _store?['defaultUrl']?.toString().trim().isNotEmpty == true
        ? _store!['defaultUrl'].toString()
        : _defaultOfficialStoreUrl;

    try {
      final result = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (dialogCtx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('配置 Git 在线插件商店'),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      key: const ValueKey('storeRegistryUrlField'),
                      controller: registryCtrl,
                      decoration: InputDecoration(
                        labelText: '自定义 Git registry.json 地址（留空用官方默认）',
                        hintText: defaultUrl,
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      key: const ValueKey('storeMirrorPrefixField'),
                      controller: mirrorCtrl,
                      decoration: const InputDecoration(
                        labelText: 'GitHub 加速镜像前缀（可选）',
                        hintText: 'https://ghfast.top/',
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        for (final preset in _mirrorPresets)
                          ChoiceChip(
                            label: Text(preset.$1),
                            selected: mirrorCtrl.text.trim() == preset.$2,
                            onSelected: (_) {
                              setDialogState(() {
                                mirrorCtrl.text = preset.$2;
                              });
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '所有下载的 .liapp.zip 均强制校验 SHA-256；自定义源插件安装后需管理员确认激活。',
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(
                  dialogCtx,
                ).pop(<String, dynamic>{'resetDefault': true}),
                child: const Text('恢复官方默认'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const ValueKey('saveStoreConfigButton'),
                onPressed: () => Navigator.of(dialogCtx).pop(<String, dynamic>{
                  'registryUrl': registryCtrl.text.trim(),
                  'mirrorPrefix': mirrorCtrl.text.trim(),
                  'resetDefault': false,
                }),
                child: const Text('保存并刷新'),
              ),
            ],
          ),
        ),
      );
      if (!mounted || result == null) return;
      await _updateStoreConfig(
        registryUrl: result['registryUrl']?.toString() ?? '',
        mirrorPrefix: result['mirrorPrefix']?.toString() ?? '',
        resetDefault: result['resetDefault'] == true,
      );
    } finally {
      registryCtrl.dispose();
      mirrorCtrl.dispose();
    }
  }
}
