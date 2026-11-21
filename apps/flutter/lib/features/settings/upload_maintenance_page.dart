import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';

class UploadMaintenancePage extends StatefulWidget {
  const UploadMaintenancePage({super.key, required this.api});
  final LightIsleApi api;
  @override
  State<UploadMaintenancePage> createState() => _UploadMaintenancePageState();
}

class _UploadMaintenancePageState extends State<UploadMaintenancePage> {
  List<Map<String, dynamic>> _items = [];
  String _cursor = '';
  String? _error, _message;
  bool _busy = false, _loaded = false;
  int _days = 30;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.api.get(
        '/api/v2/admin/uploads',
        query: {
          'limit': '20',
          if (more && _cursor.isNotEmpty) 'after': _cursor,
        },
      );
      if (mounted) {
        setState(() {
          _items = [
            ...(more ? _items : <Map<String, dynamic>>[]),
            ...objectList(r['uploads']),
          ];
          _cursor = r['nextCursor']?.toString() ?? '';
          _loaded = true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel(Map<String, dynamic> item) async {
    if (!await confirmAction(
      context,
      '取消上传',
      '将清理 ${item['path']} 的未完成上传，之后需要重新上传。',
      action: '取消并清理',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.send('DELETE', '/api/v2/admin/uploads/${item['id']}');
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _error == null) await _load();
  }

  Future<void> _cleanup() async {
    final days = _days;
    if (!await confirmAction(
      context,
      '清理过期上传',
      '清理至少 $days 天未活动的上传分片，清理后无法续传。不会删除已完成的原始文件。',
      action: '清理分片',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final r = await widget.api.send(
        'POST',
        '/api/v2/admin/uploads/cleanup-expired',
        body: {'inactiveForSeconds': days * 86400},
      );
      if (mounted) {
        setState(
          () => _message =
              '已清理 ${r['removed']} 项，跳过 ${r['skipped']} 项。${(r['pendingReservations'] as num? ?? 0) > 0 ? '${r['pendingReservations']} 项容量预占仍需在管理员任务中心检查。' : ''}${r['hasMore'] == true ? '仍有更多，可再次执行清理。' : ''}',
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _error == null) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    final abnormalCount = _items
        .where((i) => i['orphan'] == true || i['corrupt'] == true)
        .length;

    return Scaffold(
      appBar: IsleAppBar(
        title: const Text('上传维护'),
        actions: [
          IconButton(
            tooltip: '刷新上传',
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
          IsleHelpButton(
            title: '分片上传维护说明',
            accentColor: palette['brandCyan'],
            body:
                '此处仅列出尚未合并完成的断点续传临时分片。清理过期或异常分片会释放其占用的暂存空间与成员配额预占，绝不会删除任何已上传完成的正式文件。',
          ),
        ],
      ),
      body: IsleListView(
        maxWidth: IsleLayout.workbenchMaxWidth,
        children: [
          if (_message != null) Notice(_message!),
          if (_error != null) Notice(_error!, error: true, onRetry: _load),
          if (_busy)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: ClipRRect(
                borderRadius: IsleRadius.brPill,
                child: const LinearProgressIndicator(minHeight: 3),
              ),
            ),
          IsleFocalStage(
            icon: Icons.cleaning_services_rounded,
            accent: palette['brandCyan'],
            title: '分片上传维护',
            metrics: [
              IsleFocalMetric(
                label: '暂存会话',
                value: _loaded ? '${_items.length} 项' : '读取中',
                icon: Icons.cloud_upload_outlined,
                color: palette['brandCyan'],
              ),
              IsleFocalMetric(
                label: '异常分片',
                value: _loaded ? '$abnormalCount 项' : '—',
                icon: Icons.warning_amber_rounded,
                color: abnormalCount > 0
                    ? Theme.of(context).colorScheme.error
                    : palette['brandSage'],
              ),
            ],
            actions: [
              for (final d in const [7, 30, 90])
                ChoiceChip(
                  visualDensity: VisualDensity.compact,
                  label: Text('$d 天'),
                  selected: _days == d,
                  onSelected: _busy ? null : (_) => setState(() => _days = d),
                ),
              FilledButton.tonalIcon(
                onPressed: _busy ? null : _cleanup,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                label: const Text('清理过期上传'),
              ),
            ],
          ),
          if (_loaded && _items.isEmpty)
            const IsleEmptyStateCard(
              '没有待维护的上传。',
              icon: Icons.cloud_done_outlined,
            ),
          if (_items.isNotEmpty) ...[
            IsleSectionHeader(title: '活动中的分片会话（${_items.length}）'),
            IsleResponsiveGrid(
              minItemWidth: 310,
              maxColumns: 3,
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final item in _items) _buildUploadSessionCard(context, item),
              ],
            ),
          ],
          if (!_busy && _cursor.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: FilledButton.tonalIcon(
                  onPressed: () => _load(more: true),
                  icon: const Icon(Icons.expand_more_rounded, size: 18),
                  label: const Text('加载更多'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildUploadSessionCard(
    BuildContext context,
    Map<String, dynamic> item,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final offset = (item['offset'] as num?)?.toDouble() ?? 0;
    final size = (item['size'] as num?)?.toDouble() ?? 0;
    final fraction = size > 0 ? (offset / size).clamp(0.0, 1.0) : 0.0;
    final abnormal = item['orphan'] == true || item['corrupt'] == true;
    final accent = abnormal ? colors.error : palette['brandCyan'];

    return IsleSurface(
      radius: IsleRadius.card,
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IsleSquircleBadge(
                icon: abnormal
                    ? Icons.warning_amber_rounded
                    : Icons.cloud_upload_outlined,
                color: accent,
                size: 34,
                iconSize: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item['path']?.toString() ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '账号：${item['ownerName'] ?? '已删除'}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IsleStatusBadge(
                label: abnormal ? '分片异常' : '断点暂存',
                color: accent,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: IsleDecorations.recessedWell(
              context,
              radius: IsleRadius.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: fraction,
                    minHeight: 5,
                    color: accent,
                    backgroundColor: accent.withValues(alpha: 0.14),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${formatBytes(item['offset'] as num?)} / ${formatBytes(item['size'] as num?)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(
                      '${(fraction * 100).round()}%',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: accent,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _busy ? null : () => _cancel(item),
              style: TextButton.styleFrom(
                foregroundColor: colors.error,
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('取消并清理'),
            ),
          ),
        ],
      ),
    );
  }
}
