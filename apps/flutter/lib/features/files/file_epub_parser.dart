/// Pure-Dart safe XHTML/HTML block extractor and OPF spine resolver for
/// lightweight EPUB reading without any WebView or third-party HTML engine.
class EpubChapterContent {
  const EpubChapterContent({required this.title, required this.blocks});

  final String title;
  final List<EpubTextBlock> blocks;
}

class EpubTextBlock {
  const EpubTextBlock({required this.text, this.isHeading = false});

  final String text;
  final bool isHeading;
}

/// Strips script/style/head/svg/noscript blocks and decodes HTML entities into
/// safe plain-text heading and paragraph blocks.
EpubChapterContent parseSafeEpubDocument(
  String rawHtml, {
  String fallbackTitle = '',
}) {
  final cleaned = rawHtml
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
      .replaceAll(
        RegExp(
          r'<(script|style|head|svg|noscript)\b[^>]*>[\s\S]*?</\1>',
          caseSensitive: false,
        ),
        '',
      );

  final titleMatch = RegExp(
    r'<title\b[^>]*>([\s\S]*?)</title>',
    caseSensitive: false,
  ).firstMatch(rawHtml);
  final extractedTitle = titleMatch != null
      ? _cleanInlineText(titleMatch.group(1) ?? '')
      : '';

  final blocks = <EpubTextBlock>[];
  final blockRegex = RegExp(
    r'<(h[1-6]|p|li|blockquote|div|pre)\b[^>]*>([\s\S]*?)</\1>',
    caseSensitive: false,
  );
  final matches = blockRegex.allMatches(cleaned).toList();
  if (matches.isEmpty) {
    final plain = _cleanInlineText(cleaned);
    if (plain.isNotEmpty) {
      for (final line in plain.split(RegExp(r'\n{2,}'))) {
        final t = line.trim();
        if (t.isNotEmpty) blocks.add(EpubTextBlock(text: t));
      }
    }
  } else {
    for (final m in matches) {
      final tag = (m.group(1) ?? '').toLowerCase();
      final inner = m.group(2) ?? '';
      if (tag == 'div' &&
          RegExp(
            r'<(p|h[1-6]|div|blockquote|li)\b',
            caseSensitive: false,
          ).hasMatch(inner)) {
        continue;
      }
      final text = _cleanInlineText(inner);
      if (text.isEmpty) continue;
      final isHeading = tag.startsWith('h');
      final formatted = tag == 'li' ? '• $text' : text;
      blocks.add(EpubTextBlock(text: formatted, isHeading: isHeading));
    }
  }

  final title = extractedTitle.isNotEmpty
      ? extractedTitle
      : (blocks.isNotEmpty && blocks.first.isHeading
            ? blocks.first.text
            : fallbackTitle);
  return EpubChapterContent(title: title, blocks: blocks);
}

String _cleanInlineText(String fragment) {
  final withBreaks = fragment
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '');
  final decoded = _decodeHtmlEntities(withBreaks);
  return decoded
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[ \t\r]+'), ' ').trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
}

String _decodeHtmlEntities(String input) {
  const named = <String, String>{
    '&nbsp;': ' ',
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'",
    '&apos;': "'",
    '&mdash;': '—',
    '&ndash;': '–',
    '&hellip;': '…',
  };
  var out = input;
  named.forEach((k, v) => out = out.replaceAll(k, v));
  out = out.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
    final c = int.tryParse(m.group(1) ?? '', radix: 16);
    return c != null && c > 0 && c <= 0x10FFFF
        ? String.fromCharCode(c)
        : m.group(0)!;
  });
  return out.replaceAllMapped(RegExp(r'&#([0-9]+);'), (m) {
    final c = int.tryParse(m.group(1) ?? '');
    return c != null && c > 0 && c <= 0x10FFFF
        ? String.fromCharCode(c)
        : m.group(0)!;
  });
}

/// Parses an EPUB OPF manifest + spine XML to determine reading chapter order.
List<String> parseEpubOpfSpine(String opfXml, String opfEntryPath) {
  final slash = opfEntryPath.lastIndexOf('/');
  final baseDir = slash < 0 ? '' : opfEntryPath.substring(0, slash + 1);

  final idToHref = <String, String>{};
  for (final m in RegExp(
    r'<item\b([^>]+)/?>',
    caseSensitive: false,
  ).allMatches(opfXml)) {
    final attrs = m.group(1) ?? '';
    final id = _xmlAttr(attrs, 'id');
    final href = _xmlAttr(attrs, 'href');
    if (id != null && href != null) {
      idToHref[id] = _joinZipPath(baseDir, Uri.decodeComponent(href));
    }
  }
  final ordered = <String>[];
  for (final m in RegExp(
    r'<itemref\b([^>]+)/?>',
    caseSensitive: false,
  ).allMatches(opfXml)) {
    final idref = _xmlAttr(m.group(1) ?? '', 'idref');
    final target = idref != null ? idToHref[idref] : null;
    if (target != null && !ordered.contains(target)) {
      ordered.add(target);
    }
  }
  return ordered;
}

String? _xmlAttr(String attrs, String name) {
  final match = RegExp(
    '\\b$name\\s*=\\s*["\']([^"\']+)["\']',
    caseSensitive: false,
  ).firstMatch(attrs);
  return match?.group(1);
}

String _joinZipPath(String baseDir, String relative) {
  final combined = '$baseDir$relative'.replaceAll('\\', '/');
  final stack = <String>[];
  for (final part in combined.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (stack.isNotEmpty) stack.removeLast();
    } else {
      stack.add(part);
    }
  }
  return stack.join('/');
}
