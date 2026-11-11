import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/lightisle_api.dart';
import 'file_name_validation.dart';

/// The only native platform channel used to hand a verified local file to
/// the operating system. Download, temporary-file and picker lifetimes remain
/// specific to each export operation.
const MethodChannel fileExportChannel = MethodChannel('lightisle/export');

Future<String> exportMediaFile(
  LightIsleApi api, {
  required String path,
  required String name,
  String? destinationDirectory,
  String endpoint = '/api/v2/files/content',
}) async {
  final fileName = name.split('/').last.split('\\').last;
  final issue = validateFileName(fileName);
  if (issue != null) throw FormatException(issue);
  final mobile =
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  Directory? temporaryDirectory;
  try {
    late final String destination;
    if (mobile) {
      final root = await getTemporaryDirectory();
      temporaryDirectory = await root.createTemp('lightisle-media-export-');
      destination =
          '${temporaryDirectory.path}${Platform.pathSeparator}$fileName';
    } else {
      final directory =
          destinationDirectory ??
          await FilePicker.getDirectoryPath(dialogTitle: '选择媒体保存目录');
      if (directory == null || directory.isEmpty) return '已取消保存';
      var candidate = '$directory${Platform.pathSeparator}$fileName';
      final dot = fileName.lastIndexOf('.');
      final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
      final extension = dot > 0 ? fileName.substring(dot) : '';
      var suffix = 1;
      while (await File(candidate).exists()) {
        candidate =
            '$directory${Platform.pathSeparator}$stem ($suffix)$extension';
        suffix++;
        if (suffix > 10000) throw StateError('保存目录已有过多同名文件');
      }
      destination = candidate;
    }
    await api.download(endpoint, destination, query: {'path': path});
    if (!mobile) return '已保存到：$destination';
    final result = await fileExportChannel.invokeMethod<String>('exportFile', {
      'path': destination,
      'name': fileName,
    });
    return result == null
        ? '已取消系统导出'
        : result == 'shared'
        ? '已通过系统分享或保存'
        : '已保存到：$result';
  } finally {
    if (temporaryDirectory != null) {
      try {
        await temporaryDirectory.delete(recursive: true);
      } on FileSystemException {
        // The OS may still hold the item after a cancelled export sheet.
      }
    }
  }
}

/// Shared multi-file save behavior for Files, Gallery and Cinema. On mobile,
/// hand off all files once; on desktop, pick one destination folder.
Future<String> exportSelectedFiles(
  LightIsleApi api, {
  required List<({String path, String name, int size})> items,
  void Function(int finished, int total, String name)? onProgress,
  bool Function()? stillCurrent,
}) async {
  if (items.isEmpty) throw const FormatException('请先选择要保存的文件');
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    return exportMediaFiles(api, items: items, onProgress: onProgress);
  }
  final destination = await FilePicker.getDirectoryPath(
    dialogTitle: '选择批量文件保存位置',
  );
  if (destination == null || destination.isEmpty) return '已取消批量保存';
  var saved = 0;
  final failures = <String>[];
  for (final item in items) {
    try {
      await exportMediaFile(
        api,
        path: item.path,
        name: item.name,
        destinationDirectory: destination,
      );
      if (stillCurrent != null && !stillCurrent()) {
        throw StateError('共享目录已变化，已取消批量导出。');
      }
      saved++;
    } catch (_) {
      failures.add(item.name);
    }
    onProgress?.call(saved + failures.length, items.length, item.name);
  }
  return failures.isEmpty
      ? '已保存 $saved 项原文件到所选文件夹。'
      : '已保存 $saved 项，${failures.length} 项失败，请检查文件权限或网络后重试。';
}

