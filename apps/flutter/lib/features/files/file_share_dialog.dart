import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/lightisle_api.dart';

/// Uses exactly the same password-protected, expiring share flow as Files.
Future<void> openMediaFileShare(
  BuildContext context, {
  required LightIsleApi api,
  required String path,
  required String name,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      FileShareDialog(api: api, path: path, name: name, isFolder: false),
);

class FileShareDialog extends StatefulWidget {
  const FileShareDialog({
    super.key,
    required this.api,
    required this.path,
    required this.name,
    required this.isFolder,
  });

  final LightIsleApi api;
  final String path;
  final String name;
  final bool isFolder;

  @override
  State<FileShareDialog> createState() => FileShareDialogState();
}

class FileShareDialogState extends State<FileShareDialog> {
  static const _hourOptions = <int>[1, 6, 24, 72, 168];
  final TextEditingController _linkController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _downloadsController = TextEditingController();
  int _hours = 24;
  bool _creating = false;
  String? _error;
  String? _copyMessage;

  @override
  void dispose() {
    _linkController.dispose();
    _passwordController.dispose();
    _downloadsController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_creating || _linkController.text.isNotEmpty) return;
    setState(() {
      _creating = true;
      _error = null;
      _copyMessage = null;
    });
    try {
      final result = await widget.api.send(
        'POST',
        '/api/v2/file-shares',
        body: <String, Object?>{
          'path': widget.path,
          'hours': _hours,
          if (_passwordController.text.trim().isNotEmpty)
            'password': _passwordController.text.trim(),
          if (int.tryParse(_downloadsController.text.trim()) case final count?
              when count > 0)
            'maxDownloads': count,
        },
      );
      final token = result['token']?.toString() ?? '';
      if (token.isEmpty) {
        throw const FormatException('服务端没有返回分享链接，请刷新分享列表确认创建状态。');
      }
      final link = widget.api.publicFileShareUri(token).toString();
      if (mounted) setState(() => _linkController.text = link);
    } catch (error) {
      if (mounted) setState(() => _error = _shareErrorMessage(error));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _copy() async {
    final link = _linkController.text;
    if (link.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: link));
      if (mounted) setState(() => _copyMessage = '已复制分享链接。');
    } catch (_) {
      _linkController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: link.length,
      );
      if (mounted) setState(() => _copyMessage = '无法访问剪贴板，链接已选中，请手动复制。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final created = _linkController.text.isNotEmpty;
    return AlertDialog(
      title: Text(
        '限时分享 · ${widget.name}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.isFolder
                  ? '生成仅可下载此文件夹的临时链接（打包为 ZIP 流式下载，不支持断点续传）。获得链接的人无需登录；链接到期、文件夹被替换或读取授权撤销后会失效。'
                  : '生成仅可下载此文件的临时链接。获得链接的人无需登录；链接到期、文件变化或读取授权撤销后会失效。',
            ),
            const SizedBox(height: 16),
            if (!created)
              DropdownButtonFormField<int>(
                initialValue: _hours,
                decoration: const InputDecoration(labelText: '有效期'),
                items: [
                  for (final hours in _hourOptions)
                    DropdownMenuItem<int>(
                      value: hours,
                      child: Text(_hourLabel(hours)),
                    ),
                ],
                onChanged: _creating
                    ? null
                    : (value) {
                        if (value != null) setState(() => _hours = value);
                      },
              )
            else ...[
              TextField(
                controller: _linkController,
                readOnly: true,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: '分享链接（仅此时显示）',
                  helperText: '保存或发送给需要下载的人。关闭此窗口后无法再次查看。',
                ),
                onTap: () => _linkController.selection = TextSelection(
                  baseOffset: 0,
                  extentOffset: _linkController.text.length,
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _copy,
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('复制分享链接'),
                ),
              ),
              if (_copyMessage != null)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _copyMessage!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (!created)
          FilledButton.icon(
            onPressed: _creating ? null : _create,
            icon: _creating
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.link_rounded),
            label: Text(_creating ? '正在生成…' : '生成分享链接'),
          ),
        TextButton(
          onPressed: _creating ? null : () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    );
  }
}

String _hourLabel(int hours) => switch (hours) {
  1 => '1 小时',
  6 => '6 小时',
  24 => '1 天',
  72 => '3 天',
  168 => '7 天',
  _ => '$hours 小时',
};

String _shareErrorMessage(Object error) {
  if (error is LightIsleApiException) {
    return switch (error.code) {
      'too_many_shares' => '有效分享链接已达到上限。请先撤销不再使用的链接。',
      'file_too_large_to_share' => '文件超过 2 GiB，无法创建下载分享。',
      'unsupported_file_identity' => '无法确认所选对象的身份，请刷新目录后重试。',
      'file_permission_denied' => '当前账号已无法读取此文件，请刷新目录后重试。',
      'invalid_share_request' => '分享时长或文件路径无效，请重新选择后重试。',
      'authentication_required' => '登录状态已失效，请重新登录。',
      _ => error.message,
    };
  }
  return error.toString();
}
