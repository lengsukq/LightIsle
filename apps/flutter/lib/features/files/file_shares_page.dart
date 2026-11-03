import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';

class FileShareEntry {
  const FileShareEntry({
    required this.id,
    required this.path,
    required this.createdAt,
    required this.expiresAt,
    this.isFolder = false,
    this.hasPassword = false,
    this.maxDownloads = 0,
    this.downloadCount = 0,
  });

  final String id;
  final String path;
  final int createdAt;
  final int expiresAt;
  // Folder links stream a bounded ZIP download instead of a single file.
  final bool isFolder;
  // Display-only protection summary; the verifier itself never leaves the
  // server.
  final bool hasPassword;
  final int maxDownloads;
  final int downloadCount;

  factory FileShareEntry.fromJson(Map<String, dynamic> json) => FileShareEntry(
    id: json['id']?.toString() ?? '',
    path: json['path']?.toString() ?? '',
    createdAt: _shareTimestamp(json['createdAt']),
    expiresAt: _shareTimestamp(json['expiresAt']),
    isFolder: json['kind'] == 'dir',
    hasPassword: json['hasPassword'] == true,
    maxDownloads: _shareTimestamp(json['maxDownloads']),
    downloadCount: _shareTimestamp(json['downloadCount']),
  );
}

int _shareTimestamp(Object? value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text) ?? 0,
  _ => 0,
};

/// Reusable settings page for reviewing and revoking the current user's links.
class FileSharesPage extends StatefulWidget {
  const FileSharesPage({super.key, required this.api});

  final LightIsleApi api;

  @override
  State<FileSharesPage> createState() => _FileSharesPageState();
}

class _FileSharesPageState extends State<FileSharesPage> {
  List<FileShareEntry> _shares = const [];
  final Set<String> _revoking = <String>{};
  bool _loading = false;
  bool _loaded = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant FileSharesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await widget.api.get('/api/v2/file-shares');
      if (!mounted || generation != _generation) return;
      setState(() {
        _shares = objectList(response['shares'])
            .map(FileShareEntry.fromJson)
            .toList(growable: false);
        _loaded = true;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '读取分享列表失败：${userFacingError(error)}');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _revoke(FileShareEntry share) async {
    if (_revoking.contains(share.id)) return;
    if (!await confirmAction(
      context,
      '撤销分享链接',
      '停止分享“${share.path}”？已经发出的下载链接将立即失效。',
      action: '撤销链接',
      isDestructive: true,
    )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _revoking.add(share.id);
      _error = null;
    });
    try {
      await widget.api.send(
        'DELETE',
        '/api/v2/file-shares/${Uri.encodeComponent(share.id)}',
      );
      if (mounted) {
        setState(() {
          _shares = _shares.where((item) => item.id != share.id).toList();
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '撤销分享失败：${userFacingError(error)}');
    } finally {
      if (mounted) setState(() => _revoking.remove(share.id));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('我的文件分享'),
      actions: [
        IconButton(
          tooltip: '刷新分享列表',
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh_rounded),
        ),
        const SizedBox(width: 8),
      ],
    ),
    body: LayoutBuilder(
      builder: (context, constraints) {
        return IsleListView(
          padding: EdgeInsets.all(IsleLayout.pageInset(constraints.maxWidth)),
          children: [
            if (_error != null) Notice(_error!, error: true, onRetry: _load),
            if (_loading && !_loaded)
              const Padding(
                padding: EdgeInsets.only(top: 20),
                child: LinearProgressIndicator(),
              )
            else if (_loaded && _shares.isEmpty && _error == null)
              IsleSurface(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Icon(
                      Icons.link_off_rounded,
                      size: 34,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '当前没有有效的分享链接。',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '你可以在文件页选择一个文件或文件夹，再打开“分享”。',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              )
            else
              IsleResponsiveGrid(
                minItemWidth: 340,
                maxColumns: 2,
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final share in _shares)
                    IsleSurface(
                      radius: 16,
                      margin: EdgeInsets.zero,
                      padding: EdgeInsets.zero,
                      child: _shareCard(context, share),
                    ),
                ],
              ),
            const SizedBox(height: 24),
            const IsleHelpDisclosure(
              summary: '分享说明',
              details:
                  '分享可用于文件或文件夹 ZIP，最长有效 7 天。链接只在创建时显示。'
                  '文件变化、账号停用或权限撤销后，链接会失效。',
            ),
          ],
        );
      },
    ),
  );

  Widget _shareCard(BuildContext context, FileShareEntry share) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final created = _displayShareTime(share.createdAt);
    final expires = _displayShareTime(share.expiresAt);
    final iconColor = share.isFolder ? const Color(0xff0ea5e9) : const Color(0xff64748b);
    final action = OutlinedButton.icon(
      onPressed: _revoking.contains(share.id) ? null : () => _revoke(share),
      icon: _revoking.contains(share.id)
          ? const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.link_off_rounded),
      label: Text(_revoking.contains(share.id) ? '正在撤销' : '撤销链接'),
    );
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: iconColor.withValues(alpha: isDark ? 0.22 : 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          share.isFolder
              ? Icons.folder_outlined
              : Icons.insert_drive_file_outlined,
          color: iconColor,
          size: 18,
        ),
      ),
      title: SelectableText(
        share.path,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (share.hasPassword ||
              share.maxDownloads > 0 ||
              share.downloadCount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (share.hasPassword)
                    _shareBadge(context, Icons.lock_outline_rounded, '密码保护'),
                  if (share.maxDownloads > 0)
                    _shareBadge(
                      context,
                      Icons.pin_rounded,
                      '限 ${share.maxDownloads} 次',
                    ),
                  if (share.downloadCount > 0)
                    _shareBadge(
                      context,
                      Icons.download_rounded,
                      '已下载 ${share.downloadCount} 次',
                    ),
                ],
              ),
            ),
          Text(
            '创建：$created · 到期：$expires',
            style: TextStyle(fontSize: 12.5, color: colors.onSurfaceVariant),
          ),
        ],
      ),
      trailing: action,
    );
  }

  Widget _shareBadge(BuildContext context, IconData icon, String label) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: isDark ? 0.20 : 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: colors.primary),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: colors.primary,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

String _displayShareTime(int timestamp) {
  if (timestamp <= 0) return '未知';
  final value = DateTime.fromMillisecondsSinceEpoch(
    timestamp * 1000,
    isUtc: true,
  ).toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} ${two(value.hour)}:${two(value.minute)}';
}
