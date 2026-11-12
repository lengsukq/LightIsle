import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';

/// Displays native Tailscale zero-config mesh detection (`100.64.0.0/10` +
/// MagicDNS) when the connected account has administrator privileges.
class TailscaleStatusCard extends StatefulWidget {
  const TailscaleStatusCard({super.key, required this.api});

  final LightIsleApi api;

  @override
  State<TailscaleStatusCard> createState() => _TailscaleStatusCardState();
}

class _TailscaleStatusCardState extends State<TailscaleStatusCard> {
  Map<String, dynamic>? _status;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final res = await widget.api.get('/api/v2/admin/tailscale');
      if (mounted) setState(() => _status = res);
    } catch (_) {
      // Non-admin accounts receive 403; omit card quietly.
      if (mounted) setState(() => _status = null);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snap = _status;
    if (snap == null) return const SizedBox.shrink();
    final connected = snap['connected'] == true;
    final installed = snap['installed'] == true;
    final ipv4 = snap['ipv4']?.toString() ?? '';
    final magicDns = snap['magicDns']?.toString() ?? '';
    final directUrl = snap['directUrl']?.toString() ?? '';
    final magicUrl = snap['magicUrl']?.toString() ?? '';
    final targetUrl = magicUrl.isNotEmpty ? magicUrl : directUrl;
    final colors = Theme.of(context).colorScheme;

    return IsleSurface(
      radius: 20,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.hub_outlined, size: 20, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Tailscale 零配置异地组网',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IsleStatusBadge(
                label: connected
                    ? '已组网在线'
                    : (installed ? '已安装未连接' : '未安装'),
                color: connected
                    ? const Color(0xFF10B981)
                    : const Color(0xFF64748B),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '刷新组网状态',
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            connected
                ? '已自动识别本机虚拟组网接口${ipv4.isNotEmpty ? ' ($ipv4)' : ''}${magicDns.isNotEmpty ? ' · $magicDns' : ''}，无需公网 IP 即可异地加密直连。'
                : '在宿主 Mac 与手机安装登录同一 Tailscale 账号后，开启局域网访问即可自动双栈监听组网网卡。',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
          if (targetUrl.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SelectableText(
                  targetUrl,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
                ),
                FilledButton.tonalIcon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: targetUrl));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制异地组网直连地址')),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded, size: 15),
                  label: const Text('复制直连地址'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
