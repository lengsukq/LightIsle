import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/lightisle_api.dart';

/// Downloads an authenticated original to an app-private, scoped cache and
/// shares only that *local* path with the platform document opener. Auth
/// cookies and private NAS URLs must never be handed to other applications.
///
/// The other app may keep the file open after this app goes to the background.
/// Successful opens therefore retain a private temporary copy until the next
/// cleanup pass (24h); failed opens delete their copy immediately.
class ExternalFileOpener {
  ExternalFileOpener._();

  static const maxOpenSize = 512 * 1024 * 1024;
  static const _prefix = 'lightisle-other-app-';
  static const _retention = Duration(hours: 24);

  @visibleForTesting
  static String? safeBasename(String fileName) {
    final name = fileName.split('/').last.split('\\').last;
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.startsWith('.lightisle-')) {
      return null;
    }
    if (name.runes.any((c) => c < 32 || c == 127 || c == 0x202e)) {
      return null;
    }
    return name;
  }

  static Future<void> _prune(Directory root) async {
    final now = DateTime.now();
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory ||
          !entity.uri.pathSegments
              .where((s) => s.isNotEmpty)
              .last
              .startsWith(_prefix)) {
        continue;
      }
      try {
        final stat = await entity.stat();
        if (now.difference(stat.modified) >= _retention) {
          await entity.delete(recursive: true);
        }
      } on FileSystemException {
        // The OS may still own an open handle; retry at a future launch.
      }
    }
  }

  static Future<String> open({
    required LightIsleApi api,
    required String path,
    required String name,
    required num? size,
    void Function(double progress)? onProgress,
    Future<OpenResult> Function(String path)? opener,
    Directory? temporaryRoot,
  }) async {
    final basename = safeBasename(name);
    if (basename == null || path.trim().isEmpty) {
      throw const FormatException('文件名或文件路径无效');
    }
    if (size != null && size > maxOpenSize) {
      throw StateError('文件超过 512 MiB 外部打开临时空间上限，请改用“下载”保存原件。');
    }

    final root = temporaryRoot ?? await getTemporaryDirectory();
    await _prune(root);
    final staging = await root.createTemp(_prefix);
    var retained = false;
    try {
      final local = File('${staging.path}${Platform.pathSeparator}$basename');
      await api.download(
        '/api/v2/files/content',
        local.path,
        query: {'path': path},
        onProgress: (received, total) {
          if (total > 0) {
            onProgress?.call((received / total).clamp(0.0, 1.0).toDouble());
          }
        },
      );
      if (!await local.exists()) throw StateError('下载未产生可打开的文件');
      final length = await local.length();
      if (length > maxOpenSize) {
        throw StateError('文件超出 512 MiB 外部打开上限，请改用“下载”。');
      }
      if (size != null && size > 0 && length != size.toInt()) {
        throw const FormatException('文件下载不完整，未交给外部应用');
      }
      final result = await (opener ?? OpenFilex.open)(local.path);
      if (result.type != ResultType.done) {
        throw StateError(
          result.type == ResultType.noAppToOpen
              ? '当前设备没有可打开此格式的应用。可先保存文件后安装对应软件。'
              : '系统未能打开此文件：${result.message}',
        );
      }
      retained = true;
      return '已交给系统应用处理，原文件未修改。';
    } finally {
      if (!retained) {
        try {
          await staging.delete(recursive: true);
        } on FileSystemException {
          // Failure is explicit; original NAS content is untouched.
        }
      }
    }
  }
}
