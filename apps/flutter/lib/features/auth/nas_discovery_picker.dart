import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/isle_route.dart';
import '../../core/nas_discovery.dart';
import '../../core/widgets.dart';

/// Mobile login helper. Selecting a result returns an address to the caller;
/// it never starts login or changes certificate trust.
class NasDiscoveryPicker extends StatefulWidget {
  const NasDiscoveryPicker({
    super.key,
    required this.onSelected,
    this.service,
    this.enabled = true,
    @visibleForTesting this.platformOverride,
  });

  final ValueChanged<NasDiscoveryServer> onSelected;
  final NasDiscoveryService? service;
  final bool enabled;
  @visibleForTesting
  final TargetPlatform? platformOverride;

  @override
  State<NasDiscoveryPicker> createState() => _NasDiscoveryPickerState();
}

class _NasDiscoveryPickerState extends State<NasDiscoveryPicker> {
  late final NasDiscoveryService _service =
      widget.service ?? NasDiscoveryService();

  bool get _supportsDiscovery =>
      !kIsWeb &&
      switch (widget.platformOverride ?? defaultTargetPlatform) {
        TargetPlatform.android || TargetPlatform.iOS => true,
        _ => false,
      };

  Future<void> _openPicker() async {
    final selected = await showIsleDialog<NasDiscoveryServer>(
      context: context,
      builder: (_) => _NasDiscoveryDialog(service: _service),
    );
    if (!mounted || selected == null) return;
    widget.onSelected(selected);
  }

  @override
  void dispose() {
    unawaited(_service.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_supportsDiscovery) return const SizedBox.shrink();
    return TextButton.icon(
      key: const Key('nasDiscoveryButton'),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        minimumSize: const Size(0, 28),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: widget.enabled ? _openPicker : null,
      icon: const Icon(Icons.wifi_find_rounded, size: 15),
      label: const Text('自动查找我的 NAS', style: TextStyle(fontSize: 12)),
    );
  }
}

class _NasDiscoveryDialog extends StatefulWidget {
  const _NasDiscoveryDialog({required this.service});

  final NasDiscoveryService service;

  @override
  State<_NasDiscoveryDialog> createState() => _NasDiscoveryDialogState();
}

class _NasDiscoveryDialogState extends State<_NasDiscoveryDialog> {
  bool _searching = true;
  List<NasDiscoveryServer> _servers = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_search());
  }

  Future<void> _search() async {
    setState(() {
      _searching = true;
      _servers = const [];
      _error = null;
    });
    try {
      final servers = await widget.service.discover();
      if (!mounted) return;
      setState(() {
        _servers = servers;
        _searching = false;
      });
    } on NasDiscoveryCancelled {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = '局域网搜索已取消。';
      });
    } on NasDiscoveryException catch (error) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = '无法搜索局域网 NAS，请检查网络后重试。';
      });
    }
  }

  @override
  void dispose() {
    unawaited(widget.service.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = IsleGlass.rimBorderColor(isDark);

    return AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      shape: IsleShapes.card(
        side: BorderSide(color: borderColor, width: 1.0),
      ),
      title: Text(
        '附近的 LightIsle',
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '点选同一局域网下的设备即可自动填入连接地址，不会自动登录。',
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 12.5,
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            if (_searching) ...[
              const IsleLoadingState(
                compact: true,
                padding: EdgeInsets.symmetric(vertical: 14),
                label: '正在搜索当前局域网…',
              ),
            ] else if (_error != null) ...[
              Text(_error!, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _search,
                  icon: const Icon(Icons.refresh_rounded, size: 17),
                  label: const Text('重新搜索'),
                ),
              ),
            ] else if (_servers.isEmpty) ...[
              const Text(
                '未发现设备，请确认 Mac 端正在运行且位于同一局域网。',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _search,
                  icon: const Icon(Icons.refresh_rounded, size: 17),
                  label: const Text('重新搜索'),
                ),
              ),
            ] else ...[
              Container(
                decoration: ShapeDecoration(
                  shape: IsleShapes.md(
                    side: BorderSide(color: borderColor, width: 1.0),
                  ),
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.03)
                      : colors.surfaceContainerHighest.withValues(alpha: 0.28),
                ),
                clipBehavior: Clip.antiAlias,
                child: Material(
                  type: MaterialType.transparency,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var index = 0; index < _servers.length; index++) ...[
                        if (index > 0)
                          Divider(
                            height: 1,
                            thickness: 0.7,
                            indent: 48,
                            color: borderColor,
                          ),
                        Builder(
                          builder: (context) {
                            final isHttps = _servers[index].address.startsWith(
                              'https://',
                            );
                            final tintColor = isHttps
                                ? const Color(0xff10b981)
                                : const Color(0xfff59e0b);
                            return ListTile(
                              key: Key('nasDiscoveryResult_$index'),
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 2,
                              ),
                              leading: Container(
                                width: 30,
                                height: 30,
                                decoration: ShapeDecoration(
                                  color: tintColor.withValues(
                                    alpha: isDark ? 0.20 : 0.11,
                                  ),
                                  shape: IsleShapes.squircle(8),
                                ),
                                child: Icon(
                                  Icons.dns_rounded,
                                  color: tintColor,
                                  size: 16.5,
                                ),
                              ),
                              title: Text(
                                _servers[index].name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13.5,
                                ),
                              ),
                              subtitle: Text(
                                _servers[index].address,
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: IsleBadgePill(
                                label: isHttps ? 'HTTPS' : '未加密',
                                color: isHttps
                                    ? const Color(0xff10b981)
                                    : colors.onSurfaceVariant,
                              ),
                              onTap: () =>
                                  Navigator.of(context).pop(_servers[index]),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('nasDiscoveryCancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_searching ? '取消搜索' : '关闭'),
        ),
      ],
    );
  }
}
