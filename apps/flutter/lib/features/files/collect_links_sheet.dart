import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'file_extras_api.dart';

Future<void> showCollectLinksSheet(
  BuildContext context, {
  required LightIsleApi api,
  required String targetPath,
  required String folderName,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.transparent,
  builder: (_) => FractionallySizedBox(
    heightFactor: 0.88,
    child: CollectLinksSheet(
      api: api,
      targetPath: targetPath,
      folderName: folderName,
    ),
  ),
);

/// Write-only file collection link creator and manager ("亲友投递箱").
class CollectLinksSheet extends StatefulWidget {
  const CollectLinksSheet({
    super.key,
    required this.api,
    required this.targetPath,
    required this.folderName,
  });

  final LightIsleApi api;
  final String targetPath;
  final String folderName;

  @override
  State<CollectLinksSheet> createState() => _CollectLinksSheetState();
}

class _CollectLinksSheetState extends State<CollectLinksSheet> {
  static const _hourOptions = <int>[6, 24, 72, 168, 336, 720];

  late final FileExtrasApi _extrasApi = FileExtrasApi(widget.api);
  late final TextEditingController _titleController = TextEditingController(
    text: '${widget.folderName} · 亲友投递箱',
  );
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _maxFilesController = TextEditingController();
  final TextEditingController _maxFileMbController = TextEditingController();
  final TextEditingController _maxTotalGbController = TextEditingController();
  final TextEditingController _extsController = TextEditingController();

  int _hours = 72;
  bool _loading = true;
  bool _creating = false;
  bool _showAllFolders = false;
  String? _revokingId;
  String? _error;
  String? _notice;
  CreatedCollectLink? _created;
  List<CollectLinkEntry> _links = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadLinks());
  }

  @override
  void dispose() {
    _titleController.dispose();
    _passwordController.dispose();
    _maxFilesController.dispose();
    _maxFileMbController.dispose();
    _maxTotalGbController.dispose();
    _extsController.dispose();
    super.dispose();
  }

  Future<void> _loadLinks() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final links = await _extrasApi.listCollectLinks();
      if (!mounted) return;
      setState(() {
        _links = links;
        _loading = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = '读取收集链接失败：${userFacingError(err)}';
        _loading = false;
      });
    }
  }

  List<String> _parseAllowedExts() {
    final raw = _extsController.text.trim();
    if (raw.isEmpty) return const [];
    return raw
        .split(RegExp(r'[,，\s]+'))
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .map((e) => e.startsWith('.') ? e : '.$e')
        .toList();
  }

  Future<void> _createLink() async {
    if (_creating) return;
    final password = _passwordController.text;
    if (password.isNotEmpty && (password.length < 4 || password.length > 128)) {
      setState(() => _error = '投递口令需为 4–128 位，或留空。');
      return;
    }
    final maxFiles = _maxFilesController.text.trim().isEmpty
        ? 0
        : int.tryParse(_maxFilesController.text.trim());
    if (maxFiles == null || maxFiles < 0 || maxFiles > 10000) {
      setState(() => _error = '最大文件数需为 1–10000 之间的整数，或留空。');
      return;
    }
    final maxFileMb = _maxFileMbController.text.trim().isEmpty
        ? 0.0
        : double.tryParse(_maxFileMbController.text.trim());
    if (maxFileMb == null || !maxFileMb.isFinite || maxFileMb < 0) {
      setState(() => _error = '单文件上限请输入有效数字（MiB），或留空。');
      return;
    }
    final maxTotalGb = _maxTotalGbController.text.trim().isEmpty
        ? 0.0
        : double.tryParse(_maxTotalGbController.text.trim());
    if (maxTotalGb == null || !maxTotalGb.isFinite || maxTotalGb < 0) {
      setState(() => _error = '总容量上限请输入有效数字（GiB），或留空。');
      return;
    }

    setState(() {
      _creating = true;
      _error = null;
      _notice = null;
    });
    try {
      final created = await _extrasApi.createCollectLink(
        path: widget.targetPath,
        hours: _hours,
        title: _titleController.text.trim(),
        password: password,
        maxFiles: maxFiles,
        maxFileBytes: (maxFileMb * 1024 * 1024).round(),
        maxTotalBytes: (maxTotalGb * 1024 * 1024 * 1024).round(),
        allowedExts: _parseAllowedExts(),
      );
      if (!mounted) return;
      setState(() {
        _created = created;
        _passwordController.clear();
        _notice = '收集链接已创建（仅此时展示一次完整投递地址，请尽快复制）。';
      });
      await _loadLinks();
    } catch (err) {
      if (!mounted) return;
      setState(() => _error = '创建收集链接失败：${userFacingError(err)}');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _copyUrl(String url, String label) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    setState(() => _notice = '已复制$label。');
  }

  Future<void> _revoke(CollectLinkEntry link) async {
    if (_revokingId != null) return;
    final confirmed = await confirmAction(
      context,
      '撤销收集链接',
      '撤销“${link.title.isEmpty ? link.targetPath : link.title}”后，外链将立即失效；已投递到文件夹的文件会保留。',
      action: '确认撤销',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _revokingId = link.id;
      _error = null;
    });
    try {
      await _extrasApi.revokeCollectLink(link.id);
      if (!mounted) return;
      setState(() {
        if (_created?.link.id == link.id) _created = null;
        _notice = '收集链接已撤销。';
      });
      await _loadLinks();
    } catch (err) {
      if (!mounted) return;
      setState(() => _error = '撤销失败：${userFacingError(err)}');
    } finally {
      if (mounted) setState(() => _revokingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final palette = IslePalette(isDark);
    final borderColor = IsleGlass.rimBorderColor(isDark);
    final visibleLinks = _showAllFolders
        ? _links
        : _links.where((l) => l.targetPath == widget.targetPath).toList();

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 10, 8),
            child: Row(
              children: [
                IsleSquircleBadge(
                  icon: Icons.move_to_inbox_rounded,
                  color: palette['brandAmber'],
                  size: 36,
                  iconSize: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '文件收集链接（亲友投递箱）',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        '目标目录：${widget.targetPath} · 仅可上传，无法查看目录内已有文件',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: borderColor),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
              children: [
                if (_error != null) ...[
                  Notice(_error!, error: true),
                  const SizedBox(height: 8),
                ],
                if (_notice != null) ...[
                  Notice(_notice!),
                  const SizedBox(height: 8),
                ],
                if (_created != null) ...[
                  _buildCreatedCard(context, _created!, palette),
                  const SizedBox(height: 12),
                ],
                _buildCreateCard(context, palette),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _showAllFolders
                            ? '当前存储全部收集链接（${visibleLinks.length}）'
                            : '当前文件夹收集链接（${visibleLinks.length}）',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () =>
                          setState(() => _showAllFolders = !_showAllFolders),
                      child: Text(_showAllFolders ? '仅看当前目录' : '查看全部目录'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                if (_loading)
                  const LinearProgressIndicator(minHeight: 2)
                else if (visibleLinks.isEmpty)
                  const IsleEmptyStateCard(
                    '还没有为该目录创建收集链接。创建后亲友无需登录即可投递照片或文件。',
                    icon: Icons.inbox_outlined,
                  )
                else
                  for (final link in visibleLinks) ...[
                    _buildLinkRow(context, link, palette),
                    const SizedBox(height: 8),
                  ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCreatedCard(
    BuildContext context,
    CreatedCollectLink created,
    IslePalette palette,
  ) {
    final sage = palette['brandSage'];
    return IsleSurface(
      margin: EdgeInsets.zero,
      tint: sage,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle_outline_rounded, color: sage, size: 18),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  '新收集链接已就绪（关闭后令牌不再显示）',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            created.primaryUrl,
            key: const ValueKey('collectLinkPrimaryUrl'),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              FilledButton.icon(
                key: const ValueKey('copyCollectLinkPrimaryBtn'),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => _copyUrl(created.primaryUrl, '投递链接'),
                icon: const Icon(Icons.copy_rounded, size: 15),
                label: const Text('复制投递链接'),
              ),
              if (created.alternateUrl != null)
                OutlinedButton.icon(
                  key: const ValueKey('copyCollectLinkAltBtn'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () =>
                      _copyUrl(created.alternateUrl!, '公网/远程投递链接'),
                  icon: const Icon(Icons.public_rounded, size: 15),
                  label: const Text('复制远程/公网链接'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCreateCard(BuildContext context, IslePalette palette) {
    return IsleSurface(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '创建新投递链接',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('collectTitleField'),
            controller: _titleController,
            enabled: !_creating,
            decoration: const InputDecoration(
              isDense: true,
              labelText: '投递页标题',
              hintText: '例如：春节家庭合影收集',
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: _hours,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '有效期',
                  ),
                  items: [
                    for (final h in _hourOptions)
                      DropdownMenuItem(value: h, child: Text(_hourLabel(h))),
                  ],
                  onChanged: _creating
                      ? null
                      : (v) {
                          if (v != null) setState(() => _hours = v);
                        },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _passwordController,
                  enabled: !_creating,
                  obscureText: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '投递口令（选填）',
                    hintText: '留空无需口令',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _maxFilesController,
                  enabled: !_creating,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '最多文件数',
                    hintText: '不限',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _maxFileMbController,
                  enabled: !_creating,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '单文件上限(MiB)',
                    hintText: '默认',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _maxTotalGbController,
                  enabled: !_creating,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '总上限(GiB)',
                    hintText: '默认',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _extsController,
            enabled: !_creating,
            decoration: const InputDecoration(
              isDense: true,
              labelText: '允许后缀（选填，逗号分隔）',
              hintText: '如：.jpg, .png, .mp4（留空不限）',
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              key: const ValueKey('createCollectLinkBtn'),
              onPressed: _creating ? null : _createLink,
              icon: _creating
                  ? const SizedBox.square(
                      dimension: 15,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.add_link_rounded, size: 17),
              label: Text(_creating ? '正在生成…' : '生成收集链接'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLinkRow(
    BuildContext context,
    CollectLinkEntry link,
    IslePalette palette,
  ) {
    final colors = Theme.of(context).colorScheme;
    final countText = link.maxFiles > 0
        ? '${link.uploadedFiles}/${link.maxFiles} 个文件'
        : '${link.uploadedFiles} 个文件';
    final sizeText = link.maxTotalBytes > 0
        ? '${formatBytes(link.uploadedBytes)} / ${formatBytes(link.maxTotalBytes)}'
        : formatBytes(link.uploadedBytes);
    final exp = link.expiresAtTime;
    final expText = exp == null ? '—' : formatDateTime(exp.toLocal());

    return IsleSurface(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  link.title.isEmpty ? link.targetPath : link.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                  ),
                ),
              ),
              if (link.hasPassword) ...[
                IsleBadgePill(
                  label: '需口令',
                  color: palette['brandBlue'],
                ),
                const SizedBox(width: 6),
              ],
              IsleBadgePill(
                label: link.isExpired ? '已过期' : '收集中',
                color: link.isExpired ? colors.error : palette['brandSage'],
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '目录：${link.targetPath} · 已收 $countText（$sizeText）',
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 2),
          Text(
            '有效期至：$expText',
            style: TextStyle(fontSize: 11.5, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              key: ValueKey('revoke-collect-${link.id}'),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: colors.error,
              ),
              onPressed: _revokingId != null ? null : () => _revoke(link),
              icon: const Icon(Icons.link_off_rounded, size: 15),
              label: Text(_revokingId == link.id ? '撤销中…' : '撤销链接'),
            ),
          ),
        ],
      ),
    );
  }

  static String _hourLabel(int hours) => switch (hours) {
    6 => '6 小时',
    24 => '1 天',
    72 => '3 天',
    168 => '7 天',
    336 => '14 天',
    720 => '30 天',
    _ => '$hours 小时',
  };
}
