import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'family_reminder_sheet.dart';

export 'family_reminder_sheet.dart' show showFamilyReminderSheet;

class FamilyLunarDate {
  const FamilyLunarDate({
    required this.year,
    required this.month,
    required this.day,
    required this.isLeap,
    required this.ganZhi,
    required this.zodiac,
    required this.monthName,
    required this.dayName,
    required this.display,
  });

  final int year;
  final int month;
  final int day;
  final bool isLeap;
  final String ganZhi;
  final String zodiac;
  final String monthName;
  final String dayName;
  final String display;

  factory FamilyLunarDate.fromJson(Map<String, dynamic> json) => FamilyLunarDate(
    year: (json['year'] as num?)?.toInt() ?? 0,
    month: (json['month'] as num?)?.toInt() ?? 0,
    day: (json['day'] as num?)?.toInt() ?? 0,
    isLeap: json['isLeap'] == true,
    ganZhi: json['ganZhi']?.toString() ?? '',
    zodiac: json['zodiac']?.toString() ?? '',
    monthName: json['monthName']?.toString() ?? '',
    dayName: json['dayName']?.toString() ?? '',
    display: json['display']?.toString() ?? '',
  );
}

const List<({String id, String label, String paletteKey})>
familyReminderColorSpecs = [
  (id: 'amber', label: '暖阳', paletteKey: 'brandAmber'),
  (id: 'rose', label: '晚霞', paletteKey: 'brandRose'),
  (id: 'blue', label: '晴空', paletteKey: 'brandBlue'),
  (id: 'sage', label: '青苔', paletteKey: 'brandSage'),
  (id: 'violet', label: '暮紫', paletteKey: 'brandViolet'),
];

Color familyReminderPaletteColor(String id, IslePalette palette) {
  for (final item in familyReminderColorSpecs) {
    if (item.id == id) return palette[item.paletteKey];
  }
  return palette['brandAmber'];
}

Color familyReminderToneColor(String id) =>
    familyReminderPaletteColor(id, const IslePalette(false));

