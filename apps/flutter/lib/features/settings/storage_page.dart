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
    setState(() {
      loading = true;
      error = null;
    });
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
            '/api/v2/roots/${Uri.encodeComponent(id)}/storage/users/$userId/usage-check',
            query: {'rootGeneration': '${root['generation']}'},
          );
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
        setState(
          () => usageChecks[userId] =
              '在线文件 ${(bytes / (1 << 30)).toStringAsFixed(2)} GiB · 已检查 $checked 项。'
              '${skipped.isEmpty ? '所有已分配在线硬盘已检查。' : '未能检查：${skipped.join('、')}，结果不完整。'}'
              '回收站、未确认上传不计入本次现场扫描；不会修改账本。',
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> abandonCategory(int id, String category) async {
    if (loading || !widget.isAdmin || !rootsKnown) return;
    final matches = objectList(policies[id]?['locations'])
        .where((loc) => loc['category'] == category)
        .toList(growable: false);
    if (matches.length != 1) {
      setState(() => error = '旧存储绑定已变化，请刷新后重新确认。');
      return;
    }
    final rootID = matches.single['rootID']?.toString() ?? '';
    final generation = matches.single['rootGeneration'];
    if (rootID.isEmpty ||
        generation is! num ||
        generation.toInt() <= 0 ||
        roots.any((root) => root['rootID'] == rootID)) {
      setState(() => error = '原硬盘仍在登记中或身份无法确认，请先在 Mac 管理端核实。');
      return;
    }
    final approved = await confirmAction(
      context,
      '放弃旧存储绑定',
      '仅当旧硬盘已在 Mac 管理端解除登记、且确认无法继续使用时操作。此操作会移除旧目录在 LightIsle 中的授权、分享与容量记录，不会删除旧硬盘原文件，也不会自动迁移数据。',
      action: '确认放弃旧绑定',
      isDestructive: true,
    );
    if (!approved || !mounted) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      policies[id] = await widget.api.send(
        'POST',
        '/api/v2/storage/users/$id/categories/$category/abandon',
        body: {
          'rootID': rootID,
          'generation': generation.toInt(),
          'confirm': true,
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已解除旧分类绑定，原硬盘文件未删除。现在可以分配新的空白目录。')),
        );
      }
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
      final nextPolicies = <int, Map<String, dynamic>>{};
      var nextRoots = <Map<String, dynamic>>[];
      var nextRootsKnown = false;
      var nextUsers = <Map<String, dynamic>>[];
      if (widget.isAdmin) {
        nextUsers = objectList(
          (await widget.api.get('/api/v2/users'))['users'],
        );
        try {
          nextRoots = objectList(
            (await widget.api.get('/api/v2/roots'))['roots'],
          ).toList();
          nextRootsKnown = true;
        } catch (_) {
          nextRoots = [];
        }
        for (final user in nextUsers) {
          final id = (user['id'] as num).toInt();
          nextPolicies[id] = await widget.api.get('/api/v2/users/$id/storage');
        }
      } else {
        final mine = await widget.api.get('/api/v2/me/storage');
        nextPolicies[(mine['userId'] as num).toInt()] = mine;
        // A family member needs the SAME authorized root discovery to see
        // whether their assigned physical disk is actually online. Never
        // show another user's root or use a privileged admin endpoint.
        try {
          nextRoots = objectList(
            (await widget.api.get('/api/v2/roots'))['roots'],
          ).toList();
          nextRootsKnown = true;
        } catch (_) {
          nextRoots = [];
        }
      }
      if (!mounted) return;
      setState(() {
        users = nextUsers;
        roots = nextRoots;
        rootsKnown = nextRootsKnown;
        policies
          ..clear()
          ..addAll(nextPolicies);
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '刷新失败，以下保留上次成功读取的信息：${userFacingError(e)}';
          // An unverified root list must never enable a destructive action.
          rootsKnown = false;
          // Retain the previous friendly drive names, but never trust their
          // previous online state for actions until discovery succeeds again.
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
        });
      }
    }
  }

  Future<void> editQuota(
    int id,
    String rootID,
    int generation,
    num oldQuota,
    String rootName,
  ) async {
    var value = (oldQuota / (1 << 30)).round().toString();
    final entered = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('设置 $rootName 的专属额度 (GiB)'),
        content: TextFormField(
          initialValue: value,
          onChanged: (next) => value = next,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(helperText: '0 表示以后不允许新增数据'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, int.tryParse(value.trim())),
            child: const Text('保存'),
          ),
        ],
      ),
    );
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
        '/api/v2/users/$id/storage/roots/${Uri.encodeComponent(rootID)}/quota',
        body: {'quotaBytes': entered * (1 << 30), 'generation': generation},
      );
    } catch (e) {
      error = userFacingError(e);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> assign(int id, String category) async {
    if (loading ||
        !rootsKnown ||
        !roots.any((root) => root['online'] == true)) {
      return;
    }
    final root = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .65,
        child: ListView(
          children: [
            const ListTile(title: Text('为用户选择存储硬盘')),
            ...roots
                .where((root) => root['online'] == true)
                .map(
                  (r) => ListTile(
                    leading: const Icon(Icons.storage_rounded),
                    title: Text(r['name']?.toString() ?? '硬盘'),
                    subtitle: Text(_physicalFreeLabel(r)),
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

  String _physicalFreeLabel(Map<String, dynamic> root) {
    if (!rootsKnown) return '硬盘状态未核实，请刷新后重试';
    if (root['online'] != true) return '当前离线 · 请重新连接原硬盘';
    final available = root['filesystemAvailableBytes'];
    final total = root['filesystemTotalBytes'];
    if (available is num && total is num && total > 0) {
      return '磁盘可用 ${(available / (1 << 30)).toStringAsFixed(1)} / '
          '${(total / (1 << 30)).toStringAsFixed(1)} GiB · 物理卷共享空间';
    }
    return '在线 · 物理磁盘剩余空间未知';
  }

  String label(Map<String, dynamic> location) {
    final rootID = location['rootID'];
    String name = '原绑定硬盘';
    for (final root in roots) {
      if (root['rootID'] == rootID) {
        name = root['name']?.toString() ?? name;
        if (!rootsKnown) {
          name += ' · 当前连接状态未核实';
        } else if (root['online'] != true) {
          name += ' · 离线，请接回原硬盘';
        } else if (root['generation'] != location['rootGeneration']) {
          name += ' · 存储身份已变化，请检查旧盘';
        } else {
          name += ' · ${_physicalFreeLabel(root)}';
        }
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
        const IsleDisclosureCard(
          title: Text('存储位置与额度说明'),
          leading: Icon(Icons.info_outline_rounded),
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                '每个账号在每块硬盘上有一份独立额度，默认 100 GiB；文件、照片和视频若在同一盘上则共享该盘额度。多盘额度不合并，管理端可逐盘调整。',
                style: TextStyle(height: 1.5),
              ),
            ),
          ],
        ),
        const Notice(
          '个人目录的上传、分块备份和受管单文件复制/移动已接入额度账本；'
          '传统 WebDAV 与下载任务目前拒绝直接写入私人目录，'
          '外部直接操作硬盘不受应用额度保护。'
          '当前仍不是操作系统级全渠道硬配额，请勿将已入账用量视作真实全盘占用。',
        ),
        if (rootsKnown && roots.isNotEmpty)
          ExpansionTile(
            leading: const Icon(Icons.storage_rounded),
            title: Text('已登记的存储位置（${roots.length}）'),
            subtitle: const Text('按物理根管理，磁盘空间不自动合并'),
            children: [
              for (final root in roots)
                ListTile(
                  dense: true,
                  leading: Icon(
                    root['online'] == true
                        ? Icons.check_circle_outline_rounded
                        : Icons.do_not_disturb_on_outlined,
                  ),
                  title: Text(root['name']?.toString() ?? '未命名存储位置'),
                  subtitle: Text(
                    '${_physicalFreeLabel(root)}'
                    ' · 已绑定 ${policies.values.fold<int>(0, (total, policy) => total + objectList(policy['locations']).where((loc) => loc['rootID'] == root['rootID']).length)} 个账号分类',
                  ),
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Text(
                  '这里显示的是底层物理文件系统剩余空间，不是某个账号的额度。'
                  '多个 LightIsle 根可能共享同一 APFS 卷，不能把这些剩余容量相加；'
                  '断开一块盘不会自动把它的文件转存到其他硬盘。',
                ),
              ),
            ],
          ),
        if (loading) const LinearProgressIndicator(),
        if (error != null) Notice(error!, error: true, onRetry: refresh),
        if (widget.isAdmin && !rootsKnown)
          const Notice('无法核对已登记硬盘，请检查 Mac 管理端并刷新；为安全起见不提供旧空间解除操作。'),
        if (widget.isAdmin &&
            rootsKnown &&
            !roots.any((root) => root['online'] == true))
          const Notice('目前没有在线硬盘，请先检查连接或从 Mac 管理端登记。'),
        ...policies.entries.map((entry) {
          final id = entry.key, policy = entry.value;
          final list = objectList(policy['locations']);
          final rootQuotas = objectList(policy['rootQuotas']);
          String username = '我的存储';
          for (final user in users) {
            if (user['id'] == id) {
              username = user['username'].toString();
              break;
            }
          }
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final categoryMeta = {
            'files': (Icons.folder_outlined, const Color(0xff0ea5e9)),
            'photos': (Icons.photo_library_outlined, const Color(0xff10b981)),
            'videos': (Icons.movie_outlined, const Color(0xff8b5cf6)),
          };
          return IsleSurface(
            padding: const EdgeInsets.all(18),
            radius: 18,
            margin: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      username,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (rootQuotas.isEmpty)
                  const Text('尚未分配存储硬盘；分配后每块盘默认 100 GiB。'),
                for (final quota in rootQuotas) ...[
                  Builder(
                    builder: (context) {
                      final rootID = quota['rootID']?.toString() ?? '';
                      final generation = (quota['rootGeneration'] as num? ?? 0)
                          .toInt();
                      Map<String, dynamic>? root;
                      for (final candidate in roots) {
                        if (candidate['rootID'] == rootID) {
                          root = candidate;
                          break;
                        }
                      }
                      final rootName = root?['name']?.toString() ?? '原绑定硬盘';
                      final limit = quota['quotaBytes'];
                      final used = (quota['accountedBytes'] as num? ?? 0)
                          .toDouble();
                      final reserved = (quota['reservedBytes'] as num? ?? 0)
                          .toDouble();
                      final max = limit is num ? limit.toDouble() : 0.0;
                      final active = list.any(
                        (loc) =>
                            loc['rootID'] == rootID &&
                            loc['rootGeneration'] == generation,
                      );
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '$rootName · ${limit == null ? '不限制' : '${(max / (1 << 30)).toStringAsFixed(0)} GiB'}'
                                    '${!active
                                        ? ' · 历史账本'
                                        : !rootsKnown
                                        ? ' · 硬盘状态未核实'
                                        : root?['online'] != true
                                        ? ' · 离线'
                                        : ''}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (widget.isAdmin &&
                                    rootsKnown &&
                                    active &&
                                    limit is num)
                                  TextButton(
                                    onPressed: loading
                                        ? null
                                        : () => editQuota(
                                            id,
                                            rootID,
                                            generation,
                                            limit,
                                            rootName,
                                          ),
                                    child: const Text('调整额度'),
                                  ),
                              ],
                            ),
                            if (max > 0)
                              LinearProgressIndicator(
                                minHeight: 6,
                                value: ((used + reserved) / max).clamp(
                                  0.0,
                                  1.0,
                                ),
                              ),
                            const SizedBox(height: 4),
                            Text(
                              '已入账 ${(used / (1 << 30)).toStringAsFixed(2)} GiB'
                              ' · 预占 ${(reserved / (1 << 30)).toStringAsFixed(2)} GiB'
                              '${max > 0 ? ' · 额度剩余 ${((max - used - reserved).clamp(0.0, max) / (1 << 30)).toStringAsFixed(2)} GiB' : ''}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
                const SizedBox(height: 2),
                Text(
                  '部分渠道尚未计费，当前不是硬盘实际总用量。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (widget.isAdmin) ...[
                  const SizedBox(height: 4),
                  TextButton.icon(
                    onPressed: loading || !rootsKnown
                        ? null
                        : () => checkOnlineUsage(id),
                    icon: const Icon(Icons.calculate_outlined, size: 18),
                    label: const Text('核对在线文件占用'),
                  ),
                  if (usageChecks[id] != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 4),
                      child: Text(
                        usageChecks[id]!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
                const Divider(height: 20),
                ...categories.entries.map((item) {
                  Map<String, dynamic>? loc;
                  for (final row in list) {
                    if (row['category'] == item.key) {
                      loc = row;
                      break;
                    }
                  }
                  final meta =
                      categoryMeta[item.key] ??
                      (Icons.inventory_2_outlined, const Color(0xff64748b));
                  final catIcon = meta.$1;
                  final catColor = meta.$2;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: catColor.withValues(alpha: isDark ? 0.22 : 0.12),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Icon(catIcon, color: catColor, size: 16),
                    ),
                    title: Text(
                      item.value,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    subtitle: Text(loc == null ? '尚未分配' : label(loc)),
                    trailing:
                        widget.isAdmin &&
                            loc != null &&
                            rootsKnown &&
                            !roots.any(
                              (root) => root['rootID'] == loc!['rootID'],
                            )
                        ? TextButton(
                            onPressed: loading
                                ? null
                                : () => abandonCategory(id, item.key),
                            child: const Text('放弃旧空间并重建'),
                          )
                        : widget.isAdmin && loc == null
                        ? OutlinedButton(
                            onPressed:
                                loading ||
                                    !rootsKnown ||
                                    !roots.any((root) => root['online'] == true)
                                ? null
                                : () => assign(id, item.key),
                            child: const Text('分配'),
                          )
                        : null,
                  );
                }),
                if (policy['enforcement'] == 'pending')
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '写入配额拦截：开发中',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
              ],
            ),
          );
        }),
      ],
    ),
  );
}
