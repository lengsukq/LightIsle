import 'desktop_backup_models.dart';

/// Built-in ignore preset metadata for folder backup tasks.
class DesktopBackupIgnorePreset {
  const DesktopBackupIgnorePreset({
    required this.id,
    required this.label,
    required this.description,
    required this.patterns,
  });

  final String id;
  final String label;
  final String description;
  final List<String> patterns;
}

const DesktopBackupIgnorePreset kDevIgnorePreset = DesktopBackupIgnorePreset(
  id: 'dev',
  label: '开发与构建目录',
  description: 'node_modules、.git、target、build、.venv、__pycache__',
  patterns: <String>[
    'node_modules',
    '.git',
    'target',
    'build',
    '.venv',
    '__pycache__',
  ],
);

const DesktopBackupIgnorePreset kTempIgnorePreset = DesktopBackupIgnorePreset(
  id: 'temp',
  label: '临时与缓存文件',
  description: '*.tmp、~\$*、*.part、.DS_Store、Thumbs.db',
  patterns: <String>['*.tmp', '~\$*', '*.part', '.DS_Store', 'Thumbs.db'],
);

const List<DesktopBackupIgnorePreset> kDesktopBackupIgnorePresets =
    <DesktopBackupIgnorePreset>[kDevIgnorePreset, kTempIgnorePreset];

const Set<String> kDesktopBackupSystemJunkNames = <String>{
  '.DS_Store',
  'Thumbs.db',
  'desktop.ini',
  '.Spotlight-V100',
  '.Trashes',
  '.fseventsd',
  '.TemporaryItems',
  'Icon\r',
};

const int kBytesPerMiB = 1024 * 1024;

final RegExp _lightIsleBackupSuffixPattern = RegExp(
  r'\.lightisle-bak(?:\.\d+)?$',
);
final RegExp _lightIsleRestorePartPattern = RegExp(
  r'\.lightisle-restore-[^/\\]+\.part$',
);

/// Returns true if a file or directory segment is an internal LightIsle
/// artifact (`.lightisle-*`, restore `.lightisle-bak[.N]`, or `.lightisle-restore-*.part`).
bool isLightIsleInternalArtifactName(String name) =>
    name.startsWith('.lightisle-') ||
    _lightIsleBackupSuffixPattern.hasMatch(name) ||
    _lightIsleRestorePartPattern.hasMatch(name);

DesktopBackupIgnorePreset? findIgnorePreset(String id) {
  for (final preset in kDesktopBackupIgnorePresets) {
    if (preset.id == id) return preset;
  }
  return null;
}

/// Parses multiline user input into normalized non-empty glob patterns.
List<String> parseCustomIgnoreText(String raw) {
  final out = <String>[];
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    out.add(trimmed);
  }
  return List<String>.unmodifiable(out);
}

String formatCustomIgnoreText(List<String> patterns) => patterns.join('\n');

/// Pure-Dart zero-dependency glob matcher for local & Android folder backups.
class DesktopBackupIgnoreMatcher {
  DesktopBackupIgnoreMatcher({
    this.ignoreHidden = true,
    List<String> ignorePresets = const <String>[],
    List<String> customIgnorePatterns = const <String>[],
    this.maxFileSizeMiB = 0,
  }) : _effectivePatterns = _expandPatterns(
         ignorePresets,
         customIgnorePatterns,
       ) {
    _rules = _effectivePatterns
        .map(_CompiledIgnoreRule.tryParse)
        .whereType<_CompiledIgnoreRule>()
        .toList(growable: false);
  }

  factory DesktopBackupIgnoreMatcher.fromTask(DesktopBackupTask task) =>
      DesktopBackupIgnoreMatcher(
        ignoreHidden: task.ignoreHidden,
        ignorePresets: task.ignorePresets,
        customIgnorePatterns: task.customIgnorePatterns,
        maxFileSizeMiB: task.maxFileSizeMiB,
      );

  final bool ignoreHidden;
  final int maxFileSizeMiB;
  final List<String> _effectivePatterns;
  late final List<_CompiledIgnoreRule> _rules;

  /// All expanded glob patterns (selected presets + custom lines) for native
  /// scanners such as Android SAF.
  List<String> get effectivePatterns => _effectivePatterns;

  int get maxFileSizeBytes =>
      maxFileSizeMiB > 0 ? maxFileSizeMiB * kBytesPerMiB : 0;

  bool exceedsSizeLimit(int sizeBytes) =>
      maxFileSizeBytes > 0 && sizeBytes > maxFileSizeBytes;

  /// Returns true if a single path segment is reserved or always-ignored junk.
  bool shouldSkipSegmentName(String name) {
    if (name.isEmpty || name == '.' || name == '..') return true;
    if (kDesktopBackupSystemJunkNames.contains(name)) return true;
    if (isLightIsleInternalArtifactName(name)) return true;
    if (ignoreHidden && name.startsWith('.')) return true;
    return false;
  }

