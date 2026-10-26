import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/nas_discovery.dart';

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
    final selected = await showDialog<NasDiscoveryServer>(
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
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        key: const Key('nasDiscoveryButton'),
        onPressed: widget.enabled ? _openPicker : null,
        icon: const Icon(Icons.wifi_find_rounded),
        label: const Text('查找局域网 NAS'),
      ),
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
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('查找局域网 NAS'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('搜索约 10 秒，按 NAS 实际广播的 HTTP/HTTPS 协议显示地址。选择不会自动登录；HTTP 不加密，HTTPS 仍需校验证书。'),
          const SizedBox(height: 14),
          if (_searching) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            const Text('正在搜索当前局域网…'),
          ] else if (_error != null) ...[
            Text(_error!),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _search,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新搜索'),
            ),
          ] else if (_servers.isEmpty) ...[
            const Text('没有发现 LightIsle NAS。你仍可手动输入服务器地址。'),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _search,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新搜索'),
            ),
          ] else ...[
            const Text('选择 NAS 后会填入地址，不会自动登录。HTTPS 请核对证书指纹；HTTP 只适用于可信局域网。'),
            const SizedBox(height: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var index = 0; index < _servers.length; index++) ...[
                  if (index > 0) const Divider(height: 1),
                  ListTile(
                    key: Key('nasDiscoveryResult_$index'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.dns_outlined),
                    title: Text(_servers[index].name),
                    subtitle: Text(_servers[index].address),
                    trailing: Text(
                      _servers[index].address.startsWith('https://') ? '加密' : '未加密',
                      style: TextStyle(
                        color: _servers[index].address.startsWith('https://')
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.error,
                      ),
                    ),
                    onTap: () => Navigator.of(context).pop(_servers[index]),
                  ),
                ],
              ],
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
