import 'package:flutter/material.dart';

import '../../core/isle_style.dart';

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
            borderRadius: BorderRadius.circular(IsleRadius.badge),
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
                TextStyle(
                  fontSize: size,
                  fontWeight: FontWeight.w800,
                  height: 1.35,
                ),
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
      final taskMatch = RegExp(
        r'^[-*]\s+\[([ xX])\]\s+(.*)$',
      ).firstMatch(trimmed);
      if (taskMatch != null) {
        final done = taskMatch.group(1)!.toLowerCase() == 'x';
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  done
                      ? Icons.check_box_rounded
                      : Icons.check_box_outline_blank_rounded,
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
