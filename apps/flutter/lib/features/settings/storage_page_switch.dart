part of 'storage_page.dart';

class _AdminConfirmationCancelledException implements Exception {
  const _AdminConfirmationCancelledException();
}

extension _StoragePageSwitch on _StoragePageState {
  // Sensitive disk-switch HTTP mutations require the administrator's current
  // password or a server-issued short-lived step-up confirmation token bound to
  // (session, userID, taskID). Never persist the password in widget state.
  Future<Map<String, dynamic>> _sendStorageSwitch(
    int id,
    Map<String, dynamic> request,
  ) async {
    final endpoint = '/api/v2/users/$id/storage/switch-root';
    final taskID = request['taskID']?.toString() ?? '';
    final tokenKey = '$id:$taskID';
    final existingToken = taskID.isNotEmpty ? switchStepUpTokens[tokenKey] : null;
    final payload = <String, dynamic>{
      ...request,
      if (existingToken != null && existingToken.isNotEmpty)
        'confirmationToken': existingToken,
    };
    try {
      final response = await widget.api.send('POST', endpoint, body: payload);
      _recordSwitchStepUpToken(id, taskID, response);
      return response;
    } on LightIsleApiException catch (e) {
      if (e.code != 'admin_confirmation_required' &&
          e.code != 'admin_confirmation_invalid') {
        rethrow;
      }
      if (taskID.isNotEmpty) {
        switchStepUpTokens.remove(tokenKey);
      }
    }
    if (!mounted) throw const _AdminConfirmationCancelledException();
    var enteredPassword = '';
    final password = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('管理员身份确认'),
        content: TextField(
          autofocus: true,
          obscureText: true,
          onChanged: (next) => enteredPassword = next,
          decoration: const InputDecoration(
            labelText: '当前管理员密码',
            helperText: '换盘属于高风险操作，需要额外验证（同一任务 10 分钟内免重复输入）',
          ),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, enteredPassword),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (password == null || password.isEmpty) {
      throw const _AdminConfirmationCancelledException();
    }
    final response = await widget.api.send(
      'POST',
      endpoint,
      body: {
        ...request,
        'confirmationPassword': password,
      },
    );
    _recordSwitchStepUpToken(id, taskID, response);
    return response;
  }

