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
    List<Map<String, dynamic>> currentLocations,
  ) async {
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
    final parsedGiB = int.tryParse(quotaText.trim());
    if (parsedGiB == null || parsedGiB < 0 || parsedGiB > 1048576) {
      _updateState(() => error = '配额范围为 0–1048576 GiB');
      return;
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
    final entered = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('在 $rootName 新建子目录'),
        content: TextFormField(
          onChanged: (next) => subdir = next,
          decoration: const InputDecoration(
            labelText: '子目录名称',
            hintText: '例如 文档资料 或 photos/家庭相册',
          ),
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
