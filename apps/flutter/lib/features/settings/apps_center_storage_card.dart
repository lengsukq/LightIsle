part of 'apps_center_page.dart';

extension _AppsCenterStorageCard on _AppsCenterPageState {
  Widget _buildStorageLocationsCard(BuildContext context) {
    final storage = _appStorage;
    if (storage == null) return const SizedBox.shrink();
    final theme = Theme.of(context), colors = theme.colorScheme;
    final locations = objectList(storage['locations']);
    final volumes = objectList(storage['availableVolumes']);
    final maxLocations = (storage['maxLocations'] as num?)?.toInt() ?? 2;
    Map<String, dynamic>? internalLoc;
    Map<String, dynamic>? externalLoc;
    for (final loc in locations) {
      if (loc['kind'] == 'external') {
        externalLoc = loc;
      } else {
        internalLoc ??= loc;
      }
    }

    return IsleSurface(
      key: const ValueKey('appStorageLocationsCard'),
      radius: IsleRadius.card,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.storage_rounded, size: 20, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '应用数据存储位置',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IsleStatusBadge(
                label: '已配置 ${locations.length}/$maxLocations（1 内置盘 + 1 其他盘）',
                color: colors.primary,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '可选择应用中心轻应用代码（plugins/）和业务数据（plugin-data/）的存放位置，仅支持 1 个内置盘与最多 1 个其他盘。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          if (internalLoc != null)
            _buildStorageSlotTile(
              context,
              loc: internalLoc,
              slotBadge: '内置盘 1/1',
              isExternal: false,
              volumes: volumes,
            ),
          const SizedBox(height: 10),
          if (externalLoc != null)
            _buildStorageSlotTile(
              context,
              loc: externalLoc,
              slotBadge: '其他盘 1/1',
              isExternal: true,
              volumes: volumes,
            )
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: colors.outlineVariant.withValues(alpha: 0.7),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '外置 / 其他盘位置（可选）',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      IsleStatusBadge(
                        label: '其他盘 0/1',
                        color: colors.secondary,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '可绑定 1 个 Mac 外接磁盘目录下的子文件夹（例如 /Volumes/磁盘名/LightIsleApps）。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    key: const ValueKey('addExternalAppStorageButton'),
                    onPressed: _busy
                        ? null
                        : () => _openStoragePathDialog(
                            kind: 'external',
                            action: 'add',
                            volumes: volumes,
                          ),
                    icon: const Icon(Icons.add_rounded, size: 16),
                    label: const Text('添加其他盘位置'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStorageSlotTile(
    BuildContext context, {
    required Map<String, dynamic> loc,
    required String slotBadge,
    required bool isExternal,
    required List<Map<String, dynamic>> volumes,
  }) {
    final theme = Theme.of(context), colors = theme.colorScheme;
    final online = loc['online'] == true;
    final writable = loc['writable'] == true;
    final isDefault = loc['isDefault'] == true;
    final isCustomPath = loc['isCustomPath'] == true;
    final appCount = (loc['appCount'] as num?)?.toInt() ?? 0;
    final freeBytes = (loc['freeBytes'] as num?)?.toInt() ?? 0;
    final error = loc['error']?.toString().trim() ?? '';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDefault
              ? colors.primary.withValues(alpha: 0.55)
              : colors.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                loc['name']?.toString() ?? (isExternal ? '外置其他盘' : 'Mac 内置盘'),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              IsleStatusBadge(label: slotBadge, color: colors.secondary),
              if (isDefault)
                IsleStatusBadge(label: '默认位置', color: colors.primary),
              IsleStatusBadge(
                label: online ? (writable ? '可用' : '只读') : '离线',
                color: online && writable
                    ? const Color(0xFF16A34A)
                    : const Color(0xFFD97706),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            loc['path']?.toString() ?? '',
            style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            '已装 $appCount 个应用${freeBytes > 0 ? ' · 剩余 ${_formatStorageBytes(freeBytes)}' : ''}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          if (error.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              error,
              style: TextStyle(
                fontSize: 12,
                color: colors.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!isDefault)
                OutlinedButton(
                  onPressed: _busy || !online || !writable
                      ? null
                      : () => _mutateAppStorage({
                          'action': 'set_default',
                          'defaultLocationId': isExternal
                              ? 'external'
                              : 'internal',
                        }),
                  child: const Text('设为默认'),
                ),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _openStoragePathDialog(
                        kind: isExternal ? 'external' : 'internal',
                        action: 'set',
                        initialPath: loc['path']?.toString() ?? '',
                        initialName: loc['name']?.toString() ?? '',
                        volumes: volumes,
                      ),
                child: Text(isExternal ? '更换目录' : '修改路径'),
              ),
              if (!isExternal && isCustomPath)
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _mutateAppStorage({'action': 'reset_internal'}),
                  child: const Text('恢复默认'),
                ),
              if (isExternal)
                OutlinedButton(
                  key: const ValueKey('removeExternalAppStorageButton'),
                  onPressed: _busy
                      ? null
                      : () => _mutateAppStorage({'action': 'remove_external'}),
                  child: const Text('移除登记'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openStoragePathDialog({
    required String kind,
    required String action,
    String initialPath = '',
    String initialName = '',
    List<Map<String, dynamic>> volumes = const [],
  }) async {
    final pathCtl = TextEditingController(
      text: initialPath.isNotEmpty
          ? initialPath
          : (kind == 'external' && volumes.isNotEmpty
                ? (volumes.first['suggestedPath']?.toString() ?? '')
                : ''),
    );
    final nameCtl = TextEditingController(
      text: initialName.isNotEmpty
          ? initialName
          : (kind == 'external' && volumes.isNotEmpty
                ? (volumes.first['name']?.toString() ?? '')
                : ''),
    );
    var setDefault = false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(
            kind == 'external'
                ? (action == 'add' ? '添加其他盘应用存储位置' : '更换其他盘位置')
                : '修改 Mac 内置盘应用目录',
          ),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (kind == 'external' && volumes.isNotEmpty) ...[
                  const Text('已连接磁盘卷（点击快速填入）：', style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final vol in volumes)
                        ActionChip(
                          label: Text(vol['name']?.toString() ?? ''),
                          onPressed: vol['readOnly'] == true
                              ? null
                              : () {
                                  pathCtl.text =
                                      vol['suggestedPath']?.toString() ?? '';
                                  if (nameCtl.text.trim().isEmpty) {
                                    nameCtl.text =
                                        vol['name']?.toString() ?? '';
                                  }
                                },
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],
                TextField(
                  key: const ValueKey('appStoragePathField'),
                  controller: pathCtl,
                  decoration: InputDecoration(
                    labelText: 'Mac 本机目录路径',
                    hintText: kind == 'external'
                        ? '/Volumes/MyDisk/LightIsleApps'
                        : '/Users/name/LightIsleApps',
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: nameCtl,
                  decoration: InputDecoration(
                    labelText: '显示名称（可选）',
                    hintText: kind == 'external' ? '外置扩展盘' : 'Mac 内置盘',
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 6),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: setDefault,
                  onChanged: (v) => setDialogState(() => setDefault = v == true),
                  title: const Text('同时设为默认安装位置'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('confirmAppStorageDialogButton'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('保存并生效'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    final trimmedPath = pathCtl.text.trim();
    if (trimmedPath.isEmpty) return;
    await _mutateAppStorage({
      'action': action,
      'kind': kind,
      'path': trimmedPath,
      if (nameCtl.text.trim().isNotEmpty) 'name': nameCtl.text.trim(),
      'setDefault': setDefault,
    });
  }

  String _formatStorageBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var val = bytes.toDouble();
    var idx = 0;
    while (val >= 1024 && idx < units.length - 1) {
      val /= 1024;
      idx++;
    }
    return '${idx <= 1 || val >= 100 ? val.round() : val.toStringAsFixed(1)} ${units[idx]}';
  }
}
