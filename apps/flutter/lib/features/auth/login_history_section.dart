import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/login_history_store.dart';
import '../../core/widgets.dart';

export 'account_switcher_dialog.dart';

/// Compact color-coded badge displaying server/domain HTTP RTT latency.
class ServerLatencyBadge extends StatelessWidget {
  const ServerLatencyBadge({super.key, required this.result, this.onTap});

  final ServerLatencyResult? result;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colors = theme.colorScheme;
    final state = result?.state ?? ServerLatencyState.probing;
    final ms = result?.latencyMs;

    final Color badgeColor;
    final IconData? icon;
    final String label;

    switch (state) {
      case ServerLatencyState.probing:
        badgeColor = colors.onSurfaceVariant;
        icon = Icons.radar_rounded;
        label = result?.message ?? '测速中…';
      case ServerLatencyState.online:
        final value = ms ?? 1;
        if (value < 80) {
          badgeColor = const Color(0xff10b981);
        } else if (value <= 250) {
          badgeColor = const Color(0xfff59e0b);
        } else {
          badgeColor = const Color(0xffef4444);
        }
        icon = null;
        label = '$value ms';
      case ServerLatencyState.certError:
        badgeColor = const Color(0xfff59e0b);
        icon = Icons.shield_outlined;
        label = result?.message ?? 'HTTPS 证书需核对';
      case ServerLatencyState.offline:
        badgeColor = colors.error;
        icon = Icons.cloud_off_rounded;
        label = result?.message ?? '离线 / 超时';
      case ServerLatencyState.invalid:
        badgeColor = colors.onSurfaceVariant;
        icon = Icons.info_outline_rounded;
        label = result?.message ?? '地址待完善';
    }

    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: ShapeDecoration(
        shape: const StadiumBorder(),
        color: badgeColor.withValues(alpha: isDark ? 0.18 : 0.11),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state == ServerLatencyState.online)
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: badgeColor,
                shape: BoxShape.circle,
              ),
            )
          else if (icon != null)
            Icon(icon, size: 12, color: badgeColor),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: badgeColor,
                height: 1.15,
              ),
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return pill;
    return InkWell(borderRadius: IsleRadius.brPill, onTap: onTap, child: pill);
  }
}

/// Live latency status row beneath the server URL input on [LoginPage].
class CurrentServerLatencyBar extends StatelessWidget {
  const CurrentServerLatencyBar({
    super.key,
    required this.serverUrl,
    required this.result,
    required this.onProbe,
    this.enabled = true,
  });

