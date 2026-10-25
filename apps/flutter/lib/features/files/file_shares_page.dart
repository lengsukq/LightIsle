import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
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
      final response = await widget.api.get('/api/v1/file-shares');
      if (!mounted || generation != _generation) return;
      setState(() {
        _shares = objectList(response['shares'])
            .map(FileShareEntry.fromJson)
            .toList(growable: false);
        _loaded = true;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '读取分享列表失败：${error.toString()}');
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
        '/api/v1/file-shares/${Uri.encodeComponent(share.id)}',
      );
      if (mounted) {
        setState(() {
          _shares = _shares.where((item) => item.id != share.id).toList();
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '撤销分享失败：${error.toString()}');
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
        final compact = constraints.maxWidth < 700;
        return IsleListView(
          padding: EdgeInsets.all(compact ? 16 : 24),
          children: [
            const IslePageHeader(
              title: '我的文件分享',
              subtitle: '查看并撤销你创建的限时下载链接。',
              icon: Icons.ios_share_rounded,
            ),
            const SizedBox(height: 8),
            const Notice(
              '分享可以是单个文件或文件夹（打包为 ZIP 流式下载，最长有效 7 天）。链接只在创建时显示；对象变化、账号停用或读取授权撤销后，下载也会失效。',
            ),
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
              ..._shares.map((share) => _shareCard(context, share, compact)),
            const SizedBox(height: 24),
          ],
        );
      },
    ),
  );

  Widget _shareCard(BuildContext context, FileShareEntry share, bool compact) {
    final colors = Theme.of(context).colorScheme;
    final created = _displayShareTime(share.createdAt);
    final expires = _displayShareTime(share.expiresAt);
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
    return IsleSurface(
      padding: EdgeInsets.all(compact ? 14 : 18),
      radius: IsleTokens.cardRadius,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                share.isFolder
                    ? Icons.folder_outlined
                    : Icons.insert_drive_file_outlined,
                color: colors.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SelectableText(
                  share.path,
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (share.hasPassword ||
              share.maxDownloads > 0 ||
              share.downloadCount > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (share.hasPassword)
                    _shareBadge(context, Icons.password_rounded, '密码保护'),
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
          Text('创建：$created', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 2),
          Text(
            '到期：$expires',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerRight, child: action),
        ],
      ),
    );
  }

  Widget _shareBadge(BuildContext context, IconData icon, String label) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(IsleTokens.controlRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: colors.onSecondaryContainer),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colors.onSecondaryContainer,
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
