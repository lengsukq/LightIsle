part of 'apps_center_page.dart';

extension _AppsCenterCards on _AppsCenterPageState {
  Widget _buildEmbeddedWorkbench(
    BuildContext context,
    Map<String, dynamic> app,
  ) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final draft = AppConfigDraft.fromApp(app);
    final (runtimeLabel, runtimeColor) = appRuntimeBadge(app, draft.webMode);
    final urlText = _activeWorkbenchUrl ?? '';
    return IsleSurface(
      key: ValueKey('embeddedAppWorkbench_$_workbenchReloadKey'),
      radius: IsleRadius.hero,
      margin: EdgeInsets.zero,
      padding: EdgeInsets.all(_workbenchFullscreen ? 14 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('workbenchBackButton'),
                    onPressed: () {
                      _updateState(() {
                        _activeWorkbenchAppId = null;
                        _activeWorkbenchUrl = null;
                        _workbenchFullscreen = false;
                      });
                      _reload(refresh: false);
                    },
                    icon: const Icon(Icons.arrow_back_rounded, size: 16),
                    label: const Text('返回应用中心'),
                  ),
                  Text(
                    draft.name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (_isAdmin) ...[
                    IsleStatusBadge(label: runtimeLabel, color: runtimeColor),
                    IsleStatusBadge(
                      label: app['locationKind'] == 'external'
                          ? '其他盘 · ${app['locationName'] ?? '外置盘'}'
                          : '内置盘 · ${app['locationName'] ?? 'Mac 内置盘'}',
                      color: app['locationKind'] == 'external'
                          ? palette['brandSage']
                          : colors.primary,
                    ),
                  ],
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('workbenchRefreshButton'),
                    onPressed: () => _launchApp(app),
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('重新打开窗口'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('workbenchFullscreenButton'),
                    onPressed: () => _updateState(
                      () => _workbenchFullscreen = !_workbenchFullscreen,
                    ),
                    icon: Icon(
                      _workbenchFullscreen
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                      size: 16,
                    ),
                    label: Text(_workbenchFullscreen ? '退出全屏' : '全屏展开'),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('workbenchExternalButton'),
                    onPressed: () => _launchApp(app, preferExternal: true),
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: const Text('外部浏览器打开'),
                  ),
                ],
              ),
            ],
          ),
          Divider(
            height: 20,
            color: IsleGlass.rimBorderColor(
              theme.brightness == Brightness.dark,
            ),
          ),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: IsleDecorations.recessedWell(context, radius: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '轻应用运行会话 · ${draft.name}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                SelectableText(
                  urlText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOfficialTemplatesCard(BuildContext context) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final violet = palette['brandViolet'];
    return IsleSurface(
      radius: IsleRadius.hero,
      tint: violet,
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IsleSquircleBadge(
                icon: Icons.auto_awesome_rounded,
                color: violet,
                size: 36,
                iconSize: 18,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '官方精选家庭轻应用模板（0 MB 静态即装即用）',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
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
                  labelText: '模板安装目标位置',
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
          const SizedBox(height: 14),
          IsleResponsiveGrid(
            minItemWidth: 240,
            maxColumns: 4,
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final tpl in _templates)
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: palette['cardTop'],
                    borderRadius: IsleRadius.brMd,
                    border: Border.all(
                      color: IsleGlass.rimBorderColor(
                        theme.brightness == Brightness.dark,
                      ),
                      width: 1.0,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tpl['name']?.toString() ?? '',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        tpl['description']?.toString() ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 10),
                      FilledButton.tonal(
                        onPressed: _busy || tpl['installed'] == true
                            ? null
                            : () => _installOfficialTemplate(tpl),
                        child: Text(tpl['installed'] == true ? '已安装' : '一键安装'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAppCard(BuildContext context, Map<String, dynamic> app) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final draft = AppConfigDraft.fromApp(app);
    final id = draft.id, name = draft.name;
    final description = app['description']?.toString().trim() ?? '';
    final category = app['category']?.toString();
    final catColor = appCategoryColor(category, colors);
    final isWaking = _wakingAppId == id;
    final webMap = app['web'] is Map ? app['web'] as Map : const {};
    final lastError =
        (app['lastError'] ?? app['validationError'] ?? webMap['lastError'])
            ?.toString()
            .trim() ??
        '';
    final diag = app['diagnostic'] is Map
        ? Map<String, dynamic>.from(app['diagnostic'] as Map)
        : null;
    final (runtimeLabel, runtimeColor) = appRuntimeBadge(app, draft.webMode);
    final accessLabel = switch (draft.accessPolicy) {
      'all_members' => '全员可用',
      'selected_members' => '指定成员',
      _ => '仅管理员',
    };
    final cronSummary = draft.cronExpression.isEmpty
        ? null
        : (draft.cronEnabled
              ? '定时 ${draft.cronExpression}'
              : '定时已暂停 (${draft.cronExpression})');

    return IsleSurface(
      key: ValueKey('appCard_$id'),
      margin: EdgeInsets.zero,
      tint: catColor,
      radius: IsleRadius.card,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IsleSquircleBadge(
                icon: appCategoryIcon(category),
                color: catColor,
                size: 38,
                iconSize: 19,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IsleStatusBadge(
                          label: appCategoryLabel(category),
                          color: catColor,
                        ),
                      ],
                    ),
                    if (description.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (_isAdmin) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                IsleStatusBadge(label: runtimeLabel, color: runtimeColor),
                IsleStatusBadge(
                  label: app['locationKind'] == 'external'
                      ? '其他盘 · ${app['locationName'] ?? '外置盘'}'
                      : '内置盘 · ${app['locationName'] ?? 'Mac 内置盘'}',
                  color: app['locationKind'] == 'external'
                      ? palette['brandSage']
                      : colors.primary,
                ),
                if (app['pendingActivation'] == true)
                  IsleStatusBadge(
                    label: '待首次激活',
                    color: palette['brandAmber'],
                  ),
                IsleStatusBadge(
                  label: accessLabel,
                  color: palette['brandViolet'],
                ),
                if (cronSummary != null)
                  IsleStatusBadge(
                    label: cronSummary,
                    color: palette['brandBlue'],
                  ),
              ],
            ),
            if (diag != null) ...[
              const SizedBox(height: 8),
              AppDiagnosticBanner(diag: diag),
            ] else if (lastError.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                lastError,
                style: TextStyle(
                  fontSize: 12.5,
                  color: colors.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (_isAdmin && app['pendingActivation'] == true)
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _performAction(app, 'activate'),
                  icon: const Icon(Icons.verified_outlined, size: 16),
                  label: const Text('确认激活'),
                ),
              FilledButton.icon(
                key: ValueKey('launchApp_$id'),
                onPressed: isWaking ? null : () => _launchApp(app),
                icon: Icon(
                  isWaking
                      ? Icons.hourglass_top_rounded
                      : Icons.open_in_new_rounded,
                  size: 16,
                ),
                label: Text(isWaking ? '正在唤醒…' : '立即打开'),
              ),
              if (_isAdmin)
                OutlinedButton.icon(
                  key: ValueKey('detailApp_$id'),
                  onPressed: _busy ? null : () => _openAppDetailPage(app),
                  icon: const Icon(Icons.tune_rounded, size: 16),
                  label: const Text('详情与设置'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