class FamilyReminder {
  const FamilyReminder({
    required this.id,
    required this.authorUserId,
    required this.authorUsername,
    required this.title,
    required this.category,
    required this.calendarType,
    required this.year,
    required this.month,
    required this.day,
    required this.isLeapMonth,
    required this.repeatRule,
    required this.intervalDays,
    required this.nextSolarDate,
    required this.daysUntil,
    required this.yearsCount,
    required this.lunarLabel,
    required this.remindDays,
    required this.remindDaysCsv,
    required this.notifyEnabled,
    required this.color,
    required this.notes,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id, authorUserId, year, month, day, intervalDays, daysUntil;
  final int yearsCount, createdAt, updatedAt;
  final String authorUsername, title, category, calendarType, repeatRule;
  final String nextSolarDate, lunarLabel, remindDaysCsv, color, notes;
  final bool isLeapMonth, notifyEnabled;
  final List<int> remindDays;

  bool get isLunar => calendarType == 'lunar';

  IconData get categoryIcon => switch (category) {
    'birthday' => Icons.cake_outlined,
    'anniversary' => Icons.favorite_border_rounded,
    'chore' => Icons.cleaning_services_outlined,
    'bill' => Icons.receipt_long_outlined,
    _ => Icons.event_note_outlined,
  };

  String get repeatLabel => switch (repeatRule) {
    'yearly' => '每年',
    'monthly' => '每月',
    'weekly' => '每周',
    'interval_days' => intervalDays > 0 ? '每 $intervalDays 天' : '按间隔',
    _ => '单次',
  };

  String get countdownLabel {
    if (daysUntil == 0) return '今天';
    if (daysUntil == 1) return '明天';
    if (daysUntil == 2) return '后天';
    if (daysUntil > 2) return '$daysUntil 天后';
    return '已过 ${-daysUntil} 天';
  }

  String get yearsBadge {
    if (yearsCount <= 0) return '';
    if (category == 'birthday') return '$yearsCount 岁';
    if (category == 'anniversary') return '第 $yearsCount 周年';
    return '第 $yearsCount 年';
  }

  Color resolveToneColor(IslePalette palette) =>
      familyReminderPaletteColor(color, palette);

  Color get toneColor => familyReminderToneColor(color);

  factory FamilyReminder.fromJson(Map<String, dynamic> json) {
    final rawRemind = json['remindDays'];
    final remindList = rawRemind is List
        ? rawRemind
              .map((e) => (e as num?)?.toInt())
              .whereType<int>()
              .toList(growable: false)
        : const <int>[];
    return FamilyReminder(
      id: (json['id'] as num?)?.toInt() ?? 0,
      authorUserId: (json['authorUserId'] as num?)?.toInt() ?? 0,
      authorUsername: json['authorUsername']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      category: json['category']?.toString() ?? 'custom',
      calendarType: json['calendarType']?.toString() ?? 'solar',
      year: (json['year'] as num?)?.toInt() ?? 0,
      month: (json['month'] as num?)?.toInt() ?? 1,
      day: (json['day'] as num?)?.toInt() ?? 1,
      isLeapMonth: json['isLeapMonth'] == true,
      repeatRule: json['repeatRule']?.toString() ?? 'yearly',
      intervalDays: (json['intervalDays'] as num?)?.toInt() ?? 0,
      nextSolarDate: json['nextSolarDate']?.toString() ?? '',
      daysUntil: (json['daysUntil'] as num?)?.toInt() ?? 0,
      yearsCount: (json['yearsCount'] as num?)?.toInt() ?? 0,
      lunarLabel: json['lunarLabel']?.toString() ?? '',
      remindDays: remindList,
      remindDaysCsv: json['remindDaysCsv']?.toString() ?? '',
      notifyEnabled: json['notifyEnabled'] != false,
      color: json['color']?.toString() ?? 'amber',
      notes: json['notes']?.toString() ?? '',
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

class FamilyRemindersSnapshot {
  const FamilyRemindersSnapshot({
    this.reminders = const [],
    this.todaySolar = '',
    this.todayLunar,
    this.isAdmin = false,
    this.currentUserId = 0,
    this.currentUsername = '',
  });

  final List<FamilyReminder> reminders;
  final String todaySolar, currentUsername;
  final FamilyLunarDate? todayLunar;
  final bool isAdmin;
  final int currentUserId;

  factory FamilyRemindersSnapshot.fromJson(Map<String, dynamic> json) {
    final list = objectList(json['reminders'])
        .map(FamilyReminder.fromJson)
        .where((item) => item.id > 0)
        .toList(growable: false);
    final rawLunar = json['todayLunar'];
    return FamilyRemindersSnapshot(
      reminders: list,
      todaySolar: json['todaySolar']?.toString() ?? '',
      todayLunar: rawLunar is Map
          ? FamilyLunarDate.fromJson(Map<String, dynamic>.from(rawLunar))
          : null,
      isAdmin: json['isAdmin'] == true,
      currentUserId: (json['currentUserId'] as num?)?.toInt() ?? 0,
      currentUsername: json['currentUsername']?.toString() ?? '',
    );
  }
}

class FamilyRemindersApi {
  const FamilyRemindersApi(this.api);

  final LightIsleApi api;

  Future<FamilyRemindersSnapshot> list({int? days, String? category}) async {
    final query = <String, String>{};
    if (days != null && days > 0) query['days'] = '$days';
    if (category != null && category.isNotEmpty) query['category'] = category;
    final res = await api.get(
      '/api/v2/family-reminders',
      query: query.isEmpty ? null : query,
    );
    return FamilyRemindersSnapshot.fromJson(res);
  }

  Future<FamilyReminder> create(Map<String, dynamic> body) async {
    final res = await api.send('POST', '/api/v2/family-reminders', body: body);
    final raw = res['reminder'];
    if (raw is! Map) throw const FormatException('服务器未返回已创建的提醒内容。');
    return FamilyReminder.fromJson(Map<String, dynamic>.from(raw));
  }

  Future<FamilyReminder> update(int id, Map<String, dynamic> body) async {
    final res = await api.send(
      'PATCH',
      '/api/v2/family-reminders/$id',
      body: body,
    );
    final raw = res['reminder'];
    if (raw is! Map) throw const FormatException('服务器未返回更新后的提醒内容。');
    return FamilyReminder.fromJson(Map<String, dynamic>.from(raw));
  }

  Future<void> delete(int id) async {
    await api.send('DELETE', '/api/v2/family-reminders/$id');
  }

  Future<FamilyReminder> complete(int id) async {
    final res = await api.send('POST', '/api/v2/family-reminders/$id/complete');
    final raw = res['reminder'];
    if (raw is! Map) throw const FormatException('服务器未返回打卡后的提醒状态。');
    return FamilyReminder.fromJson(Map<String, dynamic>.from(raw));
  }
}

/// Compact home-screen section displaying upcoming family birthdays,
/// anniversaries, recurring chores, bills, and one-tap completion check-in.
class FamilyRemindersSection extends StatefulWidget {
  const FamilyRemindersSection({
    super.key,
    required this.api,
    required this.isAdmin,
  });

  final LightIsleApi api;
  final bool isAdmin;

  @override
  State<FamilyRemindersSection> createState() => _FamilyRemindersSectionState();
}

class _FamilyRemindersSectionState extends State<FamilyRemindersSection> {
  FamilyRemindersSnapshot _snapshot = const FamilyRemindersSnapshot();
  bool _loading = false;
  bool _expanded = false;
  int? _busyId;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant FamilyRemindersSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api || oldWidget.isAdmin != widget.isAdmin) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final next = await FamilyRemindersApi(widget.api).list();
      if (!mounted) return;
      setState(() {
        _snapshot = next;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = userFacingError(error);
        _loading = false;
      });
    }
  }

  bool _canEdit(FamilyReminder item) =>
      widget.isAdmin ||
      _snapshot.isAdmin ||
      (_snapshot.currentUserId > 0 &&
          item.authorUserId == _snapshot.currentUserId);

  Future<void> _openEditor({FamilyReminder? existing}) async {
    final saved = await showFamilyReminderSheet(
      context,
      api: widget.api,
      existing: existing,
    );
    if (saved != null && mounted) {
      await _load();
    }
  }

  Future<void> _completeReminder(FamilyReminder item) async {
    if (_busyId != null) return;
    setState(() => _busyId = item.id);
    try {
      final updated = await FamilyRemindersApi(widget.api).complete(item.id);
      if (!mounted) return;
      final hint = updated.repeatRule == 'once'
          ? '已完成「${item.title}」'
          : '已打卡「${item.title}」，下次提醒：${updated.nextSolarDate}';
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(hint)),
      );
      await _load();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('打卡失败：${userFacingError(error)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _deleteReminder(FamilyReminder item) async {
    if (!_canEdit(item) || _busyId != null) return;
    final confirmed = await confirmAction(
      context,
      '删除这条提醒？',
      '删除「${item.title}」后，所有家庭成员将不再收到该提醒。',
      action: '删除',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busyId = item.id);
    try {
      await FamilyRemindersApi(widget.api).delete(item.id);
      if (mounted) await _load();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('删除失败：${userFacingError(error)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Widget _buildReminderRow(
    BuildContext context,
    FamilyReminder item,
    bool dark,
    IslePalette palette,
  ) {
    final theme = Theme.of(context);
    final tone = item.resolveToneColor(palette);
    final isBusy = _busyId == item.id;
    final isUrgent = item.daysUntil <= 3;
    final dateParts = <String>[
      if (item.nextSolarDate.isNotEmpty) item.nextSolarDate,
      if (item.isLunar && item.lunarLabel.isNotEmpty) item.lunarLabel,
      if (item.yearsBadge.isNotEmpty) item.yearsBadge,
      item.repeatLabel,
    ];

    return Container(
      key: ValueKey('familyReminderItem-${item.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        gradient: IsleGlass.embossedGradient(dark, palette, tint: tone),
        borderRadius: BorderRadius.circular(IsleRadius.item),
        border: Border.all(
          color: isUrgent
              ? tone.withValues(alpha: dark ? 0.55 : 0.42)
              : IsleGlass.rimBorderColor(dark),
          width: isUrgent ? 1.15 : 0.9,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IsleSquircleBadge(
            icon: item.categoryIcon,
            color: tone,
            size: 34,
            iconSize: 17,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 1.5,
                      ),
                      decoration: BoxDecoration(
                        color: tone.withValues(alpha: dark ? 0.28 : 0.16),
                        borderRadius: BorderRadius.circular(IsleRadius.pill),
                      ),
                      child: Text(
                        item.countdownLabel,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: tone,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  dateParts.join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: palette['textSecondary'],
                  ),
                ),
                if (item.notes.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    item.notes.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: palette['textTertiary'],
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            key: ValueKey('familyReminderComplete-${item.id}'),
            visualDensity: VisualDensity.compact,
            tooltip: '打卡完成并推进下周期',
            onPressed: isBusy ? null : () => unawaited(_completeReminder(item)),
            icon: isBusy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    Icons.check_circle_outline_rounded,
                    size: 20,
                    color: palette['brandSage'],
                  ),
          ),
          if (_canEdit(item))
            PopupMenuButton<String>(
              tooltip: '更多提醒操作',
              icon: Icon(
                Icons.more_vert_rounded,
                size: 18,
                color: palette['textSecondary'],
              ),
              padding: EdgeInsets.zero,
              onSelected: (action) {
                if (action == 'edit') {
                  unawaited(_openEditor(existing: item));
                } else if (action == 'delete') {
                  unawaited(_deleteReminder(item));
                }
              },
              itemBuilder: (_) => [
                isleActionMenuItem(
                  value: 'edit',
                  label: '编辑提醒',
                  icon: Icons.edit_outlined,
                ),
                isleActionMenuItem(
                  value: 'delete',
                  label: '删除提醒',
                  icon: Icons.delete_outline_rounded,
                  destructive: true,
                ),
              ],
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final palette = IslePalette.of(context);
    final items = _snapshot.reminders;
    final visibleCount = _expanded ? items.length : items.length.clamp(0, 4);
    final lunarDisplay = _snapshot.todayLunar?.display.trim() ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IsleSectionHeader(
          title: '近期纪念日与家务',
          accentColor: palette['brandRose'],
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (lunarDisplay.isNotEmpty)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(
                      lunarDisplay,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: palette['textTertiary'],
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              TextButton.icon(
                key: const ValueKey('addFamilyReminderButton'),
                onPressed: () => unawaited(_openEditor()),
                icon: const Icon(Icons.add_alarm_rounded, size: 17),
                label: const Text('新建'),
              ),
            ],
          ),
        ),
        if (_error != null && items.isEmpty)
          Notice(
            '无法读取家庭提醒：$_error',
            onRetry: () => unawaited(_load()),
            error: true,
          )
        else if (items.isNotEmpty) ...[
          for (var i = 0; i < visibleCount; i++)
            _buildReminderRow(context, items[i], dark, palette),
          if (items.length > 4)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(
                  _expanded ? '收起列表' : '查看全部 ${items.length} 条提醒',
                ),
              ),
            ),
        ] else if (!_loading) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: palette['cardItemTop'],
              borderRadius: BorderRadius.circular(IsleRadius.card),
              border: Border.all(color: IsleGlass.rimBorderColor(dark)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.cake_outlined,
                  color: palette['brandRose'],
                  size: 21,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '还没有家庭纪念日或家务提醒',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '支持农历生日、结婚纪念日与换滤芯等周期家务打卡。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: palette['textTertiary'],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                TextButton(
                  onPressed: () => unawaited(_openEditor()),
                  child: const Text('去添加'),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Compact home entry card launching the family document/receipt OCR archive.
class OverviewDocumentScanShortcut extends StatelessWidget {
  const OverviewDocumentScanShortcut({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = IslePalette.of(context);
    final tone = palette['brandBlue'];
    return IsleSurface(
      key: const ValueKey('overviewDocumentScanEntry'),
      radius: IsleRadius.card,
      tint: tone,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      onTap: onTap,
      child: Row(
        children: [
          IsleSquircleBadge(
            icon: Icons.document_scanner_outlined,
            color: tone,
            size: 36,
            iconSize: 18,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '家庭档案 · 扫票据',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '拍证件/发票/保修卡，优先离线 Vision OCR 秒搜文字',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette['textSecondary'],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: palette['textTertiary'],
          ),
        ],
      ),
    );
  }
}
