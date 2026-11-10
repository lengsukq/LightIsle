import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'account_security_page.dart';

enum AccountCreationPhase {
  editing,
  creatingAccount,
  allocatingStorage,
  allocationFailed,
}

class NewAccountDialogResult {
  const NewAccountDialogResult({
    required this.accountCreated,
    required this.storageAllocated,
    this.warningMessage,
  });

  final bool accountCreated;
  final bool storageAllocated;
  final String? warningMessage;
}

class NewAccountDialog extends StatefulWidget {
  const NewAccountDialog({super.key, required this.api});

  final LightIsleApi api;

  @override
  State<NewAccountDialog> createState() => _NewAccountDialogState();
}

class _NewAccountDialogState extends State<NewAccountDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _quota = TextEditingController(text: '100');

  AccountCreationPhase _phase = AccountCreationPhase.editing;
  String _role = 'member';
  int? _createdUserId;
  String? _error;
  bool _rootsLoaded = false;
  List<Map<String, dynamic>> _onlineRoots = [];
  Map<String, dynamic>? _selectedRoot;
  final Set<String> _selectedCategories = {'files', 'photos', 'videos'};

  static const _categoryLabels = {
    'files': '普通文件',
    'photos': '照片',
    'videos': '视频',
  };

  bool get _isBusy =>
      _phase == AccountCreationPhase.creatingAccount ||
      _phase == AccountCreationPhase.allocatingStorage;

  bool get _accountLocked =>
      _createdUserId != null || _isBusy;

  @override
  void initState() {
    super.initState();
    _loadOnlineRoots();
  }

  Future<void> _loadOnlineRoots() async {
    try {
      final response = await widget.api.get('/api/v2/roots');
      final roots = objectList(
        response['roots'],
      ).where((r) => r['online'] == true).toList(growable: false);
      if (!mounted) return;
      setState(() {
        _rootsLoaded = true;
        _onlineRoots = roots;
        if (roots.isNotEmpty) {
          _selectedRoot ??= roots.first;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() => _rootsLoaded = true);
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    _quota.dispose();
    super.dispose();
  }

  Future<void> _submitCreateOrRetry() async {
    if (_isBusy) return;
    if (_createdUserId == null && !_form.currentState!.validate()) return;
    if (_createdUserId != null && _role == 'member') {
      final parsed = int.tryParse(_quota.text.trim());
      if (parsed == null || parsed < 0 || parsed > 1048576) {
        setState(() => _error = '请输入 0–1048576 GiB 的有效配额');
        return;
      }
    }

    setState(() {
      _error = null;
      _phase = _createdUserId == null
          ? AccountCreationPhase.creatingAccount
          : AccountCreationPhase.allocatingStorage;
    });

    try {
      var userId = _createdUserId;
      if (userId == null) {
        final created = await widget.api.send(
          'POST',
          '/api/v2/users',
          body: {
            'username': _name.text.trim(),
            'password': _password.text,
            'role': _role,
          },
        );
        userId = (created['id'] as num?)?.toInt();
        _createdUserId = userId;
      }

      final rootId = _selectedRoot?['rootID']?.toString() ?? '';
      final generation = (_selectedRoot?['generation'] as num?)?.toInt();
      final categories = _categoryLabels.keys
          .where(_selectedCategories.contains)
          .toList(growable: false);

      if (userId != null &&
          rootId.isNotEmpty &&
          generation != null &&
          categories.isNotEmpty) {
        if (mounted) {
          setState(() => _phase = AccountCreationPhase.allocatingStorage);
        }
        final quotaGiB = int.tryParse(_quota.text.trim());
        await widget.api.send(
          'POST',
          '/api/v2/roots/${Uri.encodeComponent(rootId)}/users/$userId/storage',
          query: {'rootGeneration': '$generation'},
          body: {
            if (_role == 'member' && quotaGiB != null)
              'quotaBytes': quotaGiB * (1 << 30),
            'categories': categories,
          },
        );
      }

      if (!mounted) return;
      Navigator.pop(
        context,
        NewAccountDialogResult(
          accountCreated: true,
          storageAllocated: rootId.isNotEmpty && categories.isNotEmpty,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final friendly = userFacingError(e);
      setState(() {
        if (_createdUserId != null) {
          _phase = AccountCreationPhase.allocationFailed;
          _error = '账号「${_name.text.trim()}」已创建成功，但初始存储空间分配失败：$friendly';
        } else {
          _phase = AccountCreationPhase.editing;
          _error = friendly;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_createdUserId == null ? '创建账号' : '完成初始存储空间分配'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_isBusy) ...[
                LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text(
                  _phase == AccountCreationPhase.creatingAccount
                      ? '第 1/2 步：正在创建账号…'
                      : '第 2/2 步：正在分配存储目录与配额…',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
              ],
              if (_phase == AccountCreationPhase.allocationFailed) ...[
                Notice(
                  '第 1/2 步已完成：账号「${_name.text.trim()}」已创建，无需重复创建。请检查下方硬盘与配额设置后点击「仅重试空间分配」，或先关闭并在存储页配置。',
                ),
                const SizedBox(height: 8),
              ],
              if (_error != null) ...[
                Notice(_error!, error: true),
                const SizedBox(height: 8),
              ],
              TextFormField(
                controller: _name,
                enabled: !_accountLocked,
                decoration: const InputDecoration(labelText: '用户名（3–32 位）'),
                autocorrect: false,
                validator: (v) =>
                    v == null || !RegExp(r'^[A-Za-z0-9_.-]{3,32}$').hasMatch(v)
                    ? '使用 3–32 位字母、数字、点、下划线或短横线'
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _password,
                enabled: !_accountLocked,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码（至少 12 位）'),
                validator: validateNewPassword,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _role,
                decoration: const InputDecoration(labelText: '角色'),
                items: const [
                  DropdownMenuItem(value: 'member', child: Text('成员')),
                  DropdownMenuItem(value: 'admin', child: Text('管理员')),
                ],
                onChanged: _accountLocked
                    ? null
                    : (v) => setState(() => _role = v!),
              ),
              if (_role == 'admin') ...[
                const SizedBox(height: 10),
                Text(
                  '管理员默认无限配额，仅受所选硬盘实际可用空间限制。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (_role == 'member' && _onlineRoots.isNotEmpty) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _quota,
                  enabled: !_isBusy,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '初始空间限额 (GiB)',
                    helperText: '分配空间时直接配置限额，后续可自由调整',
                  ),
                  validator: (v) {
                    final parsed = int.tryParse((v ?? '').trim());
                    if (parsed == null || parsed < 0 || parsed > 1048576) {
                      return '请输入 0–1048576 GiB 的有效配额';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final preset in const [50, 100, 200, 500, 1024])
                      ActionChip(
                        label: Text('$preset GiB'),
                        onPressed: _isBusy
                            ? null
                            : () => _quota.text = '$preset',
                      ),
                  ],
                ),
              ],
              if (_rootsLoaded && _onlineRoots.isEmpty) ...[
                const SizedBox(height: 12),
                const Notice(
                  '当前没有在线的存储硬盘。将先仅创建账号；待连接或登记存储硬盘后，可在「存储与配额」中为该账号分配目录与限额。',
                ),
              ],
              if (_onlineRoots.isNotEmpty) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _selectedRoot?['rootID']?.toString(),
                  decoration: const InputDecoration(labelText: '初始分配硬盘'),
                  items: [
                    for (final r in _onlineRoots)
                      DropdownMenuItem(
                        value: r['rootID']?.toString(),
                        child: Text(r['name']?.toString() ?? '硬盘'),
                      ),
                  ],
                  onChanged: _isBusy
                      ? null
                      : (next) {
                          for (final r in _onlineRoots) {
                            if (r['rootID']?.toString() == next) {
                              setState(() => _selectedRoot = r);
                              break;
                            }
                          }
                        },
                ),
                const SizedBox(height: 10),
                const Text('初始创建的专属目录（可稍后再加）：'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final entry in _categoryLabels.entries)
                      FilterChip(
                        label: Text(entry.value),
                        selected: _selectedCategories.contains(entry.key),
                        onSelected: _isBusy
                            ? null
                            : (checked) => setState(() {
                                if (checked) {
                                  _selectedCategories.add(entry.key);
                                } else {
                                  _selectedCategories.remove(entry.key);
                                }
                              }),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _isBusy
            ? null
            : () => Navigator.pop(
                context,
                _createdUserId != null
                    ? NewAccountDialogResult(
                        accountCreated: true,
                        storageAllocated: false,
                        warningMessage: _error,
                      )
                    : null,
              ),
        child: Text(_createdUserId != null ? '先关闭（稍后分配）' : '取消'),
      ),
      FilledButton(
        onPressed: _isBusy ? null : _submitCreateOrRetry,
        child: Text(_createdUserId != null ? '仅重试空间分配' : '创建账号'),
      ),
    ],
  );
}
