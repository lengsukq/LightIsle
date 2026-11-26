import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'file_extras_api.dart';
import 'file_models.dart';

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
  bool _loadingForEdit = false;
  bool _saving = false;
  bool _dirty = false;
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
    if (_mtimeUnixNano != null && _mtimeUnixNano! > 0) {
      setState(() {
        _mode = _TextDialogMode.edit;
        _bannerMessage = null;
      });
      return;
    }
    setState(() {
      _loadingForEdit = true;
      _bannerMessage = null;
      _bannerError = false;
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
        _dirty = false;
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
      });
      return;
    }
    setState(() {
      _saving = true;
      _bannerMessage = null;
      _bannerError = false;
    });
    try {
      final extras = FileExtrasApi(api);
      if (refreshConflictFirst) {
        final latest = await extras.loadEditableText(widget.item.path);
        if (!mounted) return;
        setState(() {
          _mtimeUnixNano = latest.mtimeUnixNano;
          _conflictLatestContent = latest.content;
          _bannerMessage = '已刷新服务端最新版本供对照（下方可核对）。当前编辑草稿已保留，确认无误后可再次点击保存。';
          _bannerError = false;
        });
        return;
      }
      final outcome = await extras.saveEditableText(
        path: widget.item.path,
        content: draft,
        expectedMtimeUnixNano: _mtimeUnixNano,
      );
      if (!mounted) return;
      if (outcome.conflict) {
        setState(() {
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
        _dirty = false;
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
      child: ClipRRect(
        borderRadius: IsleRadius.brCard,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 840),
            decoration: BoxDecoration(
              color: colors.surface.withValues(alpha: isDark ? 0.92 : 0.97),
              borderRadius: IsleRadius.brCard,
              border: Border.all(color: borderColor, width: 1.0),
              boxShadow: IsleShadows.floating(isDark),
            ),
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
                  '${formatBytes(widget.item.size)} · ${_mode == _TextDialogMode.edit ? (_dirty ? '编辑中（未保存）' : '在线编辑') : 'QuickLook 快速查看'}',
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
                  ? const SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
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
    final isConflict = _bannerError && _bannerMessage!.contains('修改');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: (_bannerError ? colors.error : colors.primary).withValues(
          alpha: 0.1,
        ),
        borderRadius: BorderRadius.circular(10),
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
          if (isConflict)
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
      borderRadius: BorderRadius.circular(12),
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

/// Safe pure-Dart Markdown preview widget (never renders raw HTML or scripts).
class SafeMarkdownView extends StatelessWidget {
  const SafeMarkdownView({super.key, required this.markdown});

  final String markdown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final lines = markdown.replaceAll('\r\n', '\n').split('\n');
    final widgets = <Widget>[];
    var inCodeBlock = false;
    final codeBuffer = StringBuffer();

    void flushCodeBlock() {
      if (codeBuffer.isEmpty) return;
      widgets.add(
        Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            codeBuffer.toString().trimRight(),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12.2,
              height: 1.45,
            ),
          ),
        ),
      );
      codeBuffer.clear();
    }

    for (final rawLine in lines) {
      final trimmed = rawLine.trimRight();
      if (trimmed.startsWith('```')) {
        if (inCodeBlock) {
          flushCodeBlock();
          inCodeBlock = false;
        } else {
          inCodeBlock = true;
        }
        continue;
      }
      if (inCodeBlock) {
        codeBuffer.writeln(rawLine);
        continue;
      }
      if (trimmed.trim().isEmpty) {
        widgets.add(const SizedBox(height: 6));
        continue;
      }
      if (RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(trimmed.trim())) {
        widgets.add(const Divider(height: 18));
        continue;
      }
      final heading = RegExp(r'^(#{1,4})\s+(.*)$').firstMatch(trimmed);
      if (heading != null) {
        final level = heading.group(1)!.length;
        final size = switch (level) {
          1 => 20.0,
          2 => 17.5,
          3 => 15.5,
          _ => 14.0,
        };
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: SelectableText.rich(
              _parseInlineSpans(
                heading.group(2) ?? '',
                TextStyle(fontSize: size, fontWeight: FontWeight.w800, height: 1.35),
                colors,
              ),
            ),
          ),
        );
        continue;
      }
      if (trimmed.startsWith('> ')) {
        widgets.add(
          Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.fromLTRB(10, 4, 8, 4),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: colors.primary, width: 3),
              ),
            ),
            child: SelectableText.rich(
              _parseInlineSpans(
                trimmed.substring(2),
                TextStyle(
                  fontSize: 13.5,
                  color: colors.onSurfaceVariant,
                  height: 1.5,
                ),
                colors,
              ),
            ),
          ),
        );
        continue;
      }
      final taskMatch = RegExp(r'^[-*]\s+\[([ xX])\]\s+(.*)$').firstMatch(trimmed);
      if (taskMatch != null) {
        final done = taskMatch.group(1)!.toLowerCase() == 'x';
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  done ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                  size: 16,
                  color: done ? colors.primary : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: SelectableText.rich(
                    _parseInlineSpans(
                      taskMatch.group(2) ?? '',
                      TextStyle(
                        fontSize: 13.5,
                        height: 1.5,
                        decoration: done ? TextDecoration.lineThrough : null,
                      ),
                      colors,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        continue;
      }
      final bulletMatch = RegExp(r'^[-*+]\s+(.*)$').firstMatch(trimmed);
      if (bulletMatch != null) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 2, bottom: 2),
            child: SelectableText.rich(
              _parseInlineSpans(
                '• ${bulletMatch.group(1) ?? ''}',
                const TextStyle(fontSize: 13.5, height: 1.5),
                colors,
              ),
            ),
          ),
        );
        continue;
      }
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: SelectableText.rich(
            _parseInlineSpans(
              trimmed,
              const TextStyle(fontSize: 13.5, height: 1.55),
              colors,
            ),
          ),
        ),
      );
    }
    if (inCodeBlock) flushCodeBlock();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  TextSpan _parseInlineSpans(
    String text,
    TextStyle baseStyle,
    ColorScheme colors,
  ) {
    final spans = <InlineSpan>[];
    final tokenRegex = RegExp(
      r'(\*\*[^*]+\*\*|`[^`]+`|\*[^*]+\*|\[[^\]]+\]\([^)]+\))',
    );
    var cursor = 0;
    for (final match in tokenRegex.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      final token = match.group(0)!;
      if (token.startsWith('**') && token.endsWith('**')) {
        spans.add(
          TextSpan(
            text: token.substring(2, token.length - 2),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        );
      } else if (token.startsWith('`') && token.endsWith('`')) {
        spans.add(
          TextSpan(
            text: token.substring(1, token.length - 1),
            style: TextStyle(
              fontFamily: 'monospace',
              backgroundColor: colors.surfaceContainerHighest.withValues(
                alpha: 0.7,
              ),
            ),
          ),
        );
      } else if (token.startsWith('*') && token.endsWith('*')) {
        spans.add(
          TextSpan(
            text: token.substring(1, token.length - 1),
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        );
      } else if (token.startsWith('[')) {
        final close = token.indexOf('](');
        if (close > 1) {
          final label = token.substring(1, close);
          spans.add(
            TextSpan(
              text: label,
              style: TextStyle(
                color: colors.primary,
                decoration: TextDecoration.underline,
              ),
            ),
          );
        } else {
          spans.add(TextSpan(text: token));
        }
      }
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return TextSpan(style: baseStyle, children: spans);
  }
}
