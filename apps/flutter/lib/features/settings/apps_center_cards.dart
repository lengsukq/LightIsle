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

  Widget _buildAppCard(BuildContext context, Map<String, dynamic> app) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final draft = AppConfigDraft.fromApp(app);
    final id = draft.id, name = draft.name;
    final storeEntry = _storePluginFor(id);
    final hasStoreUpdate = storeEntry?['updateAvailable'] == true;
    final storeNextVersion = storeEntry?['version']?.toString().trim() ?? '';
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
              if (_isAdmin && hasStoreUpdate && storeEntry != null)
                FilledButton.tonalIcon(
                  key: ValueKey('cardUpgradeApp_$id'),
                  onPressed: _busy || _storeBusy
                      ? null
                      : () => _upgradeStorePlugin(storeEntry),
                  icon: const Icon(Icons.system_update_alt_rounded, size: 16),
                  label: Text('更新 v$storeNextVersion'),
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
