import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import '../../core/isle_theme.dart';

class StoragePage extends StatefulWidget {
  const StoragePage({super.key, required this.api, required this.isAdmin});
  final LightIsleApi api;
  final bool isAdmin;
  @override
  State<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends State<StoragePage> {
  bool loading = false;
  String? error;
  List<Map<String, dynamic>> users = [];
  List<Map<String, dynamic>> roots = [];
  final Map<int, Map<String, dynamic>> policies = {};
  static const categories = {'files': '普通文件', 'photos': '照片', 'videos': '视频'};

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      policies.clear();
      if (widget.isAdmin) {
        users = objectList((await widget.api.get('/api/v1/users'))['users']);
        try {
          roots = objectList((await widget.api.get('/api/v2/roots'))['roots'])
              .where((r) => r['online'] == true)
              .toList();
        } catch (_) {
          roots = [];
        }
        for (final user in users) {
          final id = (user['id'] as num).toInt();
          policies[id] = await widget.api.get('/api/v1/users/$id/storage');
        }
      } else {
        final mine = await widget.api.get('/api/v1/me/storage');
        policies[(mine['userId'] as num).toInt()] = mine;
      }
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
        });
      }
    }
  }

  Future<void> editQuota(int id, num oldQuota) async {
    final input = TextEditingController(
      text: (oldQuota / (1 << 30)).round().toString(),
    );
    final entered = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设置总空间 (GiB)'),
        content: TextField(
          controller: input,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(helperText: '0 表示以后不允许新增数据'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, int.tryParse(input.text.trim())),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    input.dispose();
    if (entered == null || !mounted) return;
    if (entered < 0 || entered > 1048576) {
      setState(() => error = '配额范围为 0–1048576 GiB');
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      policies[id] = await widget.api.send(
        'PUT',
        '/api/v1/users/$id/storage/quota',
        body: {'quotaBytes': entered * (1 << 30)},
      );
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> assign(int id, String category) async {
    if (roots.isEmpty) return;
    final root = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('为用户选择存储硬盘')),
            ...roots.map(
              (r) => ListTile(
                leading: const Icon(Icons.storage_rounded),
                title: Text(r['name']?.toString() ?? '硬盘'),
                onTap: () => Navigator.pop(context, r),
              ),
            ),
          ],
        ),
      ),
    );
    if (root == null || !mounted) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await widget.api.assignStorageRoot(
        '/api/v2/roots/${Uri.encodeComponent(root['rootID'].toString())}/users/$id/storage/$category',
        (root['generation'] as num).toInt(),
      );
      policies[id] = await widget.api.get('/api/v1/users/$id/storage');
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  String label(Map<String, dynamic> location) {
    final rootID = location['rootID'];
    String name = '原绑定硬盘';
    for (final root in roots) {
      if (root['rootID'] == rootID) {
        name = root['name']?.toString() ?? name;
        break;
      }
    }
    final path = location['relativePath'].toString();
    return '$name / $path';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('存储空间'),
      actions: [
        IconButton(
          onPressed: loading ? null : refresh,
          tooltip: '刷新',
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: IsleListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Notice('每个用户拥有独立目录；照片、视频和文件可以放在不同硬盘，合计使用一份配额。'),
        const SizedBox(height: 8),
        const Notice('容量设置已支持，但全部写入方式的硬配额拦截仍在开发中。'),
        if (loading) const LinearProgressIndicator(),
        if (error != null) Notice(error!, error: true, onRetry: refresh),
        if (widget.isAdmin && roots.isEmpty)
          const Notice('请在 Mac 管理端开启多根并添加在线硬盘。'),
        ...policies.entries.map((entry) {
          final id = entry.key, policy = entry.value;
          final quota = policy['quotaBytes'];
          final quotaLabel = quota == null
              ? '不限制'
              : '${((quota as num) / (1 << 30)).toStringAsFixed(0)} GiB';
          final list = objectList(policy['locations']);
          String username = '我的存储';
          for (final user in users) {
            if (user['id'] == id) {
              username = user['username'].toString();
              break;
            }
          }
          return IsleSurface(
            padding: const EdgeInsets.all(16),
            radius: 18,
            margin: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(username, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: Text('总配额：$quotaLabel')),
                    if (widget.isAdmin && quota is num)
                      TextButton(
                        onPressed: loading ? null : () => editQuota(id, quota),
                        child: const Text('调整'),
                      ),
                  ],
                ),
                Text(
                  '已入账：${((policy['accountedBytes'] as num? ?? 0) / (1 << 30)).toStringAsFixed(2)} GiB'
                  ' · 预占：${((policy['reservedBytes'] as num? ?? 0) / (1 << 30)).toStringAsFixed(2)} GiB',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Text(
                  '部分渠道尚未计费，当前不是硬盘实际总用量。',
                  style: TextStyle(fontSize: 12),
                ),
                const Divider(),
                ...categories.entries.map((item) {
                  Map<String, dynamic>? loc;
                  for (final row in list) {
                    if (row['category'] == item.key) {
                      loc = row;
                      break;
                    }
                  }
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(item.value),
                    subtitle: Text(loc == null ? '尚未分配' : label(loc)),
                    trailing: widget.isAdmin && loc == null
                        ? OutlinedButton(
                            onPressed: loading || roots.isEmpty
                                ? null
                                : () => assign(id, item.key),
                            child: const Text('分配'),
                          )
                        : null,
                  );
                }),
                if (policy['enforcement'] == 'pending')
                  const Text('写入配额拦截：开发中', style: TextStyle(fontSize: 12)),
              ],
            ),
          );
        }),
      ],
    ),
  );
}
