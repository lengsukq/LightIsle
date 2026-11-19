import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/isle_gallery_layout.dart';
import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';

class SmbSharePoint {
  const SmbSharePoint({
    required this.recordName,
    required this.smbName,
    required this.path,
    required this.shared,
    required this.guestAccess,
    required this.readOnly,
    required this.sealed,
    required this.rootId,
    required this.rootName,
    required this.exposesPersonalDirs,
    required this.pathExists,
  });

  final String recordName;
  final String smbName;
  final String path;
  final bool shared;
  final bool guestAccess;
  final bool readOnly;
  final bool sealed;
  final String? rootId;
  final String? rootName;
  final bool exposesPersonalDirs;
  final bool pathExists;

  factory SmbSharePoint.fromJson(Map<String, dynamic> json) => SmbSharePoint(
    recordName: json['recordName']?.toString() ?? '',
    smbName: json['smbName']?.toString() ?? '',
    path: json['path']?.toString() ?? '',
    shared: json['shared'] == true,
    guestAccess: json['guestAccess'] == true,
    readOnly: json['readOnly'] == true,
    sealed: json['sealed'] == true,
    rootId: json['rootId']?.toString(),
    rootName: json['rootName']?.toString(),
    exposesPersonalDirs: json['exposesPersonalDirs'] == true,
    pathExists: json['pathExists'] != false,
  );
}

class SmbCandidateRoot {
  const SmbCandidateRoot({
    required this.rootId,
    required this.name,
    required this.path,
    required this.online,
    required this.subdirectories,
  });

  final String rootId;
  final String name;
  final String path;
  final bool online;
  final List<String> subdirectories;

  factory SmbCandidateRoot.fromJson(Map<String, dynamic> json) =>
      SmbCandidateRoot(
        rootId: json['rootId']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        path: json['path']?.toString() ?? '',
        online: json['online'] == true,
        subdirectories: (json['subdirectories'] is List)
            ? (json['subdirectories'] as List)
                  .map((e) => e.toString())
                  .where((s) => s.isNotEmpty)
                  .toList()
            : const [],
      );
}

class AdminSmbPage extends StatefulWidget {
  const AdminSmbPage({super.key, required this.api});

  final LightIsleApi api;

  @override
  State<AdminSmbPage> createState() => _AdminSmbPageState();
}

class _AdminSmbPageState extends State<AdminSmbPage> {
  bool _loading = false;
  bool _busy = false;
  bool _serviceEnabled = false;
  String _listeningState = 'unknown';
  bool _remoteManageReady = false;
  String _computerName = '';
  String _bonjourUrl = '';
  String _lanUrl = '';
  List<SmbSharePoint> _shares = const [];
  List<SmbCandidateRoot> _roots = const [];
  String? _error;
  String? _notice;

  String _selectedRootId = '';
  String _selectedSubpath = '';
  final TextEditingController _nameCtrl = TextEditingController();
  bool _newReadOnly = false;
  bool _newGuestAccess = false;
  bool _newSealed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  List<SmbCandidateRoot> get _onlineRoots =>
      _roots.where((r) => r.online).toList();

  SmbCandidateRoot? get _currentRoot {
    final online = _onlineRoots;
    if (online.isEmpty) return null;
    for (final r in online) {
      if (r.rootId == _selectedRootId) return r;
    }
    return online.first;
  }

  bool get _selectionExposesPersonal {
    if (_currentRoot == null) return false;
    final sub = _selectedSubpath.trim();
    return sub.isEmpty || sub == 'Users' || sub.startsWith('Users/');
  }

  void _applyStatus(Map<String, dynamic> data) {
    _serviceEnabled = data['serviceEnabled'] == true;
    _listeningState = data['listeningState']?.toString() ?? 'unknown';
    _remoteManageReady = data['remoteManageReady'] == true;
    _computerName = data['computerName']?.toString() ?? '';
    _bonjourUrl = data['bonjourUrl']?.toString() ?? '';
    _lanUrl = data['lanUrl']?.toString() ?? '';
    _shares = objectList(data['shares']).map(SmbSharePoint.fromJson).toList();
    _roots = objectList(
      data['candidateRoots'],
    ).map(SmbCandidateRoot.fromJson).toList();
    final online = _onlineRoots;
    if (online.isEmpty) {
      _selectedRootId = '';
      _selectedSubpath = '';
    } else if (!online.any((r) => r.rootId == _selectedRootId)) {
      _selectedRootId = online.first.rootId;
      _selectedSubpath = '';
    }
  }

