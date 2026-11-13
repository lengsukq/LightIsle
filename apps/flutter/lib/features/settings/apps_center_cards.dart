part of 'apps_center_page.dart';

double? _asDoubleOrNull(Object? value) {
  if (value is num) return value.toDouble();
  if (value == null) return null;
  return double.tryParse(value.toString());
}

extension _AppsCenterCards on _AppsCenterPageState {
  Widget _buildEmbeddedWorkbench(
    BuildContext context,
    Map<String, dynamic> app,
  ) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    final draft = AppConfigDraft.fromApp(app);
    final (runtimeLabel, runtimeColor) = _runtimeBadge(app, draft.webMode);
    final urlText = _activeWorkbenchUrl ?? '';
    return IsleSurface(
      key: ValueKey('embeddedAppWorkbench_$_workbenchReloadKey'),
      radius: IsleRadius.card,
      padding: EdgeInsets.all(_workbenchFullscreen ? 12 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
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
                    label: const Text('← 返回应用中心'),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    draft.name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IsleStatusBadge(label: runtimeLabel, color: runtimeColor),
                IsleStatusBadge(
                  label: app['locationKind'] == 'external'
                      ? '其他盘 · ${app['locationName'] ?? '外置盘'}'
                      : '内置盘 · ${app['locationName'] ?? 'Mac 内置盘'}',
                  color: app['locationKind'] == 'external'
                      ? const Color(0xFF0D9488)
                      : colors.primary,
                ),
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
                    label: const Text('🔄 重新打开窗口'),
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
                    label: Text(_workbenchFullscreen ? '⛶ 退出全屏' : '⛶ 全屏展开'),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('workbenchExternalButton'),
                    onPressed: () => _launchApp(app, preferExternal: true),
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: const Text('↗ 外部浏览器打开'),
                  ),
                ],
              ),
            ],
          ),
          const Divider(height: 24),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(12),
            ),
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
                const SizedBox(height: 8),
                Text(
                  '已通过一次性 Launch Ticket 完成免二次登录鉴权并唤起浏览器会话窗口（凭据仅兑换为受保护的 HttpOnly 会话 Cookie，不驻留于地址栏）。若窗口已关闭或被遮挡，可点击上方「🔄 重新打开窗口」或「↗ 外部浏览器打开」。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
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
    return IsleSurface(
      radius: IsleRadius.card,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, size: 20, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '官方精选家庭轻应用模板（0 MB 静态即装即用）',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          if (_appStorage != null &&
              objectList(_appStorage?['locations']).length > 1) ...[
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              key: const ValueKey('templateInstallLocationDropdown'),
              initialValue: _selectedInstallLocationId,
              decoration: const InputDecoration(
                labelText: '模板安装目标位置',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                const DropdownMenuItem(value: '', child: Text('跟随默认位置')),
                for (final loc in objectList(_appStorage?['locations']))
                  DropdownMenuItem(
                    value: loc['id']?.toString() ?? '',
                    enabled: loc['online'] == true && loc['writable'] == true,
                    child: Text(
                      '${loc['kind'] == 'external' ? '其他盘' : '内置盘'} · ${loc['name'] ?? ''}'
                      '${loc['online'] == true ? '' : '（离线）'}',
                    ),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (v) => _updateState(
                      () => _selectedInstallLocationId = v ?? '',
                    ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final tpl in _templates)
                Container(
                  width: 245,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest.withValues(alpha: 0.36),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tpl['name']?.toString() ?? '',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        tpl['description']?.toString() ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      FilledButton.tonal(
                        onPressed: _busy || tpl['installed'] == true
                            ? null
                            : () => _installOfficialTemplate(tpl),
                        child: Text(
                          tpl['installed'] == true ? '已安装' : '一键安装',
                        ),
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
    final draft = AppConfigDraft.fromApp(app);
    final id = draft.id, name = draft.name;
    final description = app['description']?.toString().trim() ?? '家庭轻应用';
    final category = app['category']?.toString();
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
    final (runtimeLabel, runtimeColor) = _runtimeBadge(app, draft.webMode);
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
      radius: IsleRadius.card,
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IsleSquircleBadge(
                icon: _categoryIcon(category),
                color: colors.primary,
                size: 40,
                iconSize: 20,
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
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IsleStatusBadge(
                          label: _categoryLabel(category),
                          color: colors.primary,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
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
                      ? const Color(0xFF0D9488)
                      : colors.primary,
                ),
                if (app['pendingActivation'] == true)
                  const IsleStatusBadge(
                    label: '待首次激活',
                    color: Color(0xFFD97706),
                  ),
                IsleStatusBadge(
                  label: accessLabel,
                  color: const Color(0xFF6366F1),
                ),
                if (cronSummary != null)
                  IsleStatusBadge(
                    label: cronSummary,
                    color: const Color(0xFF0EA5E9),
                  ),
              ],
            ),
            if (diag != null) ...[
              const SizedBox(height: 8),
              _buildDiagnosticBox(theme, colors, diag),
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
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
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
              if (_isAdmin) ...[
                OutlinedButton.icon(
                  key: ValueKey('accessApp_$id'),
                  onPressed: _busy
                      ? null
                      : () => _applySheetResult(
                          showAppMemberAccessSheet(
                            context: context,
                            api: widget.api,
                            app: app,
                            members: _members,
                          ),
                          '已更新“$name”的成员访问权限。',
                        ),
                  icon: const Icon(Icons.group_outlined, size: 16),
                  label: const Text('成员权限'),
                ),
                OutlinedButton.icon(
                  key: ValueKey('configApp_$id'),
                  onPressed: _busy
                      ? null
                      : () => _applySheetResult(
                          showAppLifecycleCronSheet(
                            context: context,
                            api: widget.api,
                            app: app,
                            configuredChannels: _configuredChannels,
                          ),
                          '已保存“$name”的运行与定时设置。',
                        ),
                  icon: const Icon(Icons.tune_rounded, size: 16),
                  label: const Text('运行与定时设置'),
                ),
                OutlinedButton.icon(
                  key: ValueKey('logsApp_$id'),
                  onPressed: () => showAppLogsSheet(
                    context: context,
                    api: widget.api,
                    app: app,
                  ),
                  icon: const Icon(Icons.receipt_long_rounded, size: 16),
                  label: const Text('运行日志'),
                ),
                PopupMenuButton<String>(
                  key: ValueKey('moreActionsApp_$id'),
                  tooltip: '更多操作',
                  onSelected: (act) {
                    if (act == 'delete') {
                      _deleteApp(app);
                    } else if (act == 'export_data') {
                      _exportAppData(app);
                    } else {
                      _performAction(app, act);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'start', child: Text('启动 Web 进程')),
                    PopupMenuItem(value: 'stop', child: Text('休眠 / 停止进程')),
                    PopupMenuItem(value: 'restart', child: Text('重启 Web 进程')),
                    PopupMenuItem(value: 'run_cron', child: Text('立即执行定时任务')),
                    PopupMenuItem(
                      value: 'export_data',
                      child: Text('导出应用数据 (.tar.gz)'),
                    ),
                    PopupMenuDivider(),
                    PopupMenuItem(value: 'delete', child: Text('删除插件')),
                  ],
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  (String, Color) _runtimeBadge(Map<String, dynamic> app, String mode) {
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
    final memBytes = _asDoubleOrNull(
      app['memoryBytes'] ??
          app['rssBytes'] ??
          web['rssBytes'] ??
          runtime['memoryBytes'] ??
          runtime['rssBytes'],
    );
    final memMbRaw = _asDoubleOrNull(
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

  String _categoryLabel(String? c) => switch (c) {
    'network' => '网络监控',
    'media' => '影音工具',
    'home' => '家庭看板',
    'finance' => '账单记账',
    'system' => '系统扩展',
    _ => '实用工具',
  };

  IconData _categoryIcon(String? c) => switch (c) {
    'network' => Icons.router_rounded,
    'media' => Icons.movie_filter_rounded,
    'home' => Icons.home_work_outlined,
    'finance' => Icons.account_balance_wallet_outlined,
    'system' => Icons.memory_rounded,
    _ => Icons.widgets_rounded,
  };

  Widget _buildDiagnosticBox(
    ThemeData theme,
    ColorScheme colors,
    Map<String, dynamic> diag,
  ) {
    final summary = diag['summary']?.toString().trim() ?? '插件启动或配置异常';
    final reason = diag['reason']?.toString().trim() ?? '';
    final logExcerpt = diag['logExcerpt']?.toString().trim() ?? '';
    final dataSafe = diag['dataSafe']?.toString().trim() ?? '';
    final checks = (diag['checks'] is List)
        ? (diag['checks'] as List)
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList()
        : const <String>[];
    final solutions = (diag['solutions'] is List)
        ? (diag['solutions'] as List)
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList()
        : const <String>[];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: colors.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.error.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 16, color: colors.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  summary,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colors.error,
                  ),
                ),
              ),
            ],
          ),
          if (reason.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(
              '原因：$reason',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurface,
                height: 1.4,
              ),
            ),
          ],
          if (logExcerpt.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                logExcerpt,
                style: const TextStyle(
                  fontFamily: 'Menlo',
                  fontSize: 11,
                  height: 1.38,
                ),
              ),
            ),
          ],
          if (checks.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '排查：${checks.first}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
          if (solutions.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '解决：${solutions.first}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurface,
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
          ],
          if (dataSafe.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              dataSafe,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
