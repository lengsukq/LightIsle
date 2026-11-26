import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'file_extras_api.dart';
import 'file_models.dart';
import 'file_safe_markdown_view.dart';

export 'file_safe_markdown_view.dart';

enum _TextDialogMode { preview, source, edit }

/// QuickLook text & Markdown preview dialog with optional online editing
/// backed by `GET/PUT /api/v2/roots/{rootID}/files/text` and optimistic
/// concurrency conflict detection (`expectedMtimeUnixNano`).
class FileTextPreviewDialog extends StatefulWidget {
  const FileTextPreviewDialog({
    super.key,
    required this.item,
    required this.badge,
    required this.onOpenExternal,
    required this.onDownload,
    this.text,
    this.error,
    this.api,
    this.canEdit = false,
    this.initialMtimeUnixNano,
    this.onSaved,
  }) : assert(text != null || error != null);

  final FileEntry item;
  final Widget badge;
  final String? text;
  final String? error;
  final VoidCallback onOpenExternal;
  final VoidCallback onDownload;
  final LightIsleApi? api;
  final bool canEdit;
  final int? initialMtimeUnixNano;
  final VoidCallback? onSaved;

  @override
  State<FileTextPreviewDialog> createState() => _FileTextPreviewDialogState();
}

class _FileTextPreviewDialogState extends State<FileTextPreviewDialog> {
  static const int _maxEditableBytes = 2 * 1024 * 1024;

  late final bool _isMarkdown = isMarkdownFile(widget.item.name);
  late final bool _editableType = isEditableTextFile(widget.item.name);
  late _TextDialogMode _mode = _isMarkdown
      ? _TextDialogMode.preview
      : _TextDialogMode.source;

  late String _content = widget.text ?? '';
  late final TextEditingController _editor = TextEditingController(
    text: widget.text ?? '',
  );

  int? _mtimeUnixNano;
  String _mtimeToken = '';
  late int _currentSizeBytes = widget.item.size;
  bool _loadingForEdit = false;
  bool _saving = false;
  bool _dirty = false;
  bool _hasConflict = false;
  String? _bannerMessage;
  bool _bannerError = false;
  String? _conflictLatestContent;

  bool get _canEnterEdit =>
      widget.error == null &&
      widget.api != null &&
      widget.canEdit &&
      _editableType;

  @override
  void initState() {
    super.initState();
    _mtimeUnixNano = widget.initialMtimeUnixNano;
  }

  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  Future<void> _enterEditMode() async {
    if (!_canEnterEdit || _loadingForEdit) return;
    if ((_mtimeToken.isNotEmpty) ||
        (_mtimeUnixNano != null && _mtimeUnixNano! > 0)) {
      setState(() {
        _mode = _TextDialogMode.edit;
        _bannerMessage = null;
        _hasConflict = false;
      });
      return;
    }
    setState(() {
      _loadingForEdit = true;
      _bannerMessage = null;
      _bannerError = false;
      _hasConflict = false;
    });
    try {
      final doc = await FileExtrasApi(
        widget.api!,
      ).loadEditableText(widget.item.path);
      if (!mounted) return;
      if (!doc.canWrite) {
        setState(() {
          _loadingForEdit = false;
          _bannerMessage = '当前账号对该文件仅有只读权限，无法在线编辑。';
          _bannerError = true;
        });
        return;
      }
      setState(() {
        _content = doc.content;
        _editor.text = doc.content;
        _mtimeUnixNano = doc.mtimeUnixNano;
        _mtimeToken = doc.mtimeToken;
        _currentSizeBytes = doc.size;
        _dirty = false;
        _hasConflict = false;
        _mode = _TextDialogMode.edit;
        _loadingForEdit = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _loadingForEdit = false;
        _bannerMessage = '载入编辑内容失败：${userFacingError(err)}';
        _bannerError = true;
      });
    }
  }

