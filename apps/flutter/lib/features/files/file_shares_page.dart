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
  final bool isFolder;
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
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    final accent = palette['brandAmber'];
    final protectedCount = _shares.where((s) => s.hasPassword).length;
    final totalDownloads = _shares.fold<int>(
      0,
      (sum, s) => sum + s.downloadCount,
    );

    return Scaffold(
      appBar: IsleAppBar(
        title: const Text('我的文件分享'),
        actions: [
          IconButton(
            tooltip: '刷新分享列表',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IsleHelpButton(
            title: '外链分享安全说明',
            accentColor: accent,
            items: const [
              IsleHelpItem(
                title: '提取码摘要存储',
                body: '加密分享仅在服务端保存密码哈希摘要，不留存明文；若遗忘提取码，可撤销旧链接后重新生成。',
              ),
              IsleHelpItem(
                title: '即时失效与权限跟随',
                body: '撤销分享或到期、达到最大下载次数后链接立即失效；移动或删除源文件后外链同样无法继续读取。',
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return IsleListView(
            maxWidth: IsleLayout.workbenchMaxWidth,
            padding: EdgeInsets.all(IsleLayout.pageInset(constraints.maxWidth)),
            children: [
              IsleFocalStage(
                icon: Icons.share_rounded,
                accent: accent,
                title: '公开与加密分享链接',
                metrics: [
                  IsleFocalMetric(
                    label: '有效外链',
                    value: '${_shares.length}',
                    accent: accent,
                  ),
                  IsleFocalMetric(
                    label: '密码保护',
                    value: '$protectedCount',
                    accent: palette['brandSage'],
                  ),
                  IsleFocalMetric(
                    label: '累计下载',
                    value: '$totalDownloads',
                    accent: palette['brandBlue'],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (_error != null) Notice(_error!, error: true, onRetry: _load),
              if (_loading && !_loaded)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(),
                )
              else if (_loaded && _shares.isEmpty && _error == null)
                const IsleEmptyStateCard(
                  '可在文件页长按或点击文件菜单创建分享。',
                  title: '当前没有有效的分享链接。',
                  icon: Icons.link_off_rounded,
                )
              else ...[
                IsleSectionHeader(
                  title: '有效链接（${_shares.length}）',
                  accentColor: accent,
                ),
                IsleAdaptiveBuilder(
                  builder: (context, tier, width) {
                    final textScale =
                        MediaQuery.textScalerOf(context).scale(14) / 14;
                    if (tier == IsleViewportTier.expanded &&
                        _shares.length > 1 &&
                        textScale <= 1.35) {
                      final cardWidth = (width - 12) / 2;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 10,
                        children: [
                          for (final share in _shares)
                            SizedBox(
                              width: cardWidth,
                              child: IsleSurface(
                                margin: EdgeInsets.zero,
                                padding: EdgeInsets.zero,
                                child: _shareCard(context, share, palette),
                              ),
                            ),
                        ],
                      );
                    }
                    return IsleGroupCard(
                      margin: EdgeInsets.zero,
                      children: [
                        for (final share in _shares)
                          _shareCard(context, share, palette),
                      ],
                    );
                  },
                ),
              ],
              const SizedBox(height: 16),
            ],
          );
        },
      ),
    );
  }

  Widget _shareCard(
    BuildContext context,
    FileShareEntry share,
    IslePalette palette,
  ) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final expires = _displayShareTime(share.expiresAt);
    final iconColor = share.isFolder
        ? palette['brandAmber']
        : palette['brandBlue'];
    final action = OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
      onPressed: _revoking.contains(share.id) ? null : () => _revoke(share),
      icon: _revoking.contains(share.id)
          ? const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.link_off_rounded, size: 15),
      label: Text(_revoking.contains(share.id) ? '正在撤销' : '撤销链接'),
    );
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: iconColor.withValues(alpha: isDark ? 0.22 : 0.12),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Icon(
          share.isFolder
              ? Icons.folder_outlined
              : Icons.insert_drive_file_outlined,
          color: iconColor,
          size: 16.5,
        ),
      ),
      title: SelectableText(
        share.path,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (share.hasPassword ||
              share.maxDownloads > 0 ||
              share.downloadCount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 3, bottom: 3),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (share.hasPassword)
                    _shareBadge(
                      context,
                      Icons.lock_outline_rounded,
                      '密码保护',
                      palette['brandSage'],
                    ),
                  if (share.maxDownloads > 0)
                    _shareBadge(
                      context,
                      Icons.pin_rounded,
                      '限 ${share.maxDownloads} 次',
                      palette['brandAmber'],
                    ),
                  if (share.downloadCount > 0)
                    _shareBadge(
                      context,
                      Icons.download_rounded,
                      '已下载 ${share.downloadCount} 次',
                      colors.primary,
                    ),
                ],
              ),
            ),
          Text(
            '到期：$expires',
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
        ],
      ),
      trailing: action,
    );
  }

  Widget _shareBadge(
    BuildContext context,
    IconData icon,
    String label,
    Color tone,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: isDark ? 0.22 : 0.11),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: tone),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: tone,
              fontSize: 11,
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