/// Mobile systems present one approval UI for multiple originals. Android
/// grants an SAF destination tree; iOS shares multiple local file URLs. All
/// temporary downloads remain in the app sandbox and are removed afterwards.
Future<String> exportMediaFiles(
  LightIsleApi api, {
  required List<({String path, String name, int size})> items,
  void Function(int finished, int total, String name)? onProgress,
  bool Function()? stillCurrent,
}) async {
  if (stillCurrent != null && !stillCurrent()) {
    throw StateError('共享目录已变化，已取消批量导出。');
  }
  if (items.isEmpty || items.length > 20) {
    throw StateError('手机一次最多导出 20 项媒体文件。');
  }
  var total = 0;
  for (final item in items) {
    if (validateFileName(item.name) != null ||
        item.path.isEmpty ||
        item.size <= 0 ||
        item.size > 2 * 1024 * 1024 * 1024) {
      throw const FormatException('选中项目包含无效文件名或不支持的大文件');
    }
    total += item.size;
  }
  if (total > 2 * 1024 * 1024 * 1024) {
    throw StateError('所选媒体总大小超过 2 GiB，请分批保存以免占满手机存储。');
  }
  final root = await getTemporaryDirectory();
  final directory = await root.createTemp('lightisle-batch-export-');
  try {
    final payload = <Map<String, String>>[];
    final names = <String>{};
    for (final item in items) {
      if (stillCurrent != null && !stillCurrent()) {
        throw StateError('共享目录已变化，已取消批量导出。');
      }
      onProgress?.call(payload.length, items.length, item.name);
      final original = item.name.split('/').last.split('\\').last;
      final dot = original.lastIndexOf('.');
      final stem = dot > 0 ? original.substring(0, dot) : original;
      final ext = dot > 0 ? original.substring(dot) : '';
      var name = original;
      var count = 1;
      while (!names.add(name)) {
        name = '$stem (${count++})$ext';
      }
      final destination = '${directory.path}${Platform.pathSeparator}$name';
      await api.download(
        '/api/v2/files/content',
        destination,
        query: {'path': item.path},
      );
      if (await File(destination).length() != item.size) {
        throw FormatException('文件“${item.name}”下载不完整，未开始系统批量导出。');
      }
      payload.add({'path': destination, 'name': name});
      onProgress?.call(payload.length, items.length, item.name);
    }
    if (stillCurrent != null && !stillCurrent()) {
      throw StateError('共享目录已变化，已取消批量导出。');
    }
    final value = await fileExportChannel.invokeMethod<String>('exportFiles', {
      'files': payload,
    });
    return value == null
        ? '已取消批量导出，临时文件已清理。'
        : value == 'shared'
        ? '已通过系统面板分享或保存 ${items.length} 项。'
        : '系统批量导出结果：$value';
  } finally {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } on FileSystemException {
      // OS providers may still be closing temporary file handles.
    }
  }
}

/// Export an already verified application-private media original without
/// contacting the NAS again. HEIC/RAW are not re-encoded: their exact bytes
/// are handed to the OS document/share picker. Never overwrite an existing
/// desktop file of the same name.
Future<String> exportOfflineMediaFile(File source, String suggestedName) async {
  final name = suggestedName.split('/').last.split('\\').last;
  final issue = validateFileName(name);
  if (issue != null) throw FormatException(issue);
  if (!await source.exists()) throw StateError('本地原件已经不存在，请重新保存');
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    final result = await fileExportChannel.invokeMethod<String>('exportFile', {
      'path': source.path,
      'name': name,
    });
    return result == null
        ? '已取消系统导出'
        : result == 'shared'
        ? '已通过系统分享或保存原件'
        : '已保存到：$result';
  }
  final directory = await FilePicker.getDirectoryPath(dialogTitle: '选择原照片导出目录');
  if (directory == null || directory.isEmpty) return '已取消保存';
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  var index = 0;
  while (index < 10000) {
    final fileName = index == 0 ? name : '$stem ($index)$ext';
    final destination = File('$directory${Platform.pathSeparator}$fileName');
    var created = false;
    try {
      await destination.create(exclusive: true);
      created = true;
      final sink = await destination.open(mode: FileMode.writeOnly);
      try {
        await for (final chunk in source.openRead()) {
          await sink.writeFrom(chunk);
        }
      } finally {
        await sink.close();
      }
      return '已保存原件到：${destination.path}';
    } on FileSystemException {
      if (!created && await destination.exists()) {
        index++;
        continue;
      }
      if (created && await destination.exists()) {
        await destination.delete();
      }
      rethrow;
    } catch (_) {
      // Only ever remove the new file created by this operation. An
      // interrupted export must not leave a truncated "successful" original.
      if (created && await destination.exists()) {
        await destination.delete();
      }
      rethrow;
    }
  }
  throw StateError('保存目录已有过多同名文件');
}
