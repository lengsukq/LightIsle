import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';

enum MobileBackupBadgeKind { unconfigured, idle, synced, pendingAttention }

class MobileBackupStatusSnapshot {
  const MobileBackupStatusSnapshot({
    required this.kind,
    required this.label,
    required this.tooltip,
  });

  final MobileBackupBadgeKind kind;
  final String label;
  final String tooltip;
}

Future<MobileBackupStatusSnapshot> readMobilePhotoBackupSnapshot({
  required LightIsleApi api,
  required String accountName,
  required String baseDirectory,
  required bool canBackup,
}) async {
  if (!canBackup || baseDirectory == 'PhonePhotos') {
    return const MobileBackupStatusSnapshot(
      kind: MobileBackupBadgeKind.unconfigured,
      label: '相册备份',
      tooltip: '先在存储空间中分配个人照片目录，即可开启手机原片备份',
    );
  }
  try {
    final prefs = await SharedPreferences.getInstance();
    final deviceId = prefs.getString('lightisle.photoBackup.installationId');
    if (deviceId == null || deviceId.isEmpty) {
      return const MobileBackupStatusSnapshot(
        kind: MobileBackupBadgeKind.idle,
        label: '相册备份',
        tooltip: '将手机相机照片与原画视频增量备份到 NAS',
      );
    }
    final rootIdentity = api.selectedRoot?.identity ?? 'unassigned';
    final scope =
        'lightisle.photoBackup.${api.uri('/api/v2/me/storage').origin}.$accountName.$deviceId.$rootIdentity.$baseDirectory';
    final savedScope = prefs.getString('$scope.albumScope');
    final activeScope = savedScope == 'all'
        ? scope
        : (savedScope == 'camera'
              ? '$scope.camera'
              : (prefs.containsKey('$scope.lastCompleteAt') ||
                        prefs.containsKey('$scope.cursor')
                    ? scope
                    : '$scope.camera'));
    final includeVideos = prefs.getBool('$scope.includeVideos') ?? false;
    final failureKey =
        '$activeScope.failures.${includeVideos ? "videos" : "photos"}';
    var failureCount = (prefs.getInt('$failureKey.omitted') ?? 0).clamp(
      0,
      1 << 20,
    );
    final rawFailures = prefs.getString(failureKey);
    if (rawFailures != null && rawFailures.isNotEmpty) {
      final decoded = jsonDecode(rawFailures);
      if (decoded is List) failureCount += decoded.length;
    }
    if (failureCount > 0) {
      return MobileBackupStatusSnapshot(
        kind: MobileBackupBadgeKind.pendingAttention,
        label: '待处理 $failureCount',
        tooltip: '相册备份有 $failureCount 项原片待处理，点击查看或重试',
      );
    }
    final cursor = prefs.getString('$activeScope.cursor') ?? '';
    if (cursor.isNotEmpty) {
      return const MobileBackupStatusSnapshot(
        kind: MobileBackupBadgeKind.idle,
        label: '继续备份',
        tooltip: '上次相册检查尚未到达末尾，点击继续备份',
      );
    }
    final lastComplete =
        prefs.getInt('$activeScope.lastCompleteAt') ??
        prefs.getInt('$scope.lastCompleteAt') ??
        0;
    if (lastComplete > 0) {
      return const MobileBackupStatusSnapshot(
        kind: MobileBackupBadgeKind.synced,
        label: '已备份',
        tooltip: '最近一轮相册原片已核验完成，点击查看设置或检查新照片',
      );
    }
  } catch (error) {
    debugPrint('PhotoBackupStatusPill: snapshot read fallback: $error');
  }
  return const MobileBackupStatusSnapshot(
    kind: MobileBackupBadgeKind.idle,
    label: '相册备份',
    tooltip: '将手机相机照片与原画视频增量备份到 NAS',
  );
}

/// Compact Liquid Glass status pill displayed in the mobile Photos header.
class PhotoBackupStatusPill extends StatefulWidget {
  const PhotoBackupStatusPill({
    super.key,
    required this.api,
    required this.accountName,
    required this.baseDirectory,
    required this.canBackup,
    required this.onTap,
  });

  final LightIsleApi api;
  final String accountName;
  final String baseDirectory;
  final bool canBackup;
  final Future<void> Function() onTap;

  @override
  State<PhotoBackupStatusPill> createState() => _PhotoBackupStatusPillState();
}

class _PhotoBackupStatusPillState extends State<PhotoBackupStatusPill> {
  MobileBackupStatusSnapshot _snapshot = const MobileBackupStatusSnapshot(
    kind: MobileBackupBadgeKind.idle,
    label: '相册备份',
    tooltip: '手机相册备份',
  );

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(covariant PhotoBackupStatusPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.baseDirectory != widget.baseDirectory ||
        oldWidget.canBackup != widget.canBackup ||
        oldWidget.accountName != widget.accountName) {
      _reload();
    }
  }

  Future<void> _reload() async {
    final next = await readMobilePhotoBackupSnapshot(
      api: widget.api,
      accountName: widget.accountName,
      baseDirectory: widget.baseDirectory,
      canBackup: widget.canBackup,
    );
    if (mounted) setState(() => _snapshot = next);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (IconData icon, Color accent) = switch (_snapshot.kind) {
      MobileBackupBadgeKind.synced => (
        Icons.cloud_done_outlined,
        const Color(0xFF10B981),
      ),
      MobileBackupBadgeKind.pendingAttention => (
        Icons.error_outline_rounded,
        const Color(0xFFF59E0B),
      ),
      MobileBackupBadgeKind.unconfigured => (
        Icons.cloud_off_outlined,
        colors.onSurfaceVariant,
      ),
      MobileBackupBadgeKind.idle => (
        Icons.cloud_upload_outlined,
        colors.primary,
      ),
    };

    final showLabel = MediaQuery.sizeOf(context).width >= 385;
    return Tooltip(
      message: _snapshot.tooltip,
      child: Material(
        color: accent.withValues(alpha: 0.12),
        shape: StadiumBorder(
          side: BorderSide(color: accent.withValues(alpha: 0.34), width: 0.8),
        ),
        child: InkWell(
          key: const ValueKey('photoBackupStatusPillTap'),
          customBorder: const StadiumBorder(),
          onTap: () async {
            await widget.onTap();
            await _reload();
          },
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: showLabel ? 10 : 7,
              vertical: 5,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_snapshot.kind == MobileBackupBadgeKind.synced)
                  IsleDonutGauge(
                    fraction: 1.0,
                    color: accent,
                    size: 16,
                    strokeWidth: 2.2,
                    center: Icon(Icons.check_rounded, size: 10, color: accent),
                    semanticsLabel: '相册已同步完成',
                  )
                else if (_snapshot.kind ==
                    MobileBackupBadgeKind.pendingAttention)
                  IsleDonutGauge(
                    fraction: 0.72,
                    color: accent,
                    size: 16,
                    strokeWidth: 2.2,
                    center: Icon(
                      Icons.priority_high_rounded,
                      size: 9.5,
                      color: accent,
                    ),
                    semanticsLabel: _snapshot.label,
                  )
                else
                  Icon(icon, size: 15, color: accent),
                if (showLabel) ...[
                  const SizedBox(width: 5),
                  Text(
                    _snapshot.label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: accent,
                      height: 1.1,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