  Future<void> _save({bool refreshConflictFirst = false}) async {
    final api = widget.api;
    if (api == null || _saving) return;
    final draft = _editor.text;
    if (utf8.encode(draft).length > _maxEditableBytes) {
      setState(() {
        _bannerMessage = '文本内容超过 2 MiB 在线保存上限，请精简后再保存。';
        _bannerError = true;
        _hasConflict = false;
      });
      return;
    }
    setState(() {
      _saving = true;
      _bannerMessage = null;
      _bannerError = false;
      if (!refreshConflictFirst) _hasConflict = false;
    });
    try {
      final extras = FileExtrasApi(api);
      if (refreshConflictFirst) {
        final latest = await extras.loadEditableText(widget.item.path);
        if (!mounted) return;
        setState(() {
          _mtimeUnixNano = latest.mtimeUnixNano;
          _mtimeToken = latest.mtimeToken;
          _currentSizeBytes = latest.size;
          _conflictLatestContent = latest.content;
          _hasConflict = false;
          _bannerMessage = '已刷新服务端最新版本供对照（下方可核对）。当前编辑草稿已保留，确认无误后可再次点击保存。';
          _bannerError = false;
        });
        return;
      }
      final outcome = await extras.saveEditableText(
        path: widget.item.path,
        content: draft,
        expectedMtimeUnixNano: _mtimeUnixNano,
        expectedMtimeToken: _mtimeToken.isNotEmpty ? _mtimeToken : null,
      );
      if (!mounted) return;
      if (outcome.conflict) {
        setState(() {
          _hasConflict = true;
          _bannerMessage =
              outcome.conflictMessage ??
              '文件已被其他设备修改，本次保存已中止，您的草稿仍保留在编辑框中。';
          _bannerError = true;
        });
        return;
      }
      setState(() {
        _content = draft;
        _mtimeUnixNano = outcome.mtimeUnixNano > 0
            ? outcome.mtimeUnixNano
            : _mtimeUnixNano;
        if (outcome.mtimeToken.isNotEmpty) {
          _mtimeToken = outcome.mtimeToken;
        }
        _currentSizeBytes = outcome.size;
        _dirty = false;
        _hasConflict = false;
        _conflictLatestContent = null;
        _bannerMessage = '已安全保存到 NAS（${formatBytes(outcome.size)}）。';
        _bannerError = false;
      });
      widget.onSaved?.call();
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _bannerMessage = '保存失败：${userFacingError(err)}';
        _bannerError = true;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = IsleGlass.rimBorderColor(isDark);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: IsleShapes.card(side: BorderSide(color: borderColor)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: IsleSurface(
          margin: EdgeInsets.zero,
          padding: EdgeInsets.zero,
          radius: IsleRadius.card,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context, theme, colors),
              Divider(height: 1, thickness: 1, color: borderColor),
              if (widget.error == null && (_isMarkdown || _canEnterEdit))
                _buildModeToolbar(context, colors, borderColor),
              if (_bannerMessage != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                  child: _buildBanner(context, colors),
                ),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: _buildBody(context, theme, colors, isDark, borderColor),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    ThemeData theme,
    ColorScheme colors,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          widget.badge,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 1.5),
                Text(
                  '${formatBytes(_currentSizeBytes)} · ${_mode == _TextDialogMode.edit ? (_dirty ? '编辑中（未保存）' : '在线编辑') : 'QuickLook 快速查看'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 11.5,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '其他应用打开',
            onPressed: () {
              Navigator.pop(context);
              widget.onOpenExternal();
            },
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '下载文件',
            onPressed: () {
              Navigator.pop(context);
              widget.onDownload();
            },
            icon: const Icon(Icons.download_rounded, size: 18),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '关闭',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded, size: 19),
          ),
        ],
      ),
    );
  }

  Widget _buildModeToolbar(
    BuildContext context,
    ColorScheme colors,
    Color borderColor,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 6,
        children: [
          Wrap(
            spacing: 6,
            children: [
              if (_isMarkdown)
                ChoiceChip(
                  key: const ValueKey('textDialogPreviewModeChip'),
                  visualDensity: VisualDensity.compact,
                  label: const Text('Markdown 预览', style: TextStyle(fontSize: 12)),
                  selected: _mode == _TextDialogMode.preview,
                  onSelected: (_) => setState(() {
                    if (_mode == _TextDialogMode.edit) _content = _editor.text;
                    _mode = _TextDialogMode.preview;
                  }),
                ),
              ChoiceChip(
                key: const ValueKey('textDialogSourceModeChip'),
                visualDensity: VisualDensity.compact,
                label: const Text('源码', style: TextStyle(fontSize: 12)),
                selected: _mode == _TextDialogMode.source,
                onSelected: (_) => setState(() {
                  if (_mode == _TextDialogMode.edit) _content = _editor.text;
                  _mode = _TextDialogMode.source;
                }),
              ),
              if (_canEnterEdit)
                ChoiceChip(
                  key: const ValueKey('textDialogEditModeChip'),
                  visualDensity: VisualDensity.compact,
                  avatar: _loadingForEdit
                      ? const SizedBox.square(
                          dimension: 12,
                          child: CircularProgressIndicator(strokeWidth: 1.8),
                        )
                      : const Icon(Icons.edit_outlined, size: 14),
                  label: const Text('在线编辑', style: TextStyle(fontSize: 12)),
                  selected: _mode == _TextDialogMode.edit,
                  onSelected: _loadingForEdit
                      ? null
                      : (_) => unawaited(_enterEditMode()),
                ),
            ],
          ),
          if (_mode == _TextDialogMode.edit)
            FilledButton.icon(
              key: const ValueKey('textDialogSaveBtn'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              onPressed: _saving ? null : () => unawaited(_save()),
              icon: _saving
                  ? SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.onPrimary,
                      ),
                    )
                  : const Icon(Icons.save_outlined, size: 16),
              label: Text(_saving ? '保存中…' : '保存'),
            ),
        ],
      ),
    );
  }

  Widget _buildBanner(BuildContext context, ColorScheme colors) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: (_bannerError ? colors.error : colors.primary).withValues(
          alpha: 0.1,
        ),
        borderRadius: BorderRadius.circular(IsleRadius.badge),
        border: Border.all(
          color: (_bannerError ? colors.error : colors.primary).withValues(
            alpha: 0.35,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _bannerMessage!,
              style: TextStyle(
                fontSize: 12.2,
                color: _bannerError ? colors.error : colors.onSurface,
              ),
            ),
          ),
          if (_hasConflict)
            TextButton(
              key: const ValueKey('textDialogRefreshLatestBtn'),
              onPressed: _saving
                  ? null
                  : () => unawaited(_save(refreshConflictFirst: true)),
              child: const Text('查看最新版本'),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    ThemeData theme,
    ColorScheme colors,
    bool isDark,
    Color borderColor,
  ) {
    if (widget.error != null) {
      return Padding(
        padding: const EdgeInsets.all(18),
        child: Text(
          '无法预览：${widget.error}',
          style: TextStyle(fontSize: 13, color: colors.error),
        ),
      );
    }

    final boxDecoration = BoxDecoration(
      color: isDark
          ? Colors.black.withValues(alpha: 0.36)
          : colors.surfaceContainerHighest.withValues(alpha: 0.42),
      borderRadius: BorderRadius.circular(IsleRadius.input),
      border: Border.all(color: borderColor, width: 1.0),
    );

    if (_mode == _TextDialogMode.edit) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: Container(
                decoration: boxDecoration,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: TextField(
                  key: const ValueKey('textDialogEditorField'),
                  controller: _editor,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 13,
                    fontFamily: 'monospace',
                    height: 1.5,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isCollapsed: true,
                  ),
                  onChanged: (_) {
                    if (!_dirty) setState(() => _dirty = true);
                  },
                ),
              ),
            ),
            if (_conflictLatestContent != null) ...[
              const SizedBox(height: 8),
              Text(
                '服务端最新版本参考（只读）：',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                constraints: const BoxConstraints(maxHeight: 130),
                decoration: boxDecoration,
                padding: const EdgeInsets.all(10),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _conflictLatestContent!,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    }

    if (_mode == _TextDialogMode.preview && _isMarkdown) {
      return Container(
        constraints: const BoxConstraints(maxHeight: 520),
        decoration: boxDecoration,
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: SafeMarkdownView(markdown: _content),
        ),
      );
    }

    return Container(
      constraints: const BoxConstraints(maxHeight: 520),
      decoration: boxDecoration,
      padding: const EdgeInsets.all(14),
      child: SingleChildScrollView(
        child: SelectableText(
          _content,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontSize: 13,
            fontFamily: 'monospace',
            height: 1.5,
          ),
        ),
      ),
    );
  }
}
