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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final entered = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => AlertDialog(
          shape: IsleShapes.card(
            side: BorderSide(
              color: IsleGlass.rimBorderColor(isDark),
              width: 1.0,
            ),
          ),
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
                decoration: const InputDecoration(
                  helperText: '0 表示以后不允许新增数据',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final preset in const [50, 100, 200, 500, 1024, 0])
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      side: BorderSide(
                        color: IsleGlass.rimBorderColor(isDark),
                        width: 1.0,
                      ),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => AlertDialog(
          shape: IsleShapes.card(
            side: BorderSide(
              color: IsleGlass.rimBorderColor(isDark),
              width: 1.0,
            ),
          ),
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
    final generation = _asStorageInt(chosenRoot['generation']);
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final entered = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => AlertDialog(
          shape: IsleShapes.card(
            side: BorderSide(
              color: IsleGlass.rimBorderColor(isDark),
              width: 1.0,
            ),
          ),
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
                  final targetRoot = LightIsleRoot(
                    id: rootID,
                    generation: generation,
                    name: rootName,
                    online: true,
                  );
                  final snap = widget.api.sessionSnapshot;
                  final prevRoot = widget.api.selectedRoot;
                  final LightIsleApi pickerApi;
                  var closePickerApi = false;
                  if (snap != null) {
                    pickerApi = LightIsleApi.fromSessionSnapshot(snap)
                      ..selectRoot(targetRoot);
                    closePickerApi = true;
                  } else {
                    pickerApi = widget.api..selectRoot(targetRoot);
                  }
                  final userPrefix = 'Users/u$id/';
                  try {
                    final picked = await IsleFolderPickerSheet.pickFolder(
                      context,
                      api: pickerApi,
                      initialSourcePath: '${userPrefix}files/.probe',
                    );
                    if (picked != null && picked.path != '.' && picked.path != 'Users/u$id') {
                      final rel = picked.path.startsWith(userPrefix)
                          ? picked.path.substring(userPrefix.length)
                          : picked.path;
                      if (rel.isNotEmpty) {
                        setModalState(() {
                          subdir = rel;
                          textRevision++;
                        });
                      }
                    }
                  } finally {
                    if (closePickerApi) {
                      pickerApi.close();
                    } else {
                      widget.api.selectRoot(prevRoot);
                    }
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

  Future<void> assign(int id, String category) async {
    if (loading ||
        !rootsKnown ||
        !roots.any((root) => root['online'] == true)) {
      return;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final root = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      shape: IsleShapes.sheet(
        side: BorderSide(color: IsleGlass.rimBorderColor(isDark), width: 1.0),
      ),
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .65,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 10),
              child: Text(
                '为用户选择存储硬盘',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            IsleGroupCard(
              margin: EdgeInsets.zero,
              children: [
                for (final r in roots.where((root) => root['online'] == true))
                  ListTile(
                    dense: true,
                    leading: IsleSquircleBadge(
                      icon: Icons.storage_rounded,
                      color: Theme.of(context).colorScheme.primary,
                      size: 32,
                      iconSize: 17,
                    ),
                    title: Text(r['name']?.toString() ?? '硬盘'),
                    subtitle: Text(_physicalFreeLabel(r)),
                    trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                    onTap: () => Navigator.pop(context, r),
                  ),
              ],
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
        _asStorageInt(root['generation']),
      );
      policies[id] = await widget.api.get('/api/v2/users/$id/storage');
    } catch (e) {
      error = userFacingError(e);
    } finally {
      if (mounted) _updateState(() => loading = false);
    }
  }

  Widget _buildUserRootQuotaCard(
    BuildContext context, {
    required int userId,
    required String username,
    required Map<String, dynamic> quota,
    required List<Map<String, dynamic>> locations,
    required bool isDark,
  }) {
    final rootID = quota['rootID']?.toString() ?? '';
    final generation = _asStorageInt(quota['rootGeneration']);
    Map<String, dynamic>? root;
    for (final candidate in roots) {
      if (candidate['rootID'] == rootID) {
        root = candidate;
        break;
      }
    }
    final rootName = root?['name']?.toString() ?? '原绑定硬盘';
    final limit = quota['quotaBytes'];
    final used = _asStorageDouble(quota['accountedBytes']);
    final reserved = _asStorageDouble(quota['reservedBytes']);
    final max = limit == null ? 0.0 : _asStorageDouble(limit);
    final hasLocationsOnDisk = locations.any(
      (loc) =>
          loc['rootID'] == rootID &&
          _asStorageInt(loc['rootGeneration']) == generation,
    );
    final active =
        hasLocationsOnDisk ||
        (root != null && _asStorageInt(root['generation'], -1) == generation);
    final unassignedCats = _StoragePageState.categories.entries
        .where((e) => !locations.any((loc) => loc['category'] == e.key))
        .toList(growable: false);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : Theme.of(context).colorScheme.surface,
        borderRadius: IsleRadius.brSm,
        border: Border.all(
          color: IsleGlass.rimBorderColor(isDark),
          width: 1.0,
        ),
      ),
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
                      : !hasLocationsOnDisk
                      ? ' · 已预留配额'
                      : ''}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (max > 0) ...[
                const SizedBox(width: 8),
                StorageCompactDonut(
                  fraction: (used + reserved) / max,
                  color: ((used + reserved) / max) >= 0.92
                      ? const Color(0xffc93b3b)
                      : ((used + reserved) / max) >= 0.8
                      ? const Color(0xffc27816)
                      : IslePalette.of(context)['brandBlue'],
                  semanticsLabel:
                      '$rootName 配额已用 ${(((used + reserved) / max).clamp(0.0, 1.0) * 100).round()}%',
                ),
              ],
              if (widget.isAdmin && rootsKnown && active && limit is num)
                TextButton(
                  onPressed: loading
                      ? null
                      : () => editQuota(
                          userId,
                          rootID,
                          generation,
                          limit,
                          rootName,
                        ),
                  child: const Text('调整额度'),
                ),
            ],
          ),
          if (max > 0) ...[
            const SizedBox(height: 6),
            StorageQuotaSegmentedBar(used: used, reserved: reserved, max: max),
          ],
          const SizedBox(height: 6),
          Text(
            '已入账 ${(used / (1 << 30)).toStringAsFixed(2)} GiB'
            ' · 预占 ${(reserved / (1 << 30)).toStringAsFixed(2)} GiB'
            '${max > 0 ? ' · 额度剩余 ${((max - used - reserved).clamp(0.0, max) / (1 << 30)).toStringAsFixed(2)} GiB' : ''}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (widget.isAdmin &&
              rootsKnown &&
              active &&
              root?['online'] == true &&
              (unassignedCats.isNotEmpty || hasLocationsOnDisk)) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final cat in unassignedCats)
                  ActionChip(
                    label: Text('+ 添加${cat.value}目录'),
                    onPressed: loading
                        ? null
                        : () => addCategoryOnDisk(
                            userId,
                            rootID,
                            generation,
                            cat.key,
                          ),
                  ),
                if (hasLocationsOnDisk)
                  ActionChip(
                    label: const Text('+ 新建子目录'),
                    onPressed: loading
                        ? null
                        : () => createSubdirOnDisk(
                            userId,
                            rootID,
                            generation,
                            rootName,
                          ),
                  ),
                if (hasLocationsOnDisk)
                  ActionChip(
                    avatar: const Icon(Icons.swap_horiz_rounded, size: 15),
                    label: const Text('迁移到新目录…'),
                    onPressed: loading
                        ? null
                        : () {
                            final catsOnDisk = locations
                                .where(
                                  (loc) =>
                                      loc['rootID'] == rootID &&
                                      _asStorageInt(loc['rootGeneration']) ==
                                          generation,
                                )
                                .map((loc) => loc['category']?.toString() ?? '')
                                .where((c) => c.isNotEmpty)
                                .toSet();
                            switchUserRootCategories(
                              userId,
                              username,
                              rootID,
                              generation,
                              rootName,
                              catsOnDisk,
                            );
                          },
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildUserCategoryTile({
    required int userId,
    required String username,
    required String categoryKey,
    required String categoryLabel,
    required List<Map<String, dynamic>> locations,
    required Map<String, (IconData, Color)> categoryMeta,
    required bool isDark,
  }) {
    Map<String, dynamic>? loc;
    for (final row in locations) {
      if (row['category'] == categoryKey) {
        loc = row;
        break;
      }
    }
    final meta =
        categoryMeta[categoryKey] ??
        (Icons.inventory_2_outlined, const Color(0xff64748b));
    final catIcon = meta.$1;
    final catColor = meta.$2;
    final Widget? action =
        widget.isAdmin &&
            loc != null &&
            rootsKnown &&
            !roots.any((root) => root['rootID'] == loc!['rootID'])
        ? TextButton(
            onPressed: loading
                ? null
                : () => abandonCategory(userId, categoryKey),
            child: const Text('放弃旧空间并重建'),
          )
        : widget.isAdmin && loc != null && rootsKnown
        ? TextButton(
            onPressed: loading
                ? null
                : () => switchCategoryRoot(
                    userId,
                    username,
                    categoryKey,
                    categoryLabel,
                    loc!,
                  ),
            child: const Text('更换硬盘'),
          )
        : widget.isAdmin && loc == null
        ? OutlinedButton(
            onPressed:
                loading ||
                    !rootsKnown ||
                    !roots.any((root) => root['online'] == true)
                ? null
                : () => assign(userId, categoryKey),
            child: const Text('分配'),
          )
        : null;
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
        categoryLabel,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
      subtitle: Text(loc == null ? '尚未分配' : label(loc)),
      trailing: action,
    );
  }
}