  /// Returns true if [relativePath] (POSIX `/`-separated, no leading slash)
  /// should be skipped based on built-in rules, hidden-file setting, presets,
  /// and custom glob patterns.
  bool shouldIgnore(String relativePath, {required bool isDirectory}) {
    final normalized = normalizeRelativePath(relativePath);
    if (normalized.isEmpty) return false;
    final segments = normalized.split('/');
    for (final segment in segments) {
      if (shouldSkipSegmentName(segment)) return true;
    }
    for (final rule in _rules) {
      if (rule.matches(normalized, segments, isDirectory: isDirectory)) {
        return true;
      }
    }
    return false;
  }

  bool shouldSkipDirectory(String relativePath) =>
      shouldIgnore(relativePath, isDirectory: true);

  bool shouldSkipFile(String relativePath, {int? sizeBytes}) {
    if (shouldIgnore(relativePath, isDirectory: false)) return true;
    if (sizeBytes != null && exceedsSizeLimit(sizeBytes)) return true;
    return false;
  }

  static String normalizeRelativePath(String raw) {
    var normalized = raw.replaceAll('\\', '/').trim();
    while (normalized.startsWith('./')) {
      normalized = normalized.substring(2);
    }
    while (normalized.startsWith('/')) {
      normalized = normalized.substring(1);
    }
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  static List<String> _expandPatterns(
    List<String> presets,
    List<String> custom,
  ) {
    final seen = <String>{};
    final out = <String>[];
    for (final presetId in presets) {
      final preset = findIgnorePreset(presetId);
      if (preset == null) continue;
      for (final pattern in preset.patterns) {
        if (seen.add(pattern)) out.add(pattern);
      }
    }
    for (final raw in custom) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      if (seen.add(trimmed)) out.add(trimmed);
    }
    return List<String>.unmodifiable(out);
  }
}

class _CompiledIgnoreRule {
  const _CompiledIgnoreRule({
    required this.matchAnySegment,
    required this.directoryOnly,
    required this.regex,
    this.treePrefixRegex,
  });

  final bool matchAnySegment;
  final bool directoryOnly;
  final RegExp regex;
  final RegExp? treePrefixRegex;

  static _CompiledIgnoreRule? tryParse(String rawPattern) {
    var pattern = rawPattern.trim().replaceAll('\\', '/');
    if (pattern.isEmpty || pattern.startsWith('#')) return null;

    var anchored = false;
    while (pattern.startsWith('/')) {
      anchored = true;
      pattern = pattern.substring(1);
    }
    var directoryOnly = false;
    while (pattern.endsWith('/')) {
      directoryOnly = true;
      pattern = pattern.substring(0, pattern.length - 1);
    }
    if (pattern.isEmpty) return null;

    // Handle trailing `/**` so `cache/**` also prunes the `cache` directory
    // itself during traversal without mistakenly ignoring a regular file named
    // `cache`.
    RegExp? treePrefixRegex;
    if (pattern.endsWith('/**') && pattern.length > 3) {
      final prefix = pattern.substring(0, pattern.length - 3);
      treePrefixRegex = _compileGlob(prefix, allowSubtree: false);
    }

    final hasSlash = pattern.contains('/');
    final matchAnySegment = !anchored && !hasSlash;
    final regex = _compileGlob(
      pattern,
      allowSubtree: !matchAnySegment && !pattern.endsWith('/**'),
    );
    return _CompiledIgnoreRule(
      matchAnySegment: matchAnySegment,
      directoryOnly: directoryOnly,
      regex: regex,
      treePrefixRegex: treePrefixRegex,
    );
  }

  bool matches(
    String normalizedPath,
    List<String> segments, {
    required bool isDirectory,
  }) {
    if (matchAnySegment) {
      final limit = directoryOnly && !isDirectory
          ? segments.length - 1
          : segments.length;
      for (var i = 0; i < limit; i++) {
        if (regex.hasMatch(segments[i])) return true;
      }
      return false;
    }

    if (treePrefixRegex != null &&
        isDirectory &&
        treePrefixRegex!.hasMatch(normalizedPath)) {
      return true;
    }

    if (directoryOnly) {
      if (isDirectory && regex.hasMatch(normalizedPath)) return true;
      // Match any ancestor directory prefix for files inside an ignored dir.
      for (var i = 1; i < segments.length; i++) {
        final ancestor = segments.sublist(0, i).join('/');
        if (regex.hasMatch(ancestor)) return true;
      }
      return false;
    }

    return regex.hasMatch(normalizedPath);
  }

  static RegExp _compileGlob(String glob, {required bool allowSubtree}) {
    final buffer = StringBuffer('^');
    var i = 0;
    while (i < glob.length) {
      if (glob.startsWith('**/', i)) {
        buffer.write('(?:.+/)?');
        i += 3;
        continue;
      }
      if (glob.startsWith('/**', i) && i + 3 == glob.length) {
        buffer.write('/.*');
        i += 3;
        continue;
      }
      if (glob.startsWith('**', i)) {
        buffer.write('.*');
        i += 2;
        continue;
      }
      final ch = glob[i];
      if (ch == '*') {
        buffer.write('[^/]*');
      } else if (ch == '?') {
        buffer.write('[^/]');
      } else {
        buffer.write(RegExp.escape(ch));
      }
      i++;
    }
    if (allowSubtree) {
      buffer.write(r'(?:/.*)?');
    }
    buffer.write(r'$');
    return RegExp(buffer.toString());
  }
}
