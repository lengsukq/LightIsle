import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';

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
      final shareUri = await widget.api.createPublicFileShare(
        path: widget.path,
        hours: _hours,
        password: _passwordController.text,
        maxDownloads: int.tryParse(_downloadsController.text.trim()),
      );
      if (mounted) setState(() => _linkController.text = shareUri.toString());
    } catch (error) {
      if (mounted) setState(() => _error = userFacingError(error));
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
