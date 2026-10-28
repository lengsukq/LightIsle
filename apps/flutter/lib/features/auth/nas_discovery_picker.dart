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
        label: const Text('自动查找我的 NAS'),
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
    title: const Text('查找附近的 LightIsle'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('请确认手机和 Mac 接入同一个家庭网络（Mac 可以使用网线），并在 Mac 开启其他设备访问。点选设备即可填入地址，不会自动登录。'),
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
            const Text('没有找到 LightIsle。请检查 Mac 是否正在运行、是否允许其他设备连接；也可以手动输入地址。'),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _search,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新搜索'),
            ),
          ] else ...[
            const Text('请选择要连接的设备。首次使用加密连接时，需要核对 Mac 上的连接验证信息。'),
            const SizedBox(height: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var index = 0; index < _servers.length; index++) ...[
                  if (index > 0) const Divider(height: 1),
                  Builder(builder: (context) {
                    final isHttps = _servers[index].address.startsWith('https://');
                    final tintColor = isHttps ? const Color(0xff10b981) : const Color(0xfff59e0b);
                    final isDark = Theme.of(context).brightness == Brightness.dark;
                    return ListTile(
                      key: Key('nasDiscoveryResult_$index'),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      leading: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: tintColor.withValues(alpha: isDark ? 0.22 : 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(Icons.dns_rounded, color: tintColor, size: 18),
                      ),
                      title: Text(_servers[index].name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      subtitle: Text(_servers[index].address, style: const TextStyle(fontSize: 12.5)),
                      trailing: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: (isHttps ? const Color(0xff10b981) : Theme.of(context).colorScheme.error).withValues(alpha: isDark ? 0.20 : 0.10),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          isHttps ? '加密' : '未加密',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: isHttps ? const Color(0xff10b981) : Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                      onTap: () => Navigator.of(context).pop(_servers[index]),
                    );
                  }),
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