  void _recordSwitchStepUpToken(
    int id,
    String requestTaskID,
    Map<String, dynamic> response,
  ) {
    final token = response['confirmationToken']?.toString() ?? '';
    final resolvedTaskID = response['taskID']?.toString() ?? requestTaskID;
    if (token.isNotEmpty && resolvedTaskID.isNotEmpty) {
      switchStepUpTokens['$id:$resolvedTaskID'] = token;
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
    if (loading || !rootsKnown) return;
    if (targetRoots.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('尚未登记目标外置硬盘'),
          content: const Text(
            '当前仅登记了 1 块在线存储硬盘。请先在 Mac 管理端「个人空间」或「存储 → 存储位置」中点击「选择外置盘设为主存储…」或「+ 添加外置盘…」，登记外置硬盘并刷新后，即可将现有数据迁移过去。',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
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
            width: 440,
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
                        if (sourceOnline)
                          const RadioListTile<String>(
                            contentPadding: EdgeInsets.zero,
                            value: 'migrate',
                            title: Text('复制并核验后删除'),
                            subtitle: Text('核验完成后再次确认，源文件进入可恢复回收站。'),
                          ),
                        if (sourceOnline)
                          const RadioListTile<String>(
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
                  const SizedBox(height: 10),
                  Notice(
                    mode == 'empty'
                        ? '空白启用说明：旧盘原文件保留不动；旧盘上的照片收藏、私密相册与影院播放进度留在旧盘，绑定在旧盘路径上的共享相册与公开分享链接将在切换后失效。'
                        : '媒体与分享说明：通过 SHA-256 核验的本人照片收藏、私密相册及影院观看进度会自动迁移到新盘；绑定在旧盘路径上的共享相册与公开分享链接将在切换后失效，需在新盘重新创建分享。',
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
    final previousMessage = switchMessages[id];
    _updateState(() => switchCancellations.remove(id));
    try {
      final result = await _sendStorageSwitch(id, {
        'phase': 'cancel',
        'taskID': taskID,
      });
      if (!mounted) return;
      if (!loading) {
        final cancelled = result['phase'] == 'cancelled';
        _updateState(() {
          switchProgress.remove(id);
          switchMessages[id] = cancelled
              ? '换盘任务已取消。'
              : '当前阶段无法取消，请查看最近换盘任务。';
        });
      }
    } on _AdminConfirmationCancelledException {
      if (!mounted) return;
      _updateState(() {
        if (previousMessage != null) switchMessages[id] = previousMessage;
        switchCancellations[id] = taskID;
      });
    } catch (e) {
      if (!mounted) return;
      _updateState(() {
        error = userFacingError(e);
        switchCancellations[id] = taskID;
      });
    }
  }

  Future<void> recoverStorageSwitch(
    int id,
    String taskID, {
    required bool publication,
  }) async {
    final approved = await confirmAction(
      context,
      publication ? '重新核验并继续切换？' : '重新核验源盘？',
      publication
          ? '两块盘和已写入的目录都通过核验后才会继续。原任务的回收规则继续生效。'
          : '程序会重新校验两块盘。只有本任务核验过的源文件会进入可恢复回收站。',
      action: '核验并继续',
      isDestructive: true,
    );
    if (approved && mounted) {
      await _runStorageSwitch(id, {
        'phase': publication ? 'resume_publish' : 'recover_source',
        'taskID': taskID,
      });
    }
  }

  Future<void> _runStorageSwitch(int id, Map<String, dynamic> request) async {
    if (loading) return;
    final previousMessage = switchMessages[id];
    _updateState(() {
      loading = true;
      error = null;
      switchMessages[id] = '正在读取换盘任务…';
    });
    final endpoint = '/api/v2/users/$id/storage/switch-root';
    try {
      var result = request['phase'] == 'status'
          ? await widget.api.send('POST', endpoint, body: request)
          : await _sendStorageSwitch(id, request);
      while (mounted) {
        final taskID = result['taskID']?.toString();
        final phase = result['phase']?.toString() ?? '';
        if (taskID == null || taskID.isEmpty) {
          throw const FormatException('换盘任务缺少编号');
        }
        if (phase == 'verified') {
          if (!mounted) return;
          final files = result['verifiedFiles'] ?? 0;
          final shares = result['affectedShares'] ?? 0;
          final bytes = result['copiedBytes'] ?? 0;
          _updateState(() {
            switchProgress[id] = _describeSwitchProgress(result);
          });
          final approved = await confirmAction(
            context,
            '已核验，确认切换硬盘？',
            '已校验 $files 个文件（$bytes 字节），涉及 $shares 项分享。确认后切换目录，源文件进入可恢复回收站。'
                '${_affectedStorageShares(result)}',
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
          result = await _sendStorageSwitch(id, {
            'phase': 'confirm_cleanup',
            'taskID': taskID,
          });
          continue;
        }
        if (phase == 'queued' || phase == 'copying' || phase == 'committing') {
          final progressInfo = _describeSwitchProgress(result);
          _updateState(() {
            switchProgress[id] = progressInfo;
            if (phase == 'committing') {
              switchCancellations.remove(id);
            } else {
              switchCancellations[id] = taskID;
            }
            switchMessages[id] = progressInfo.summary;
          });
          await Future<void>.delayed(const Duration(seconds: 1));
          if (!mounted) return;
          result = await widget.api.send(
            'POST',
            endpoint,
            body: {'phase': 'status', 'taskID': taskID},
          );
          continue;
        }
        final policy = await widget.api.get('/api/v2/users/$id/storage');
        if (!mounted) return;
        _updateState(() {
          policies[id] = policy;
          switchProgress.remove(id);
          switchCancellations.remove(id);
          if (phase == 'interrupted' && result['canCancel'] == true) {
            switchCancellations[id] = taskID;
          }
          final publication =
              phase == 'interrupted' && result['canResume'] == true;
          if (phase == 'source_pending' || publication) {
            switchRecoveries[id] = (taskID: taskID, publication: publication);
          } else {
            switchRecoveries.remove(id);
          }
          switchMessages[id] = switch (phase) {
            'completed' when result['mode'] == 'empty' =>
              '已启用空白新目录，旧盘原件保留。',
            'completed' when result['mode'] == 'copy' =>
              '已复制并切换，旧盘原件保留。',
            'completed' => '已切换到目标盘，源文件可在旧盘的回收站恢复。',
            'source_pending' =>
              '空间已切换，源文件待处理。请在 Mac 管理端核对旧盘和回收站。',
            'interrupted' when publication =>
              '切换尚未提交。请接回原来的两块盘，再重新核验并继续。',
            'interrupted' => '任务中断。请检查两块硬盘和任务结果后再操作。',
            'cancelled' => '换盘任务已取消。',
            _ => storageSwitchError(result['error']?.toString()),
          };
          if (result['reviewPath'] case final String reviewPath
              when reviewPath.isNotEmpty) {
            switchMessages[id] = '${switchMessages[id]} 核对位置：$reviewPath';
          }
          if (phase == 'completed') {
            switchMessages[id] =
                '${switchMessages[id]}${_affectedStorageShares(result)}';
          }
        });
        return;
      }
    } on _AdminConfirmationCancelledException {
      if (mounted) {
        _updateState(() {
          if (previousMessage != null) {
            switchMessages[id] = previousMessage;
          } else {
            switchMessages.remove(id);
          }
        });
      }
    } catch (e) {
      if (mounted) {
        _updateState(() {
          switchProgress.remove(id);
          if (e is LightIsleApiException &&
              e.code == 'storage_switch_task_not_found') {
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

  ({String stageLabel, String summary, double? fraction}) _describeSwitchProgress(
    Map<String, dynamic> result,
  ) {
    final phase = result['phase']?.toString() ?? 'queued';
    final copiedBytes = (result['copiedBytes'] as num? ?? 0).toInt();
    final totalBytes = (result['totalBytes'] as num? ?? 0).toInt();
    final verifiedFiles = (result['verifiedFiles'] as num? ?? 0).toInt();
    final totalFiles = (result['totalFiles'] as num? ?? 0).toInt();
    final reviewPath = result['reviewPath']?.toString() ?? '';
    final fraction = totalBytes > 0
        ? (copiedBytes / totalBytes).clamp(0.0, 1.0)
        : null;
    final bytesText = totalBytes > 0
        ? '$copiedBytes / $totalBytes 字节'
        : '$copiedBytes 字节';
    final filesText = totalFiles > 0
        ? '$verifiedFiles / $totalFiles 个文件'
        : '$verifiedFiles 个文件';
    final pathSuffix = reviewPath.isNotEmpty ? ' · 当前目录 $reviewPath' : '';
    return switch (phase) {
      'copying' => (
        stageLabel: '阶段 2/5 · 复制并核验',
        summary: '正在复制并核验，已复制 $bytesText（已核验 $filesText）$pathSuffix…',
        fraction: fraction,
      ),
      'verified' => (
        stageLabel: '阶段 3/5 · 核验通过待确认',
        summary: '已核验 $filesText（$bytesText），等待管理员确认切换。',
        fraction: 1.0,
      ),
      'committing' => (
        stageLabel: '阶段 4/5 · 原子切换并同步媒体记录',
        summary: '正在切换空间并核对源盘$pathSuffix…',
        fraction: 1.0,
      ),
      _ => (
        stageLabel: '阶段 1/5 · 扫描目录并预留空间',
        summary: '换盘任务已排队…',
        fraction: 0.05,
      ),
    };
  }

  String _affectedStorageShares(Map<String, dynamic> result) {
    final items = result['affectedShareItems'];
    if (items is! List || items.isEmpty) return '';
    final lines = [
      for (final item in items.take(5))
        if (item is Map)
          "${item['kind'] == 'album' ? '共享相册' : '公开链接'} · ${item['path']}",
    ];
    final total = result['affectedShares'];
    if (total is int && total > lines.length) {
      lines.add('另有 ${total - lines.length} 项。');
    }
    return '\n${lines.join('\n')}\n切换后由所有者在新位置重新创建链接或授权。';
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
}
