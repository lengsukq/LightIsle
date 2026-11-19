import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/isle_quick_jump.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import '../files/duplicate_files_page.dart';
import '../files/isle_folder_picker_sheet.dart';
import '../media/photo_similar_cleanup_sheet.dart';
import 'admin_smb_page.dart';
import 'cache_management_page.dart';
import 'dav_page.dart';
import 'storage_charts.dart';

part 'storage_page_dialogs.dart';
part 'storage_page_switch.dart';

int _asStorageInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

double _asStorageDouble(Object? value, [double fallback = 0]) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? fallback;
}

class StoragePage extends StatefulWidget {
  const StoragePage({
    super.key,
    required this.api,
    required this.isAdmin,
    this.initialUserId,
  });
  final LightIsleApi api;
  final bool isAdmin;
  final int? initialUserId;
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
  final Map<int, String> switchMessages = {};
  final Map<int, ({String stageLabel, String summary, double? fraction})>
  switchProgress = {};
  final Map<int, ({String taskID, bool publication})> switchRecoveries = {};
  final Map<int, String> switchCancellations = {};
  final Map<String, String> switchStepUpTokens = {};
  final Map<int, Map<String, dynamic>> policies = {};
  final Map<int, String> userPolicyErrors = {};
  final Set<int> loadingUserIds = {};
  static const categories = {'files': '普通文件', 'photos': '照片', 'videos': '视频'};
  static const _maxPolicyConcurrency = 3;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  void _updateState(VoidCallback fn) => setState(fn);

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
          bytes += _asStorageInt(report['liveBytes']);
          checked += _asStorageInt(report['entriesChecked']);
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

