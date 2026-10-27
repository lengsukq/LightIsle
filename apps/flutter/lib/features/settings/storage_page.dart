import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import '../../core/isle_theme.dart';
import '../../core/user_facing_error.dart';

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
  bool rootsKnown = false;
  final Map<int, String> usageChecks = {};
  final Map<int, Map<String, dynamic>> policies = {};
  static const categories = {'files': '普通文件', 'photos': '照片', 'videos': '视频'};

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> checkOnlineUsage(int userId) async {
    final policy = policies[userId];
    if (!widget.isAdmin || !rootsKnown || policy == null || loading) return;
    final assigned = <String>{};
    for (final location in objectList(policy['locations'])) {
      final rootID = location['rootID'];
      if (rootID is String) assigned.add(rootID);
    }
    if (assigned.isEmpty) {
      setState(() => usageChecks[userId] = '还没有分配个人目录。');
      return;
    }
    setState(() { loading = true; error = null; });
    try {
      var bytes = 0;
      var checked = 0;
      final skipped = <String>[];
      for (final id in assigned) {
        Map<String, dynamic>? root;
        for (final item in roots) {
          if (item['rootID'] == id) root = item;
        }
        if (root == null || root['online'] != true) {
          skipped.add(root?['name']?.toString() ?? id);
          continue;
        }
        try {
          final report = await widget.api.get(
            '/api/v2/roots/${Uri.encodeComponent(id)}/storage/users/$userId/usage-check');
          if (report['rootGeneration'] != root['generation']) {
            skipped.add(root['name']?.toString() ?? id);
            continue;
          }
          bytes += (report['liveBytes'] as num).toInt();
          checked += (report['entriesChecked'] as num).toInt();
        } catch (_) {
          skipped.add(root['name']?.toString() ?? id);
        }
      }
      if (mounted) {
        setState(() => usageChecks[userId] =
          '在线文件 ${ (bytes / (1 << 30)).toStringAsFixed(2)} GiB · 已检查 $checked 项。'
          '${skipped.isEmpty ? '所有已分配在线硬盘已检查。' : '未能检查：${skipped.join('、')}，结果不完整。'}'
          '回收站、未确认上传不计入本次现场扫描；不会修改账本。');
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> abandonCategory(int id, String category) async {
    final approved = await confirmAction(context, '放弃旧存储绑定',
      '仅当旧硬盘已在 Mac 管理端解除登记、且确认无法继续使用时操作。此操作会移除旧目录在 LightIsle 中的授权、分享与容量记录，不会删除旧硬盘原文件，也不会自动迁移数据。',
      action: '确认放弃旧绑定', isDestructive: true);
    if (!approved || !mounted) return;
    setState(() { loading = true; error = null; });
    try {
      policies[id] = await widget.api.send('POST',
        '/api/v2/storage/users/$id/categories/$category/abandon');
    } catch (e) {
      error = '放弃旧绑定失败：${userFacingError(e)}';
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> refresh() async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      policies.clear();
      rootsKnown = false;
      if (widget.isAdmin) {
        users = objectList((await widget.api.get('/api/v2/users'))['users']);
        try {
          roots = objectList((await widget.api.get('/api/v2/roots'))['roots'])
              .toList();
          rootsKnown = true;
        } catch (_) {
          roots = [];
        }
        for (final user in users) {
          final id = (user['id'] as num).toInt();
          policies[id] = await widget.api.get('/api/v2/users/$id/storage');
        }
      } else {
        final mine = await widget.api.get('/api/v2/me/storage');
        policies[(mine['userId'] as num).toInt()] = mine;
      }
    } catch (e) {
      error = userFacingError(e);
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
        '/api/v2/users/$id/storage/quota',
        body: {'quotaBytes': entered * (1 << 30)},
      );
    } catch (e) {
      error = userFacingError(e);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> assign(int id, String category) async {
    if (!roots.any((root) => root['online'] == true)) return;
    final root = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('为用户选择存储硬盘')),
            ...roots.where((root) => root['online'] == true).map(
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
      policies[id] = await widget.api.get('/api/v2/users/$id/storage');
    } catch (e) {
      error = userFacingError(e);
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
        if (root['online'] != true) name += ' · 离线';
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
        if (widget.isAdmin && !rootsKnown)
          const Notice('无法核对已登记硬盘，请检查 Mac 管理端并刷新；为安全起见不提供旧空间解除操作。'),
        if (widget.isAdmin && rootsKnown && !roots.any((root) => root['online'] == true))
          const Notice('目前没有在线硬盘，请先检查连接或从 Mac 管理端登记。'),
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
                if (widget.isAdmin) ...[
                  TextButton.icon(
                    onPressed: loading || !rootsKnown
                        ? null : () => checkOnlineUsage(id),
                    icon: const Icon(Icons.calculate_outlined, size: 18),
                    label: const Text('核对在线文件占用'),
                  ),
                  if (usageChecks[id] != null)
                    Text(usageChecks[id]!, style: Theme.of(context).textTheme.bodySmall),
                ],
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
                    trailing: widget.isAdmin && loc != null && rootsKnown &&
                            !roots.any((root) => root['rootID'] == loc!['rootID'])
                        ? TextButton(
                            onPressed: loading ? null : () => abandonCategory(id, item.key),
                            child: const Text('放弃旧空间并重建'),
                          )
                        : widget.isAdmin && loc == null
                        ? OutlinedButton(
                            onPressed: loading || !roots.any((root) => root['online'] == true)
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