  final String serverUrl;
  final ServerLatencyResult? result;
  final VoidCallback onProbe;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (serverUrl.trim().isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Icon(Icons.speed_rounded, size: 15, color: colors.onSurfaceVariant),
          Text(
            '当前域名/地址延迟：',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (result != null)
            ServerLatencyBadge(
              key: const Key('currentServerLatencyBadge'),
              result: result,
              onTap: enabled ? onProbe : null,
            )
          else
            Text(
              '未检测',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          TextButton.icon(
            key: const Key('probeCurrentServerButton'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: enabled ? onProbe : null,
            icon: const Icon(Icons.refresh_rounded, size: 14),
            label: Text(
              result == null ? '检测延迟' : '重新测速',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Saved login history list displayed on [LoginPage].
/// Tapping an item fills `server + username + password + fingerprint`;
/// the route button manages multi-address & auto-select settings;
/// the trailing button triggers immediate connection & login.
class LoginHistorySection extends StatelessWidget {
  const LoginHistorySection({
    super.key,
    required this.entries,
    required this.latencies,
    required this.selectedKey,
    required this.busy,
    required this.onSelect,
    required this.onQuickLogin,
    required this.onRemove,
    required this.onRefreshLatencies,
    this.onManageEndpoints,
  });

  final List<LoginHistoryEntry> entries;
  final Map<String, ServerLatencyResult> latencies;
  final String? selectedKey;
  final bool busy;
  final ValueChanged<LoginHistoryEntry> onSelect;
  final ValueChanged<LoginHistoryEntry> onQuickLogin;
  final ValueChanged<LoginHistoryEntry> onRemove;
  final VoidCallback onRefreshLatencies;
  final ValueChanged<LoginHistoryEntry>? onManageEndpoints;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colors = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        key: const Key('loginHistorySection'),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: ShapeDecoration(
          shape: IsleShapes.interactive(
            side: BorderSide(color: IsleGlass.hairlineBorder(isDark)),
          ),
          color: isDark
              ? Colors.white.withValues(alpha: 0.04)
              : colors.primary.withValues(alpha: 0.04),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.history_rounded, size: 18, color: colors.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '已保存主机与账号（支持多地址择优与手动选线）',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton.icon(
                  key: const Key('refreshHistoryLatenciesButton'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: busy ? null : onRefreshLatencies,
                  icon: const Icon(Icons.speed_rounded, size: 14),
                  label: const Text('刷新延迟', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < entries.length; i++) ...[
                      if (i > 0) const SizedBox(height: 6),
                      _HistoryItemTile(
                        entry: entries[i],
                        latencies: latencies,
                        selected: entries[i].key == selectedKey,
                        busy: busy,
                        onTap: () => onSelect(entries[i]),
                        onQuickLogin: () => onQuickLogin(entries[i]),
                        onManageEndpoints: onManageEndpoints == null
                            ? null
                            : () => onManageEndpoints!(entries[i]),
                        onRemove: () => onRemove(entries[i]),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryItemTile extends StatelessWidget {
  const _HistoryItemTile({
    required this.entry,
    required this.latencies,
    required this.selected,
    required this.busy,
    required this.onTap,
    required this.onQuickLogin,
    required this.onRemove,
    this.onManageEndpoints,
  });

  final LoginHistoryEntry entry;
  final Map<String, ServerLatencyResult> latencies;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onQuickLogin;
  final VoidCallback? onManageEndpoints;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colors = theme.colorScheme;
    final preferred = entry.selectPreferredEndpoint(latencies);
    final latency =
        latencies[preferred.probeKey] ?? latencies[entry.serverProbeKey];
    final count = entry.effectiveEndpoints.length;

    return Material(
      color: selected
          ? colors.primary.withValues(alpha: isDark ? 0.18 : 0.10)
          : (isDark
                ? Colors.white.withValues(alpha: 0.04)
                : Colors.white.withValues(alpha: 0.72)),
      shape: IsleShapes.squircle(
        12,
        side: BorderSide(
          color: selected
              ? colors.primary.withValues(alpha: 0.55)
              : IsleGlass.hairlineBorder(isDark),
          width: selected ? 1.2 : 0.8,
        ),
      ),
      child: InkWell(
        key: Key('loginHistoryItem_${entry.key}'),
        customBorder: IsleShapes.squircle(12),
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: ShapeDecoration(
                  shape: IsleShapes.squircle(9),
                  color: colors.primary.withValues(alpha: isDark ? 0.22 : 0.12),
                ),
                child: Icon(
                  entry.isAdmin
                      ? Icons.admin_panel_settings_rounded
                      : Icons.person_rounded,
                  size: 17,
                  color: colors.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          entry.username,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            height: 1.2,
                          ),
                        ),
                        if (entry.hostLabel != null &&
                            entry.hostLabel!.trim().isNotEmpty)
                          Text(
                            '· ${entry.hostLabel!.trim()}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colors.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        if (entry.role != null)
                          Text(
                            entry.isAdmin ? '管理员' : '成员',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colors.onSurfaceVariant,
                              fontSize: 11,
                            ),
                          ),
                        if (count > 1)
                          IsleStatusBadge(
                            label: entry.autoSelectEndpoint
                                ? '自动择优 · $count 线路'
                                : '固定线路 · $count 线路',
                            color: entry.autoSelectEndpoint
                                ? const Color(0xff0a84ff)
                                : colors.onSurfaceVariant,
                          ),
                        ServerLatencyBadge(
                          key: Key('loginHistoryLatency_${entry.key}'),
                          result: latency,
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(
                          preferred.isHttps
                              ? Icons.lock_outline_rounded
                              : Icons.dns_outlined,
                          size: 12,
                          color: colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            preferred.normalizedUrl,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 12,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (onManageEndpoints != null) ...[
                IconButton(
                  key: Key('loginHistoryEndpoints_${entry.key}'),
                  tooltip: '多地址管理与自动择优开关',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: busy ? null : onManageEndpoints,
                  icon: Icon(
                    Icons.alt_route_rounded,
                    size: 17,
                    color: count > 1 ? colors.primary : colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 2),
              ],
              IslePillButton(
                key: Key('loginHistoryQuickLogin_${entry.key}'),
                label: '登录',
                icon: Icons.login_rounded,
                variant: IslePillVariant.primary,
                compact: true,
                onPressed: busy ? null : onQuickLogin,
              ),
              const SizedBox(width: 2),
              IconButton(
                key: Key('loginHistoryRemove_${entry.key}'),
                tooltip: '删除此登录历史',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                padding: EdgeInsets.zero,
                onPressed: busy ? null : onRemove,
                icon: Icon(
                  Icons.close_rounded,
                  size: 16,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Displays one candidate endpoint row inside [showHostEndpointsDialog].
class HostEndpointTile extends StatelessWidget {
  const HostEndpointTile({
    super.key,
    required this.endpoint,
    required this.isPrimary,
    required this.isActive,
    required this.canRemove,
    required this.busy,
    this.latency,
    this.connecting = false,
    this.onSetPrimary,
    this.onManualConnect,
    this.onRemove,
  });

  final HostEndpoint endpoint;
  final bool isPrimary;
  final bool isActive;
  final bool canRemove;
  final bool busy;
  final ServerLatencyResult? latency;
  final bool connecting;
  final VoidCallback? onSetPrimary;
  final VoidCallback? onManualConnect;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    return Container(
      key: Key('hostEndpointItem_${endpoint.normalizedUrl}'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isActive
              ? const Color(0xff10b981).withValues(alpha: 0.65)
              : colors.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IsleStatusBadge(label: endpoint.displayLabel, color: colors.primary),
              if (isPrimary)
                const IsleStatusBadge(label: '默认主地址', color: Color(0xff0a84ff)),
              if (isActive)
                const IsleStatusBadge(label: '当前已连接', color: Color(0xff10b981)),
              if (endpoint.normalizedFingerprint != null)
                IsleStatusBadge(label: '已绑指纹', color: colors.secondary),
              ServerLatencyBadge(result: latency),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  endpoint.normalizedUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                ),
              ),
              if (!isPrimary && onSetPrimary != null)
                TextButton(
                  key: Key('setPrimaryEndpoint_${endpoint.normalizedUrl}'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(0, 28),
                  ),
                  onPressed: busy ? null : onSetPrimary,
                  child: const Text('设为主地址', style: TextStyle(fontSize: 12)),
                ),
              if (onManualConnect != null && !isActive)
                IslePillButton(
                  key: Key('manualConnectEndpoint_${endpoint.normalizedUrl}'),
                  label: connecting ? '连接中…' : '手动连接',
                  icon: Icons.bolt_rounded,
                  variant: IslePillVariant.primary,
                  compact: true,
                  onPressed: busy ? null : onManualConnect,
                ),
              if (canRemove && onRemove != null)
                IconButton(
                  key: Key('removeHostEndpoint_${endpoint.normalizedUrl}'),
                  tooltip: '移除此地址',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  padding: EdgeInsets.zero,
                  onPressed: busy ? null : onRemove,
                  icon: Icon(Icons.close_rounded, size: 16, color: colors.onSurfaceVariant),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