  Future<void> _refresh() async {
    if (_loading || _busy) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.api.get('/api/v2/admin/smb');
      if (!mounted) return;
      setState(() => _applyStatus(data));
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleService(bool enabled) async {
    if (_busy || !_remoteManageReady) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final data = await widget.api.send(
        'POST',
        '/api/v2/admin/smb/service',
        body: {'enabled': enabled},
      );
      if (!mounted) return;
      setState(() {
        _applyStatus(data);
        _notice = enabled ? '已开启 macOS SMB 文件共享服务。' : '已关闭 macOS SMB 文件共享服务。';
      });
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addShare() async {
    final root = _currentRoot;
    if (_busy || !_remoteManageReady || root == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final data = await widget.api.send(
        'POST',
        '/api/v2/admin/smb/shares',
        body: {
          'rootId': root.rootId,
          'subpath': _selectedSubpath,
          'smbName': _nameCtrl.text.trim(),
          'readOnly': _newReadOnly,
          'guestAccess': _newGuestAccess,
          'sealed': _newSealed,
        },
      );
      if (!mounted) return;
      setState(() {
        _nameCtrl.clear();
        _applyStatus(data);
        _notice = '已添加 SMB 共享文件夹。';
      });
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _updateShare(
    SmbSharePoint share, {
    bool? shared,
    bool? readOnly,
    bool? guestAccess,
    bool? sealed,
  }) async {
    if (_busy || !_remoteManageReady) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final data = await widget.api.send(
        'PATCH',
        '/api/v2/admin/smb/shares/${Uri.encodeComponent(share.recordName)}',
        body: {
          'smbName': share.smbName,
          'shared': shared ?? share.shared,
          'readOnly': readOnly ?? share.readOnly,
          'guestAccess': guestAccess ?? share.guestAccess,
          'sealed': sealed ?? share.sealed,
        },
      );
      if (!mounted) return;
      setState(() {
        _applyStatus(data);
        _notice = '已更新「${share.smbName}」共享设置。';
      });
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeShare(SmbSharePoint share) async {
    if (_busy || !_remoteManageReady) return;
    final confirmed = await confirmAction(
      context,
      '移除 SMB 共享「${share.smbName}」',
      '路径：${share.path}\n\n此操作仅从 macOS 文件共享列表中取消登记，绝不会删除硬盘上的任何原始文件。确认移除？',
      action: '移除共享',
      isDestructive: true,
    );
    if (!confirmed || !mounted || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final data = await widget.api.send(
        'DELETE',
        '/api/v2/admin/smb/shares/${Uri.encodeComponent(share.recordName)}',
      );
      if (!mounted) return;
      setState(() {
        _applyStatus(data);
        _notice = '已移除「${share.smbName}」共享。';
      });
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _copy(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已复制$label：$text')));
  }

  @override
  Widget build(BuildContext context) {
    final canControl = !_busy && _remoteManageReady;
    final palette = IslePalette.of(context);
    final amber = palette['brandAmber'];
    final mineral = palette['brandBlue'];
    final sage = palette['brandSage'];
    final statusText = _serviceEnabled
        ? (_listeningState == 'listening' ? '已开启' : '已开启 · 待监听')
        : '未开启';

    final leftConfigColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IsleGroupCard(
          margin: EdgeInsets.zero,
          children: [
            IsleGroupTile(
              icon: Icons.dns_rounded,
              iconBgColor: _serviceEnabled ? sage : amber,
              title: 'SMB 文件共享服务',
              subtitle: _computerName.isNotEmpty
                  ? '$statusText · $_computerName'
                  : statusText,
              trailing: Switch.adaptive(
                key: const ValueKey('smb-service-switch'),
                value: _serviceEnabled,
                onChanged: canControl
                    ? (v) => unawaited(_toggleService(v))
                    : null,
              ),
            ),
            if (_bonjourUrl.isNotEmpty)
              IsleGroupTile(
                icon: Icons.lan_rounded,
                iconBgColor: mineral,
                title: '局域网主机地址',
                subtitle: _bonjourUrl,
                trailing: const Icon(Icons.copy_rounded, size: 16),
                onTap: () => _copy(_bonjourUrl, '主机地址'),
              ),
            if (_lanUrl.isNotEmpty)
              IsleGroupTile(
                icon: Icons.wifi_rounded,
                iconBgColor: amber,
                title: '局域网 IP 地址',
                subtitle: _lanUrl,
                trailing: const Icon(Icons.copy_rounded, size: 16),
                onTap: () => _copy(_lanUrl, 'IP 地址'),
              ),
          ],
        ),
        const SizedBox(height: 14),
        _buildAddShareCard(context, canControl, palette),
      ],
    );

    final rightSharesColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IsleSectionHeader(
          title: '已共享文件夹 (${_shares.length})',
          accentColor: mineral,
        ),
        if (_loading && _shares.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_shares.isEmpty)
          const IsleEmptyStateCard(
            '当前没有配置任何 SMB 共享文件夹。',
            icon: Icons.folder_off_outlined,
          )
        else
          for (final share in _shares)
            _buildShareCard(context, share, canControl, palette),
      ],
    );

    return Scaffold(
      appBar: IsleAppBar(
        title: const Text('Mac 文件共享 (SMB)'),
        actions: [
          IconButton(
            tooltip: '刷新状态',
            onPressed: (_loading || _busy) ? null : () => unawaited(_refresh()),
            icon: const Icon(Icons.refresh_rounded),
          ),
          IsleHelpButton(
            title: 'SMB 共享与权限说明',
            accentColor: amber,
            items: const [
              IsleHelpItem(
                title: 'macOS 原生文件共享联动',
                body: '直接管理宿主 Mac 系统级 SMB 共享列表，局域网设备使用 Mac 系统账号或访客身份挂载；移除共享仅取消登记，绝不删除磁盘原文件。',
              ),
              IsleHelpItem(
                title: '私人目录边界提醒',
                body: '若将包含 Users 目录的整盘设为 SMB 共享，具备该盘挂载权限的局域网用户将能直接访问成员私人目录，建议按子目录精细共享。',
              ),
            ],
          ),
        ],
      ),
      body: IsleListView(
        maxWidth: IsleLayout.workbenchMaxWidth,
        children: [
          if (!_loading && !_remoteManageReady)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Notice(
                '请先在 Mac 管理端「网络与连接 → Mac 文件共享」开启一次免密管理授权。',
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Notice(_error!, error: true),
            ),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Notice(_notice!),
            ),
          IsleWorkbenchSplit(
            breakpoint: 880,
            primaryFlex: 5,
            secondaryFlex: 6,
            primary: leftConfigColumn,
            secondary: rightSharesColumn,
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildAddShareCard(
    BuildContext context,
    bool canControl,
    IslePalette palette,
  ) {
    final online = _onlineRoots;
    final current = _currentRoot;
    final amber = palette['brandAmber'];
    return IsleSurface(
      radius: IsleRadius.card,
      tint: amber,
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IsleSquircleBadge(
                icon: Icons.create_new_folder_rounded,
                color: amber,
                size: 36,
                iconSize: 18,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  '新增共享文件夹',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (online.isEmpty)
            const Text(
              '暂无在线的 NAS 存储盘。',
              style: TextStyle(fontSize: 12),
            )
          else ...[
            DropdownButtonFormField<String>(
              key: const ValueKey('smb-root-dropdown'),
              initialValue: current?.rootId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'NAS 存储盘',
                isDense: true,
              ),
              items: [
                for (final r in online)
                  DropdownMenuItem(value: r.rootId, child: Text(r.name)),
              ],
              onChanged: canControl
                  ? (v) {
                      if (v == null) return;
                      setState(() {
                        _selectedRootId = v;
                        _selectedSubpath = '';
                      });
                    }
                  : null,
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              key: const ValueKey('smb-subpath-dropdown'),
              initialValue: _selectedSubpath,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '共享目录范围',
                isDense: true,
              ),
              items: [
                const DropdownMenuItem(
                  value: '',
                  child: Text('整块存储根目录（含全部子目录）'),
                ),
                if (current != null)
                  for (final sub in current.subdirectories)
                    DropdownMenuItem(value: sub, child: Text('子目录：$sub')),
              ],
              onChanged: canControl
                  ? (v) => setState(() => _selectedSubpath = v ?? '')
                  : null,
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('smb-name-input'),
              controller: _nameCtrl,
              enabled: canControl,
              decoration: const InputDecoration(
                labelText: '自定义共享名称（可选）',
                isDense: true,
              ),
            ),
            if (_selectionExposesPersonal) ...[
              const SizedBox(height: 8),
              Text(
                '包含 Users 目录时，局域网 SMB 用户可直接访问成员私人目录。',
                style: TextStyle(fontSize: 12, color: amber),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 4,
              children: [
                FilterChip(
                  visualDensity: VisualDensity.compact,
                  label: const Text('仅只读'),
                  selected: _newReadOnly,
                  onSelected: canControl
                      ? (v) => setState(() => _newReadOnly = v)
                      : null,
                ),
                FilterChip(
                  visualDensity: VisualDensity.compact,
                  label: const Text('允许访客'),
                  selected: _newGuestAccess,
                  onSelected: canControl
                      ? (v) => setState(() => _newGuestAccess = v)
                      : null,
                ),
                FilterChip(
                  visualDensity: VisualDensity.compact,
                  label: const Text('SMB3 加密'),
                  selected: _newSealed,
                  onSelected: canControl
                      ? (v) => setState(() => _newSealed = v)
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                key: const ValueKey('smb-add-button'),
                onPressed: canControl ? () => unawaited(_addShare()) : null,
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('添加到 SMB 共享'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildShareCard(
    BuildContext context,
    SmbSharePoint share,
    bool canControl,
    IslePalette palette,
  ) {
    final canManage =
        canControl && (_roots.isEmpty || (share.rootId?.isNotEmpty ?? false));
    final mineral = palette['brandBlue'];
    final amber = palette['brandAmber'];
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return IsleSurface(
      radius: IsleRadius.card,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IsleSquircleBadge(
                icon: Icons.folder_shared_rounded,
                color: share.shared ? mineral : muted,
                size: 36,
                iconSize: 19,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          share.smbName,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (share.rootName != null &&
                            share.rootName!.isNotEmpty)
                          IsleBadgePill(
                            label: 'NAS · ${share.rootName}',
                            color: mineral,
                          )
                        else if (_roots.isNotEmpty &&
                            (share.rootId?.isEmpty ?? true))
                          IsleBadgePill(
                            label: '本机其他共享（仅 Mac 端管理）',
                            color: muted,
                          ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    IsleCodePill(share.path),
                    if (share.exposesPersonalDirs)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '包含 Users 私人目录',
                          style: TextStyle(fontSize: 11, color: amber),
                        ),
                      ),
                  ],
                ),
              ),
              TextButton.icon(
                key: ValueKey('smb-remove-${share.recordName}'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: canManage
                    ? () => unawaited(_removeShare(share))
                    : null,
                icon: const Icon(Icons.delete_outline_rounded, size: 16),
                label: const Text('移除'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              FilterChip(
                visualDensity: VisualDensity.compact,
                label: const Text('启用共享'),
                selected: share.shared,
                onSelected: canManage
                    ? (v) => unawaited(_updateShare(share, shared: v))
                    : null,
              ),
              FilterChip(
                visualDensity: VisualDensity.compact,
                label: const Text('仅只读'),
                selected: share.readOnly,
                onSelected: canManage
                    ? (v) => unawaited(_updateShare(share, readOnly: v))
                    : null,
              ),
              FilterChip(
                visualDensity: VisualDensity.compact,
                label: const Text('允许访客'),
                selected: share.guestAccess,
                onSelected: canManage
                    ? (v) => unawaited(_updateShare(share, guestAccess: v))
                    : null,
              ),
              FilterChip(
                visualDensity: VisualDensity.compact,
                label: const Text('SMB3 加密'),
                selected: share.sealed,
                onSelected: canManage
                    ? (v) => unawaited(_updateShare(share, sealed: v))
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
