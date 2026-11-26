import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'mobile_photo_backup_controller.dart';
import 'photo_backup_prefs_schema.dart';
import 'photo_backup_verified_ledger.dart';

Future<void> showMobilePhotoSpaceReleaseSheet(
  BuildContext context,
  MobilePhotoBackupController controller, {
  bool autoTriggered = false,
  int? initialMinAgeDays,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetContext) => _MobilePhotoSpaceReleaseSheet(
      controller: controller,
      autoTriggered: autoTriggered,
      initialMinAgeDays: initialMinAgeDays,
    ),
  );
}

class _MobilePhotoSpaceReleaseSheet extends StatefulWidget {
  const _MobilePhotoSpaceReleaseSheet({
    required this.controller,
    required this.autoTriggered,
    this.initialMinAgeDays,
  });

  final MobilePhotoBackupController controller;
  final bool autoTriggered;
  final int? initialMinAgeDays;

  @override
  State<_MobilePhotoSpaceReleaseSheet> createState() =>
      _MobilePhotoSpaceReleaseSheetState();
}

class _MobilePhotoSpaceReleaseSheetState
    extends State<_MobilePhotoSpaceReleaseSheet> {
  SpaceReleaseFilter _filter = SpaceReleaseFilter.all;
  int? _customAgeDays;
  String? _selectedAlbum;

  bool _verifying = false;
  bool _deleting = false;
  bool _cancelled = false;
  int _checkedCount = 0;
  int _totalCount = 0;
  int _deleteBatchCurrent = 0;
  int _deleteBatchTotal = 0;

  SpaceReleaseVerificationSummary? _verificationSummary;
  SpaceReleaseExecutionResult? _executionResult;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    final minAge = widget.initialMinAgeDays;
    if (minAge == PhotoBackupPrefsSchema.spaceReleaseAgeDays30) {
      _filter = SpaceReleaseFilter.olderThan30Days;
    } else if (minAge == PhotoBackupPrefsSchema.spaceReleaseAgeDays90) {
      _filter = SpaceReleaseFilter.olderThan90Days;
    } else if (minAge != null && minAge > 0) {
      _filter = SpaceReleaseFilter.all;
      _customAgeDays = minAge;
    }
    if (widget.autoTriggered) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_verifyAndRequestRelease());
      });
    }
  }

  List<VerifiedPhotoBackupRecord> get _filteredRecords =>
      PhotoBackupVerifiedLedger.filterRecords(
        widget.controller.spaceRelease.verifiedRecords,
        filter: _filter,
        albumName: _selectedAlbum,
        minAgeDaysOverride: _customAgeDays,
      );

  bool get _busy => _verifying || _deleting;

  void _selectFilter(SpaceReleaseFilter next) {
    if (_busy) return;
    setState(() {
      _filter = next;
      _customAgeDays = null;
      _verificationSummary = null;
      _executionResult = null;
      _errorMessage = null;
      if (next == SpaceReleaseFilter.byAlbum) {
        final albums = PhotoBackupVerifiedLedger.distinctAlbums(
          widget.controller.spaceRelease.verifiedRecords,
        );
        if (_selectedAlbum == null && albums.isNotEmpty) {
          _selectedAlbum = albums.first;
        }
      }
    });
  }

  Future<void> _verifyAndRequestRelease() async {
    if (_busy) return;
    final candidates = _filteredRecords;
    if (candidates.isEmpty) return;
    setState(() {
      _verifying = true;
      _cancelled = false;
      _checkedCount = 0;
      _totalCount = candidates.length;
      _verificationSummary = null;
      _executionResult = null;
      _errorMessage = null;
    });

    final summary = await widget.controller.verifyCandidatesForRelease(
      candidates,
      onProgress: (checked, total) {
        if (!mounted) return;
        setState(() {
          _checkedCount = checked;
          _totalCount = total;
        });
      },
      isCancelled: () => _cancelled || !mounted,
    );
    if (!mounted) return;
    setState(() {
      _verifying = false;
      _verificationSummary = summary;
    });

    if (summary.cancelled || summary.aborted || summary.verified.isEmpty) {
      return;
    }

    setState(() {
      _deleting = true;
      _deleteBatchCurrent = 1;
      _deleteBatchTotal = 1;
      _errorMessage = null;
    });
    try {
      final result = await widget.controller.executeNativeSpaceRelease(
        summary.verified,
        onBatchProgress: (currentBatch, totalBatches, _) {
          if (!mounted) return;
          setState(() {
            _deleteBatchCurrent = currentBatch;
            _deleteBatchTotal = totalBatches;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _executionResult = result;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _errorMessage = '未能拉起系统删除确认：${userFacingError(error)}。本机原片均已保留。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = IslePalette.of(context);
    final sage = palette['brandSage'];
    final amber = palette['brandAmber'];

    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final allRecords = widget.controller.spaceRelease.verifiedRecords;
        final totalBytes = PhotoBackupVerifiedLedger.totalBytes(allRecords);
        final albums = PhotoBackupVerifiedLedger.distinctAlbums(allRecords);
        final filtered = _filteredRecords;
        final filteredBytes = PhotoBackupVerifiedLedger.totalBytes(filtered);

        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.80,
          minChildSize: 0.52,
          maxChildSize: 0.94,
          builder: (context, scrollController) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.autoTriggered ? '备份完成 · 安全释放本地空间' : '释放本机已备份空间',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '可释放估算：${formatBytes(totalBytes)}（共 ${allRecords.length} 项已备份记录）',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: sage,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  children: [
                    _SafetyNoticeBanner(
                      autoTriggered: widget.autoTriggered,
                      customAgeDays: _customAgeDays,
                      accent: amber,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '筛选待释放原片',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        ChoiceChip(
                          label: const Text('全部已备份'),
                          selected:
                              _filter == SpaceReleaseFilter.all &&
                              _customAgeDays == null,
                          onSelected: _busy
                              ? null
                              : (_) => _selectFilter(SpaceReleaseFilter.all),
                        ),
                        ChoiceChip(
                          label: const Text('30 天前'),
                          selected:
                              _filter == SpaceReleaseFilter.olderThan30Days,
                          onSelected: _busy
                              ? null
                              : (_) => _selectFilter(
                                  SpaceReleaseFilter.olderThan30Days,
                                ),
                        ),
                        ChoiceChip(
                          label: const Text('90 天前'),
                          selected:
                              _filter == SpaceReleaseFilter.olderThan90Days,
                          onSelected: _busy
                              ? null
                              : (_) => _selectFilter(
                                  SpaceReleaseFilter.olderThan90Days,
                                ),
                        ),
                        ChoiceChip(
                          label: const Text('仅视频'),
                          selected: _filter == SpaceReleaseFilter.videosOnly,
                          onSelected: _busy
                              ? null
                              : (_) => _selectFilter(
                                  SpaceReleaseFilter.videosOnly,
                                ),
                        ),
                        if (albums.isNotEmpty)
                          ChoiceChip(
                            label: const Text('按相簿'),
                            selected: _filter == SpaceReleaseFilter.byAlbum,
                            onSelected: _busy
                                ? null
                                : (_) =>
                                      _selectFilter(SpaceReleaseFilter.byAlbum),
                          ),
                      ],
                    ),
                    if (_filter == SpaceReleaseFilter.byAlbum &&
                        albums.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: albums.contains(_selectedAlbum)
                            ? _selectedAlbum
                            : albums.first,
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: '选择相簿',
                        ),
                        items: albums
                            .map(
                              (name) => DropdownMenuItem(
                                value: name,
                                child: Text(
                                  name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(growable: false),
                        onChanged: _busy
                            ? null
                            : (value) => setState(() {
                                _selectedAlbum = value;
                                _verificationSummary = null;
                                _executionResult = null;
                              }),
                      ),
                    ],
                    const SizedBox(height: 12),
                    IsleSurface(
                      margin: EdgeInsets.zero,
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          IsleSquircleBadge(
                            icon: Icons.cleaning_services_outlined,
                            color: sage,
                            size: 36,
                            iconSize: 18,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '当前筛选命中 ${filtered.length} 项',
                                  style: const TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  filtered.isEmpty
                                      ? '当前条件下没有可释放的已备份记录。'
                                      : '预计可释放本机约 ${formatBytes(filteredBytes)}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_verifying) ...[
                      const SizedBox(height: 14),
                      Text(
                        '正在在线核验远端原片 SHA-256（$_checkedCount / $_totalCount）…',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: _totalCount > 0
                            ? (_checkedCount / _totalCount).clamp(0.0, 1.0)
                            : null,
                      ),
                    ],
                    if (_deleting) ...[
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2.2),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _deleteBatchTotal > 1
                                  ? '正在分批请求系统释放（第 $_deleteBatchCurrent / $_deleteBatchTotal 批），请在系统弹窗中点击确认…'
                                  : '请在系统弹出的相册确认窗口中点击确认以释放本地原片…',
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 12),
                      _StatusCallout(
                        icon: Icons.error_outline_rounded,
                        color: colors.error,
                        message: _errorMessage!,
                      ),
                    ],
                    if (_executionResult != null) ...[
                      const SizedBox(height: 12),
                      _StatusCallout(
                        icon: _executionResult!.deleted
                            ? Icons.check_circle_outline_rounded
                            : Icons.info_outline_rounded,
                        color: _executionResult!.deleted
                            ? sage
                            : colors.onSurfaceVariant,
                        message: _executionResult!.message,
                      ),
                    ],
                    if (_verificationSummary != null)
                      ..._buildVerificationReport(
                        context,
                        _verificationSummary!,
                        amber,
                        colors,
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                child: Row(
                  children: [
                    if (_verifying)
                      OutlinedButton(
                        onPressed: () => setState(() => _cancelled = true),
                        child: const Text('中止核验'),
                      )
                    else
                      TextButton(
                        onPressed: _deleting
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: const Text('关闭'),
                      ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: _busy || filtered.isEmpty
                          ? null
                          : () => unawaited(_verifyAndRequestRelease()),
                      icon: const Icon(Icons.verified_user_outlined, size: 17),
                      label: Text(
                        filtered.isEmpty
                            ? '暂无可释放项'
                            : '核验并请求系统释放（${filtered.length} 项）',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _buildVerificationReport(
    BuildContext context,
    SpaceReleaseVerificationSummary summary,
    Color amber,
    ColorScheme colors,
  ) {
    final widgets = <Widget>[];
    if (summary.aborted && summary.abortMessage != null) {
      widgets.add(const SizedBox(height: 12));
      widgets.add(
        _StatusCallout(
          icon: Icons.warning_amber_rounded,
          color: colors.error,
          message: summary.abortMessage!,
        ),
      );
    } else if (summary.cancelled) {
      widgets.add(const SizedBox(height: 12));
      widgets.add(
        _StatusCallout(
          icon: Icons.info_outline_rounded,
          color: colors.onSurfaceVariant,
          message: '已中止在线核验，本机原片均已保留。',
        ),
      );
    } else if (summary.verified.isEmpty && summary.skipped.isNotEmpty) {
      widgets.add(const SizedBox(height: 12));
      widgets.add(
        _StatusCallout(
          icon: Icons.shield_outlined,
          color: amber,
          message: '本次筛选的 ${summary.skipped.length} 项均未通过远端 SHA-256 核验，已全部安全保留本机原片。',
        ),
      );
    }
    if (summary.skipped.isNotEmpty) {
      widgets.add(const SizedBox(height: 12));
      widgets.add(
        Text(
          '已安全跳过并保留本机原片（${summary.skipped.length} 项）',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
      );
      widgets.add(const SizedBox(height: 6));
      for (final skipped in summary.skipped.take(30)) {
        widgets.add(
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.shield_outlined, size: 18, color: amber),
            title: Text(
              skipped.record.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5),
            ),
            subtitle: Text(
              skipped.reason,
              style: TextStyle(fontSize: 11.5, color: colors.onSurfaceVariant),
            ),
          ),
        );
      }
      if (summary.skipped.length > 30) {
        widgets.add(
          Text(
            '其余 ${summary.skipped.length - 30} 项同样因核验未通过而保留在手机中。',
            style: TextStyle(fontSize: 11.5, color: colors.onSurfaceVariant),
          ),
        );
      }
    }
    return widgets;
  }
}

class _SafetyNoticeBanner extends StatelessWidget {
  const _SafetyNoticeBanner({
    required this.autoTriggered,
    required this.customAgeDays,
    required this.accent,
  });

  final bool autoTriggered;
  final int? customAgeDays;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final text = autoTriggered
        ? '本轮备份已无错完成，按你设定的保留期${customAgeDays != null ? "（$customAgeDays 天前）" : ""}自动发起释放核验。受系统安全机制保护，核验通过后仍需你在系统弹窗点一次确认，绝不静默删图。'
        : '释放前会逐项在线核验 NAS 物理硬盘与远端 SHA-256；任何硬盘离线、换盘、文件缺失或校验不一致的条目都会自动跳过并保留手机原片。最终删除由系统弹窗确认。';
    return IsleSurface(
      margin: EdgeInsets.zero,
      tint: accent,
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.verified_user_outlined, size: 18, color: accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 12, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusCallout extends StatelessWidget {
  const _StatusCallout({
    required this.icon,
    required this.color,
    required this.message,
  });

  final IconData icon;
  final Color color;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(IsleRadius.input),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 12.5, color: color, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
