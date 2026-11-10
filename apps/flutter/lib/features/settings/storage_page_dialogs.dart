part of 'storage_page.dart';

extension _StoragePageDialogs on _StoragePageState {
  Future<void> editQuota(
    int id,
    String rootID,
    int generation,
    num oldQuota,
    String rootName,
  ) async {
    var value = (oldQuota / (1 << 30)).round().toString();
    var presetRevision = 0;
    final entered = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => AlertDialog(
          title: Text('设置 $rootName 的专属额度 (GiB)'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                key: ValueKey('quota-edit-$presetRevision'),
                initialValue: value,
                onChanged: (next) => value = next,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(helperText: '0 表示以后不允许新增数据'),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final preset in const [50, 100, 200, 500, 1024, 0])
                    ActionChip(
                      label: Text(preset == 0 ? '0 禁写' : '$preset GiB'),
                      onPressed: () => setModalState(() {
                        value = '$preset';
                        presetRevision++;
                      }),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, int.tryParse(value.trim())),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (entered == null || !mounted) return;
    if (entered < 0 || entered > 1048576) {
      _updateState(() => error = '配额范围为 0–1048576 GiB');
      return;
    }
    _updateState(() {
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
      if (mounted) _updateState(() => loading = false);
    }
  }

  Future<void> allocateSpace(
    int id,
    String username,
    List<Map<String, dynamic>> currentLocations, {
    bool isUserAdmin = false,
  }) async {
    final onlineRoots = roots
        .where((root) => root['online'] == true)
        .toList(growable: false);
    if (loading || !rootsKnown || onlineRoots.isEmpty) return;
    var chosenRoot = onlineRoots.first;
    var quotaText = '100';
    var presetRevision = 0;
    var subdirText = '';
    final boundCats = currentLocations
        .map((loc) => loc['category']?.toString() ?? '')
        .toSet();
    final selectedCats = _StoragePageState.categories.keys
        .where((cat) => !boundCats.contains(cat))
        .toSet();
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => AlertDialog(
          title: Text('为 $username 分配存储空间与限额'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: chosenRoot['rootID']?.toString(),
                    decoration: const InputDecoration(labelText: '选择在线存储硬盘'),
                    items: [
                      for (final r in onlineRoots)
                        DropdownMenuItem(
                          value: r['rootID']?.toString(),
                          child: Text(r['name']?.toString() ?? '硬盘'),
                        ),
                    ],
                    onChanged: (next) {
                      for (final r in onlineRoots) {
                        if (r['rootID']?.toString() == next) {
                          setModalState(() => chosenRoot = r);
                          break;
                        }
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  if (isUserAdmin)
                    Text(
                      '管理员默认无限配额，仅受所选硬盘实际可用空间限制。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    )
                  else ...[
                    TextFormField(
                      key: ValueKey('alloc-quota-$presetRevision'),
                      initialValue: quotaText,
                      onChanged: (next) => quotaText = next,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '该盘空间限额 (GiB)',
                        helperText: '分配时即配置好该盘限额，后续可随时修改',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final preset in const [50, 100, 200, 500, 1024])
                          ActionChip(
                            label: Text('$preset GiB'),
                            onPressed: () => setModalState(() {
                              quotaText = '$preset';
                              presetRevision++;
                            }),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  const Text('同时创建的分类目录（可不勾选，先定限额后续再加）：'),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final entry in _StoragePageState.categories.entries)
                        FilterChip(
                          label: Text(
                            boundCats.contains(entry.key)
                                ? '${entry.value}（已分配）'
                                : entry.value,
                          ),
                          selected:
                              boundCats.contains(entry.key) ||
                              selectedCats.contains(entry.key),
                          onSelected: boundCats.contains(entry.key)
                              ? null
                              : (checked) => setModalState(() {
                                  if (checked) {
                                    selectedCats.add(entry.key);
                                  } else {
                                    selectedCats.remove(entry.key);
                                  }
                                }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    onChanged: (next) => subdirText = next,
                    decoration: const InputDecoration(
                      labelText: '可选：顺便新建子目录',
                      hintText: '例如 文档资料 或 photos/旅行',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认分配'),
            ),
          ],
        ),
      ),
    );
    if (approved != true || !mounted) return;
    int? parsedGiB;
    if (!isUserAdmin) {
      parsedGiB = int.tryParse(quotaText.trim());
      if (parsedGiB == null || parsedGiB < 0 || parsedGiB > 1048576) {
        _updateState(() => error = '配额范围为 0–1048576 GiB');
        return;
      }
    }
    final rootID = chosenRoot['rootID'].toString();
    final generation = (chosenRoot['generation'] as num).toInt();
    final orderedCats = _StoragePageState.categories.keys
        .where((c) => selectedCats.contains(c) && !boundCats.contains(c))
        .toList(growable: false);
    final trimmedSubdir = subdirText.trim();
    _updateState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.api.send(
        'POST',
        '/api/v2/roots/${Uri.encodeComponent(rootID)}/users/$id/storage',
        query: {'rootGeneration': '$generation'},
        body: {
          if (!isUserAdmin && parsedGiB != null)
            'quotaBytes': parsedGiB * (1 << 30),
          'categories': orderedCats,
          if (trimmedSubdir.isNotEmpty) 'subdirectories': [trimmedSubdir],
        },
      );
      if (result['policy'] is Map<String, dynamic>) {
        policies[id] = result['policy'] as Map<String, dynamic>;
      } else {
        policies[id] = await widget.api.get('/api/v2/users/$id/storage');
      }
    } catch (e) {
      error = userFacingError(e);
    } finally {
      if (mounted) _updateState(() => loading = false);
    }
  }

  Future<void> addCategoryOnDisk(
    int id,
    String rootID,
    int generation,
    String category,
  ) async {
    if (loading || !rootsKnown) return;
    _updateState(() {
      loading = true;
      error = null;
    });
    try {
      await widget.api.assignStorageRoot(
        '/api/v2/roots/${Uri.encodeComponent(rootID)}/users/$id/storage/$category',
        generation,
      );
      policies[id] = await widget.api.get('/api/v2/users/$id/storage');
    } catch (e) {
      error = userFacingError(e);
    } finally {
      if (mounted) _updateState(() => loading = false);
    }
  }

  Future<void> createSubdirOnDisk(
    int id,
    String rootID,
    int generation,
    String rootName,
  ) async {
    if (loading || !rootsKnown) return;
    var subdir = '';
    var textRevision = 0;
    final entered = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => AlertDialog(
          title: Text('在 $rootName 新建子目录'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                key: ValueKey('subdir-input-$textRevision'),
                initialValue: subdir,
                onChanged: (next) => subdir = next,
                decoration: const InputDecoration(
                  labelText: '子目录名称',
                  hintText: '例如 文档资料 或 photos/家庭相册',
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () async {
                  final picked = await IsleFolderPickerSheet.pickFolder(
                    context,
                    api: widget.api,
                  );
                  if (picked != null && picked.path != '.') {
                    setModalState(() {
                      subdir = picked.path;
                      textRevision++;
                    });
                  }
                },
                icon: const Icon(Icons.folder_open_rounded, size: 16),
                label: const Text('浏览目录树'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, subdir.trim()),
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    if (entered == null || entered.isEmpty || !mounted) return;
    _updateState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.api.send(
        'POST',
        '/api/v2/roots/${Uri.encodeComponent(rootID)}/users/$id/storage',
        query: {'rootGeneration': '$generation'},
        body: {
          'subdirectories': [entered],
        },
      );
      if (result['policy'] is Map<String, dynamic>) {
        policies[id] = result['policy'] as Map<String, dynamic>;
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已在 $rootName 创建子目录：$entered')));
      }
    } catch (e) {
      error = userFacingError(e);
    } finally {
      if (mounted) _updateState(() => loading = false);
    }
  }

  Future<void> switchCategoryRoot(
    int id,
    String username,
    String category,
    String categoryLabel,
    Map<String, dynamic> loc,
  ) async {
    final sourceRootID = loc['rootID']?.toString() ?? '';
    final sourceGen = (loc['rootGeneration'] as num? ?? 0).toInt();
    final targetRoots = roots
        .where((r) => r['online'] == true && r['rootID'] != sourceRootID)
        .toList(growable: false);
    if (loading || !rootsKnown || targetRoots.isEmpty) return;
    var chosenTarget = targetRoots.first;
    final sourceOnline = roots.any(
      (root) => root['rootID'] == sourceRootID && root['online'] == true,
    );
    var mode = sourceOnline ? 'migrate' : 'empty';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => AlertDialog(
          title: Text('更换 $username 的「$categoryLabel」硬盘'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: chosenTarget['rootID']?.toString(),
                    decoration: const InputDecoration(labelText: '选择目标在线硬盘'),
                    items: [
                      for (final r in targetRoots)
                        DropdownMenuItem(
                          value: r['rootID']?.toString(),
                          child: Text(r['name']?.toString() ?? '硬盘'),
                        ),
                    ],
                    onChanged: (next) {
                      for (final r in targetRoots) {
                        if (r['rootID']?.toString() == next) {
                          setModalState(() => chosenTarget = r);
                          break;
                        }
                      }
                    },
                  ),
                  const SizedBox(height: 14),
                  const Text('跨盘处理方式：'),
                  RadioGroup<String>(
                    groupValue: mode,
                    onChanged: (next) {
                      if (next != null) setModalState(() => mode = next);
                    },
                    child: Column(
                      children: [
                        if (sourceOnline) const RadioListTile<String>(
                          contentPadding: EdgeInsets.zero,
                          value: 'migrate',
                          title: Text('复制并核验后删除'),
                          subtitle: Text('核验完成后再次确认，源文件进入可恢复回收站。'),
                        ),
                        if (sourceOnline) const RadioListTile<String>(
                          contentPadding: EdgeInsets.zero,
                          value: 'move',
                          title: Text('直接剪切并切换'),
                          subtitle: Text('一次确认，校验目标后将源文件移入回收站。'),
                        ),
                        const RadioListTile<String>(
                          contentPadding: EdgeInsets.zero,
                          value: 'empty',
                          title: Text('启用空白新目录'),
                          subtitle: Text('新空间从空白开始，旧盘原件保留。'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(mode == 'migrate' ? '开始复制并核验' : '确认切换'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    final random = Random.secure();
    final taskID = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await _runStorageSwitch(id, {
      'taskID': taskID,
      'sourceRootID': sourceRootID,
      'sourceGeneration': sourceGen,
      'targetRootID': chosenTarget['rootID'],
      'targetGeneration': chosenTarget['generation'],
      'categories': [category],
      'mode': mode,
      'phase': 'copy_and_verify',
    });
  }

  Future<void> showLatestStorageSwitch(int id) =>
      _runStorageSwitch(id, {'phase': 'status'});

  Future<void> cancelStorageSwitch(int id, String taskID) async {
    _updateState(() => switchCancellations.remove(id));
    try {
      final result = await widget.api.send(
        'POST',
        '/api/v2/users/$id/storage/switch-root',
        body: {'phase': 'cancel', 'taskID': taskID},
      );
      if (!mounted) return;
      if (!loading) {
        final cancelled = result['phase'] == 'cancelled';
        _updateState(() => switchMessages[id] = cancelled
            ? '换盘任务已取消。'
            : '当前阶段无法取消，请查看最近换盘任务。');
      }
    } catch (e) {
      if (!mounted) return;
      _updateState(() {
        error = userFacingError(e);
        switchCancellations[id] = taskID;
      });
    }
  }

  Future<void> recoverStorageSwitch(int id, String taskID) async {
    final approved = await confirmAction(
      context,
      '重新核验源盘？',
      '程序会重新校验两块盘。只有本任务核验过的源文件会进入可恢复回收站。',
      action: '核验并继续',
      isDestructive: true,
    );
    if (approved && mounted) {
      await _runStorageSwitch(id, {'phase': 'recover_source', 'taskID': taskID});
    }
  }

  Future<void> _runStorageSwitch(int id, Map<String, dynamic> request) async {
    if (loading) return;
    _updateState(() {
      loading = true;
      error = null;
      switchMessages[id] = '正在读取换盘任务…';
    });
    final endpoint = '/api/v2/users/$id/storage/switch-root';
    try {
      var result = await widget.api.send('POST', endpoint, body: request);
      while (mounted) {
        final taskID = result['taskID']?.toString();
        final phase = result['phase'];
        if (taskID == null || taskID.isEmpty) {
          throw const FormatException('换盘任务缺少编号');
        }
        if (phase == 'verified') {
          if (!mounted) return;
          final files = result['verifiedFiles'] ?? 0;
          final shares = result['affectedShares'] ?? 0;
          final bytes = result['copiedBytes'] ?? 0;
          final approved = await confirmAction(
            context,
            '已核验，确认切换硬盘？',
            '已校验 $files 个文件（$bytes 字节），涉及 $shares 项分享。确认后切换目录，源文件进入可恢复回收站。',
            action: '确认切换并回收源文件',
            isDestructive: true,
          );
          if (!mounted) return;
          if (!approved) {
            _updateState(() {
              switchMessages[id] = '已核验，等待确认。可从最近换盘任务继续。';
              switchCancellations[id] = taskID;
            });
            return;
          }
          result = await widget.api.send('POST', endpoint, body: {
            'phase': 'confirm_cleanup',
            'taskID': taskID,
          });
          continue;
        }
        if (phase == 'queued' || phase == 'copying' || phase == 'committing') {
          _updateState(() {
            if (phase == 'committing') {
              switchCancellations.remove(id);
            } else {
              switchCancellations[id] = taskID;
            }
            switchMessages[id] = switch (phase) {
              'copying' => '正在复制并核验，已复制 ${result['copiedBytes'] ?? 0} 字节…',
              'committing' => '正在切换空间并核对源盘…',
              _ => '换盘任务已排队…',
            };
          });
          await Future<void>.delayed(const Duration(seconds: 1));
          if (!mounted) return;
          result = await widget.api.send('POST', endpoint, body: {
            'phase': 'status',
            'taskID': taskID,
          });
          continue;
        }
        final policy = await widget.api.get('/api/v2/users/$id/storage');
        if (!mounted) return;
        _updateState(() {
          policies[id] = policy;
          switchCancellations.remove(id);
          if (phase == 'source_pending') {
            switchRecoveries[id] = taskID;
          } else {
            switchRecoveries.remove(id);
          }
          switchMessages[id] = switch (phase) {
            'completed' when result['mode'] == 'empty' => '已启用空白新目录，旧盘原件保留。',
            'completed' when result['mode'] == 'copy' => '已复制并切换，旧盘原件保留。',
            'completed' => '已切换到目标盘，源文件可在旧盘的回收站恢复。',
            'source_pending' => '空间已切换，源文件待处理。请在 Mac 管理端核对旧盘和回收站。',
            'interrupted' => '任务中断。请检查两块硬盘和任务结果后再操作。',
            'cancelled' => '换盘任务已取消。',
            _ => storageSwitchError(result['error']?.toString()),
          };
        });
        return;
      }
    } catch (e) {
      if (mounted) {
        _updateState(() {
          if (e is LightIsleApiException && e.code == 'storage_switch_task_not_found') {
            switchMessages[id] = '该成员还没有换盘任务。';
          } else {
            error = userFacingError(e);
            switchMessages[id] = '可查看最近换盘任务核对结果。';
          }
        });
      }
    } finally {
      if (mounted) _updateState(() => loading = false);
    }
  }

  String storageSwitchError(String? code) => switch (code) {
    'storage_folder_conflict' => '目标目录已有内容，或源对象已变化。请先核对两块硬盘。',
    'storage_migration_verification_failed' => '文件核验失败，请核对源盘和目标盘。',
    'storage_switch_disk_full' => '目标盘可用空间不足。',
    'storage_quota_exceeded' => '目标盘的个人空间额度不足。',
    'storage_accounting_conflict' => '存在未结束的写入或额度预占，请完成相关任务后再试。',
    'storage_switch_unsupported_entry' => '目录内含链接或其他无法安全移动的项目。',
    'storage_switch_size_limit' => '目录超过本次可安全切换的容量或文件数量限制。',
    'root_generation_changed' => '硬盘身份发生变化，请检查连接后刷新。',
    'root_unavailable' => '所需硬盘当前离线，请检查连接。',
    _ => '换盘失败。请检查目标盘、目录权限和任务状态。',
  };

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
    _updateState(() {
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
      if (mounted) _updateState(() => loading = false);
    }
  }
}
