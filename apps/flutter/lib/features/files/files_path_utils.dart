import 'dart:io';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';

const int kFilesPageSize = 100;
const int kFilesMaxTextPreviewSize = 1024 * 1024;
const int kFilesLocateMaxPages = 6;
const Duration kFilesHighlightDuration = Duration(milliseconds: 2800);
const int _kMaxLocalConflictAttempts = 10000;

String friendlyFileDownloadError(Object error, {required bool archive}) {
  if (archive && error is LightIsleApiException) {
    if (error.code == 'archive_limit_exceeded' || error.statusCode == 413) {
      return '文件夹超过 ZIP 导出限制（2 GiB 或 2,000 项），请下载较小的子文件夹。';
    }
    if (error.code == 'archive_busy') {
      return '当前打包下载较多，请稍后重试。';
    }
    if (error.code == 'archive_source_changed') {
      return '文件夹内容在下载前发生变化，请刷新目录后重试。';
    }
  }
  return userFacingError(error);
}

String joinRelativeFilePath(String directory, String name) =>
    directory == '.' || directory.isEmpty ? name : '$directory/$name';

String joinNativeFilePath(String directory, String name) {
  final separator = Platform.pathSeparator;
  final clean = directory.endsWith(separator)
      ? directory.substring(0, directory.length - separator.length)
      : directory;
  return '$clean$separator$name';
}

String nativeFileBasename(String path) => path.split(Platform.pathSeparator).last;

String normalizeFilePickerPath(String path) {
  final uri = Uri.tryParse(path);
  if (uri != null && uri.scheme == 'file') return uri.toFilePath();
  return path;
}

Future<String> nextAvailableLocalDestination(
  String directory,
  String fileName,
) async {
  final dot = fileName.lastIndexOf('.');
  final hasExtension = dot > 0;
  final stem = hasExtension ? fileName.substring(0, dot) : fileName;
  final extension = hasExtension ? fileName.substring(dot) : '';
  for (var suffix = 2; suffix < _kMaxLocalConflictAttempts; suffix++) {
    final candidate = joinNativeFilePath(
      directory,
      '$stem ($suffix)$extension',
    );
    if (!await File(candidate).exists()) return candidate;
  }
  throw const FileSystemException('无法生成不冲突的文件名。');
}

List<(String, String)> buildFilePathSegments({
  required String currentPath,
  required String initialPath,
  required String rootName,
}) {
  if (initialPath != '.' &&
      (currentPath == initialPath ||
          currentPath.startsWith('$initialPath/'))) {
    final label = initialPath.endsWith('/photos')
        ? '我的照片'
        : initialPath.endsWith('/videos')
        ? '我的视频'
        : '我的文件';
    final result = <(String, String)>[(label, initialPath)];
    if (currentPath == initialPath) return result;
    final relative = currentPath.substring(initialPath.length + 1).split('/');
    for (var i = 0; i < relative.length; i++) {
      result.add((
        relative[i],
        '$initialPath/${relative.take(i + 1).join('/')}',
      ));
    }
    return result;
  }
  final result = <(String, String)>[(rootName, '.')];
  if (currentPath == '.' || currentPath.isEmpty) return result;
  final names = currentPath.split('/');
  for (var i = 0; i < names.length; i++) {
    result.add((names[i], names.take(i + 1).join('/')));
  }
  return result;
}

String? fileSearchSubdirLabel(String? searchScopeSubdir) {
  if (searchScopeSubdir == null || searchScopeSubdir.isEmpty) return null;
  final parts = searchScopeSubdir.split('/');
  return parts.isEmpty ? searchScopeSubdir : parts.last;
}