  Future<void> refreshSingleUserPolicy(int userId) async {
    if (loading || loadingUserIds.contains(userId)) return;
    setState(() {
      loadingUserIds.add(userId);
      userPolicyErrors.remove(userId);
    });
    try {
      final policy = await widget.api.get('/api/v2/users/$userId/storage');
      if (!mounted) return;
      setState(() {
        policies[userId] = policy;
        userPolicyErrors.remove(userId);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        userPolicyErrors[userId] = userFacingError(e);
      });
    } finally {
      if (mounted) {
        setState(() => loadingUserIds.remove(userId));
      }
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
      final nextUserErrors = <int, String>{};
      Object? firstPolicyError;
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
        for (var i = 0; i < nextUsers.length; i += _maxPolicyConcurrency) {
          final batch = nextUsers.skip(i).take(_maxPolicyConcurrency);
          await Future.wait(
            batch.map((user) async {
              final id = _asStorageInt(user['id']);
              try {
                nextPolicies[id] = await widget.api.get(
                  '/api/v2/users/$id/storage',
                );
              } catch (e) {
                firstPolicyError ??= e;
                nextUserErrors[id] = userFacingError(e);
                final previous = policies[id];
                if (previous != null) {
                  nextPolicies[id] = previous;
                }
              }
            }),
          );
        }
        if (nextUsers.isNotEmpty &&
            nextUserErrors.length == nextUsers.length &&
            firstPolicyError != null) {
          throw firstPolicyError!;
        }
      } else {
        final mine = await widget.api.get('/api/v2/me/storage');
        nextPolicies[_asStorageInt(mine['userId'])] = mine;
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
        userPolicyErrors
          ..clear()
          ..addAll(nextUserErrors);
        policies
          ..clear()
          ..addAll(nextPolicies);
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '刷新失败，以下保留上次成功读取的信息：${userFacingError(e)}';
          rootsKnown = false;
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
  Widget build(BuildContext context) {
    final palette = IslePalette.of(context);
    final amber = palette['brandAmber'];
    final mineral = palette['brandBlue'];

    return Scaffold(
      appBar: IsleAppBar(
        title: const Text('存储空间'),
        actions: [
          IconButton(
            onPressed: loading ? null : refresh,
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
          ),
          IsleHelpButton(
            title: '容量统计与配额说明',
            accentColor: amber,
            items: const [
              IsleHelpItem(
                title: '物理卷共享与目录登记',
                body: '新增或移除 NAS 物理盘目录请在 Mac 原生管理端操作；同一 APFS 容器下的多个卷共享底层物理剩余空间。',
              ),
              IsleHelpItem(
                title: '入账口径与限额范围',
                body: '成员已入账容量统计已登记渠道的写入与上传预占；部分外部直写渠道未实时计入账本，请同时留意物理盘可用空间。',
              ),
            ],
          ),
        ],
      ),
      body: IsleListView(
        maxWidth: IsleLayout.workbenchMaxWidth,
        children: [
          if (loading) const LinearProgressIndicator(),
          if (error != null) Notice(error!, error: true, onRetry: refresh),
          if (rootsKnown && roots.isNotEmpty) ...[
            IsleSurface(
              margin: EdgeInsets.zero,
              tint: amber,
              radius: IsleRadius.hero,
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      IsleSquircleBadge(
                        icon: Icons.storage_rounded,
                        color: amber,
                        size: 38,
                        iconSize: 19,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '1. 存储目录管理 · 已登记的存储位置（${roots.length}）',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  for (final root in roots)
                    StorageRootSummaryRow(
                      root: root,
                      physicalLabel: _physicalFreeLabel(root),
                      boundCount: policies.values.fold<int>(
                        0,
                        (total, policy) =>
                            total +
                            objectList(policy['locations'])
                                .where((loc) => loc['rootID'] == root['rootID'])
                                .length,
                      ),
                      summary: StorageRootUsageSummary.fromRoot(
                        root,
                        policies.values,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (widget.isAdmin)
            const IsleIntroCard(
              icon: Icons.folder_shared_rounded,
              title: '2. 用户空间管理 · 全员个人空间与配额管理',
            ),
          if (widget.isAdmin && !rootsKnown)
            const Notice('无法核对已登记硬盘，请检查 Mac 管理端并刷新；为安全起见不提供旧空间解除操作。'),
          if (widget.isAdmin &&
              rootsKnown &&
              !roots.any((root) => root['online'] == true))
            const Notice('目前没有在线硬盘，请先检查连接或从 Mac 管理端登记。'),
          if (policies.isNotEmpty || userPolicyErrors.isNotEmpty)
            IsleResponsiveGrid(
              minItemWidth: 380,
              maxColumns: 2,
              spacing: 14,
              runSpacing: 14,
              children: [
                for (final id
                    in ({...policies.keys, ...userPolicyErrors.keys}.toList()
                      ..sort((a, b) {
                        if (widget.initialUserId != null) {
                          if (a == widget.initialUserId) return -1;
                          if (b == widget.initialUserId) return 1;
                        }
                        return a.compareTo(b);
                      })))
                  Builder(
                    builder: (context) {
                      final policy = policies[id] ?? const <String, dynamic>{};
                      final list = objectList(policy['locations']);
                      final rootQuotas = objectList(policy['rootQuotas']);
                      String username = '我的存储';
                      bool isUserAdmin =
                          policy['unlimited'] == true ||
                          policy['role'] == 'admin';
                      for (final user in users) {
                        if (user['id'] == id) {
                          username = user['username'].toString();
                          if (user['role'] == 'admin') isUserAdmin = true;
                          break;
                        }
                      }
                      final isDark =
                          Theme.of(context).brightness == Brightness.dark;
                      final categoryMeta = {
                        'files': (
                          Icons.folder_outlined,
                          palette['brandAmber'],
                        ),
                        'photos': (
                          Icons.photo_library_outlined,
                          palette['brandRose'],
                        ),
                        'videos': (
                          Icons.movie_outlined,
                          palette['brandViolet'],
                        ),
                      };
                      return IsleSurface(
                        margin: EdgeInsets.zero,
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 10,
                              runSpacing: 8,
                              alignment: WrapAlignment.spaceBetween,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IsleSquircleBadge(
                                      icon: isUserAdmin
                                          ? Icons.shield_outlined
                                          : Icons.person_outline_rounded,
                                      color: mineral,
                                      size: 36,
                                      iconSize: 18,
                                    ),
                                    const SizedBox(width: 10),
                                    Flexible(
                                      child: Text(
                                        username,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                            ),
                                      ),
                                    ),
                                    if (isUserAdmin) ...[
                                      const SizedBox(width: 8),
                                      IsleStatusBadge(
                                        label: '无限配额',
                                        color: mineral,
                                      ),
                                    ],
                                  ],
                                ),
                                if (widget.isAdmin &&
                                    rootsKnown &&
                                    roots.any((root) => root['online'] == true))
                                  OutlinedButton.icon(
                                    onPressed: loading
                                        ? null
                                        : () => allocateSpace(
                                            id,
                                            username,
                                            list,
                                            isUserAdmin: isUserAdmin,
                                          ),
                                    icon: const Icon(
                                      Icons.add_chart_rounded,
                                      size: 16,
                                    ),
                                    label: const Text('分配空间与限额'),
                                  ),
                              ],
                            ),
                            if (userPolicyErrors[id] case final policyErr?) ...[
                              const SizedBox(height: 8),
                              Notice(
                                '该成员空间信息读取失败：$policyErr',
                                error: true,
                                onRetry: loadingUserIds.contains(id)
                                    ? null
                                    : () => refreshSingleUserPolicy(id),
                              ),
                            ],
                            if (loadingUserIds.contains(id)) ...[
                              const SizedBox(height: 6),
                              const LinearProgressIndicator(),
                            ],
                            if (widget.isAdmin)
                              TextButton(
                                onPressed: loading
                                    ? null
                                    : () => showLatestStorageSwitch(id),
                                child: const Text('查看最近换盘任务'),
                              ),
                            if (switchProgress[id] case final prog?) ...[
                              const SizedBox(height: 6),
                              Text(
                                prog.stageLabel,
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              if (prog.fraction != null) ...[
                                const SizedBox(height: 4),
                                LinearProgressIndicator(value: prog.fraction),
                              ],
                              const SizedBox(height: 4),
                            ],
                            if (switchMessages[id] case final message?)
                              Text(message),
                            if (switchCancellations[id] case final taskID?)
                              TextButton(
                                onPressed: () =>
                                    cancelStorageSwitch(id, taskID),
                                child: const Text('取消换盘任务'),
                              ),
                            if (switchRecoveries[id] case final recovery?)
                              TextButton(
                                onPressed: loading
                                    ? null
                                    : () => recoverStorageSwitch(
                                        id,
                                        recovery.taskID,
                                        publication: recovery.publication,
                                      ),
                                child: Text(
                                  recovery.publication
                                      ? '重新核验并继续切换'
                                      : '重新核验并回收源文件',
                                ),
                              ),
                            const SizedBox(height: 10),
                            if (rootQuotas.isEmpty)
                              Text(
                                isUserAdmin
                                    ? '管理员默认无限配额（仅受所选磁盘实际可用空间限制）。'
                                    : '尚未分配存储硬盘；分配后每块盘默认 100 GiB。',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            for (final quota in rootQuotas)
                              _buildUserRootQuotaCard(
                                context,
                                userId: id,
                                username: username,
                                quota: quota,
                                locations: list,
                                isDark: isDark,
                              ),
                            if (widget.isAdmin) ...[
                              const SizedBox(height: 4),
                              TextButton.icon(
                                onPressed: loading || !rootsKnown
                                    ? null
                                    : () => checkOnlineUsage(id),
                                icon: const Icon(
                                  Icons.calculate_outlined,
                                  size: 18,
                                ),
                                label: const Text('核对在线文件占用'),
                              ),
                              if (usageChecks[id] != null)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    left: 4,
                                    bottom: 4,
                                  ),
                                  child: Text(
                                    usageChecks[id]!,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ),
                            ],
                            const Divider(height: 20),
                            for (final item in categories.entries)
                              _buildUserCategoryTile(
                                userId: id,
                                username: username,
                                categoryKey: item.key,
                                categoryLabel: item.value,
                                locations: list,
                                categoryMeta: categoryMeta,
                                isDark: isDark,
                              ),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            ),
          const SizedBox(height: 12),
          IsleQuickJumpStrip(
            key: const ValueKey('storageQuickJumpStrip'),
            items: [
              IsleQuickJumpItem(
                icon: Icons.file_copy_outlined,
                label: '重复大文件清理',
                tooltip: '扫描重复大文件并按比例清理释放空间',
                onTap: () => Navigator.of(context).push<void>(
                  buildIslePageRoute<void>(
                    builder: (_) => DuplicateFilesPage(api: widget.api),
                  ),
                ),
              ),
              IsleQuickJumpItem(
                icon: Icons.photo_library_outlined,
                label: '相似照片去重',
                tooltip: '对比连拍或相似照片并清理冗余副本',
                onTap: () => Navigator.of(context).push<void>(
                  buildIslePageRoute<void>(
                    builder: (_) => PhotoSimilarCleanupPage(api: widget.api),
                  ),
                ),
              ),
              IsleQuickJumpItem(
                icon: Icons.folder_shared_outlined,
                label: 'WebDAV 挂载',
                tooltip: '管理 WebDAV 挂载地址与独立访问密码',
                onTap: () => Navigator.of(context).push<void>(
                  buildIslePageRoute<void>(
                    builder: (_) => DavPage(api: widget.api),
                  ),
                ),
              ),
              if (widget.isAdmin) ...[
                IsleQuickJumpItem(
                  icon: Icons.lan_outlined,
                  label: 'Mac 文件共享 (SMB)',
                  tooltip: '管理 Mac 局域网 SMB 共享目录与访客权限',
                  onTap: () => Navigator.of(context).push<void>(
                    buildIslePageRoute<void>(
                      builder: (_) => AdminSmbPage(api: widget.api),
                    ),
                  ),
                ),
                IsleQuickJumpItem(
                  icon: Icons.cleaning_services_outlined,
                  label: '本地缓存管理',
                  tooltip: '查看缩略图、海报、地图瓦片与离线副本缓存占比',
                  onTap: () => Navigator.of(context).push<void>(
                    buildIslePageRoute<void>(
                      builder: (_) =>
                          CacheManagementPage(api: widget.api, isAdmin: true),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
