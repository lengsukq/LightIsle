import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'family_reminders_card.dart';

const List<({String id, String label})> _reminderCategories = [
  (id: 'birthday', label: '生日'),
  (id: 'anniversary', label: '纪念日'),
  (id: 'chore', label: '家务'),
  (id: 'bill', label: '账单'),
  (id: 'custom', label: '自定义'),
];

const List<({String id, String label})> _repeatRules = [
  (id: 'yearly', label: '每年'),
  (id: 'monthly', label: '每月'),
  (id: 'weekly', label: '每周'),
  (id: 'interval_days', label: '每隔 N 天'),
  (id: 'once', label: '仅一次'),
];

const List<int> _advanceDayOptions = [0, 1, 3, 7, 15, 30];

const List<String> _lunarMonthNames = [
  '正月',
  '二月',
  '三月',
  '四月',
  '五月',
  '六月',
  '七月',
  '八月',
  '九月',
  '十月',
  '冬月',
  '腊月',
];

const List<String> _lunarDayNames = [
  '初一', '初二', '初三', '初四', '初五', '初六', '初七', '初八', '初九', '初十',
  '十一', '十二', '十三', '十四', '十五', '十六', '十七', '十八', '十九', '二十',
  '廿一', '廿二', '廿三', '廿四', '廿五', '廿六', '廿七', '廿八', '廿九', '三十',
];

Future<FamilyReminder?> showFamilyReminderSheet(
  BuildContext context, {
  required LightIsleApi api,
  FamilyReminder? existing,
}) {
  return showModalBottomSheet<FamilyReminder>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _FamilyReminderEditorSheet(api: api, existing: existing),
  );
}

class _FamilyReminderEditorSheet extends StatefulWidget {
  const _FamilyReminderEditorSheet({required this.api, this.existing});

  final LightIsleApi api;
  final FamilyReminder? existing;

  @override
  State<_FamilyReminderEditorSheet> createState() =>
      _FamilyReminderEditorSheetState();
}

class _FamilyReminderEditorSheetState
    extends State<_FamilyReminderEditorSheet> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _yearCtrl;
  late final TextEditingController _intervalCtrl;
  late final TextEditingController _notesCtrl;

  late String _category;
  late String _calendarType;
  late int _month;
  late int _day;
  late bool _isLeapMonth;
  late String _repeatRule;
  late Set<int> _remindDays;
  late bool _notifyEnabled;
  late String _color;

  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    final now = DateTime.now();
    _titleCtrl = TextEditingController(text: existing?.title ?? '');
    _yearCtrl = TextEditingController(
      text: existing != null && existing.year > 0 ? '${existing.year}' : '',
    );
    _intervalCtrl = TextEditingController(
      text: existing != null && existing.intervalDays > 0
          ? '${existing.intervalDays}'
          : '7',
    );
    _notesCtrl = TextEditingController(text: existing?.notes ?? '');
    _category = existing?.category ?? 'birthday';
    _calendarType = existing?.calendarType ?? 'solar';
    _month = (existing?.month ?? now.month).clamp(1, 12);
    _day = (existing?.day ?? now.day).clamp(1, _maxDaysInMonth);
    _isLeapMonth = existing?.isLeapMonth ?? false;
    _repeatRule = existing?.repeatRule ?? 'yearly';
    _remindDays = existing != null && existing.remindDays.isNotEmpty
        ? existing.remindDays.toSet()
        : {7, 1, 0};
    _notifyEnabled = existing?.notifyEnabled ?? true;
    _color = existing?.color ?? 'amber';
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _yearCtrl.dispose();
    _intervalCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  int get _maxDaysInMonth => _calendarType == 'lunar' ? 30 : 31;

  List<({String id, String label})> get _availableRepeatRules =>
      _calendarType == 'lunar'
      ? const [
          (id: 'yearly', label: '每年'),
          (id: 'once', label: '仅一次'),
        ]
      : _repeatRules;

  void _onCalendarTypeChanged(String next) {
    if (_calendarType == next) return;
    setState(() {
      _calendarType = next;
      if (next == 'lunar') {
        if (_day > 30) _day = 30;
        if (_repeatRule != 'yearly' && _repeatRule != 'once') {
          _repeatRule = 'yearly';
        }
      } else {
        _isLeapMonth = false;
      }
      _error = null;
    });
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      setState(() => _error = '请输入提醒标题。');
      return;
    }

    var year = 0;
    final rawYear = _yearCtrl.text.trim();
    if (rawYear.isNotEmpty) {
      final parsedYear = int.tryParse(rawYear);
      if (parsedYear == null || parsedYear < 1900 || parsedYear > 2100) {
        setState(() => _error = '年份需在 1900 到 2100 之间，或留空。');
        return;
      }
      year = parsedYear;
    }

    var intervalDays = 0;
    if (_repeatRule == 'interval_days') {
      final parsed = int.tryParse(_intervalCtrl.text.trim());
      if (parsed == null || parsed < 1 || parsed > 3650) {
        setState(() => _error = '重复间隔天数需在 1 到 3650 之间。');
        return;
      }
      intervalDays = parsed;
    }

    final sortedRemind = _remindDays.toList()..sort((a, b) => b.compareTo(a));
    final effectiveYear =
        (year == 0 && (_repeatRule == 'once' || _repeatRule == 'weekly' || _repeatRule == 'interval_days'))
        ? DateTime.now().year
        : year;

    final body = <String, dynamic>{
      'title': title,
      'category': _category,
      'calendarType': _calendarType,
      'year': effectiveYear,
      'month': _month,
      'day': _day,
      'isLeapMonth': _calendarType == 'lunar' ? _isLeapMonth : false,
      'repeatRule': _repeatRule,
      'intervalDays': _repeatRule == 'interval_days' ? intervalDays : 0,
      'remindDays': sortedRemind.isEmpty ? const [0] : sortedRemind,
      'notifyEnabled': _notifyEnabled,
      'color': _color,
      'notes': _notesCtrl.text.trim(),
    };

    if (_calendarType == 'solar' && effectiveYear >= 1900) {
      final mm = _month.toString().padLeft(2, '0');
      final dd = _day.toString().padLeft(2, '0');
      if (_repeatRule == 'once' ||
          _repeatRule == 'weekly' ||
          _repeatRule == 'interval_days') {
        body['nextSolarDate'] = '$effectiveYear-$mm-$dd';
      }
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final helper = FamilyRemindersApi(widget.api);
      final saved = widget.existing == null
          ? await helper.create(body)
          : await helper.update(widget.existing!.id, body);
      if (mounted) Navigator.of(context).pop(saved);
    } catch (error) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = userFacingError(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final editing = widget.existing != null;
    final dayCount = _maxDaysInMonth;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 14, 20, bottomInset + 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  editing ? '编辑家庭提醒' : '新建纪念日或家务提醒',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '关闭',
                  onPressed: _submitting ? null : () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('reminderTitleField'),
              controller: _titleCtrl,
              enabled: !_submitting,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: '提醒标题',
                hintText: '例如：妈妈农历生日、结婚纪念日、更换净水器滤芯',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text('提醒类别', style: theme.textTheme.labelMedium),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final item in _reminderCategories)
                  ChoiceChip(
                    label: Text(item.label),
                    selected: _category == item.id,
                    onSelected: _submitting
                        ? null
                        : (_) => setState(() => _category = item.id),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text('历法', style: theme.textTheme.labelMedium),
                const SizedBox(width: 12),
                ChoiceChip(
                  key: const ValueKey('reminderSolarChip'),
                  label: const Text('公历'),
                  selected: _calendarType == 'solar',
                  onSelected: _submitting
                      ? null
                      : (_) => _onCalendarTypeChanged('solar'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  key: const ValueKey('reminderLunarChip'),
                  label: const Text('农历'),
                  selected: _calendarType == 'lunar',
                  onSelected: _submitting
                      ? null
                      : (_) => _onCalendarTypeChanged('lunar'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  flex: 4,
                  child: TextField(
                    key: const ValueKey('reminderYearField'),
                    controller: _yearCtrl,
                    enabled: !_submitting,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '年份（可选）',
                      hintText: '如 1990',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 4,
                  child: DropdownButtonFormField<int>(
                    key: ValueKey('month-$_calendarType'),
                    initialValue: _month,
                    decoration: const InputDecoration(
                      labelText: '月',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (var m = 1; m <= 12; m++)
                        DropdownMenuItem<int>(
                          value: m,
                          child: Text(
                            _calendarType == 'lunar'
                                ? _lunarMonthNames[m - 1]
                                : '$m 月',
                          ),
                        ),
                    ],
                    onChanged: _submitting
                        ? null
                        : (v) {
                            if (v != null) setState(() => _month = v);
                          },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 4,
                  child: DropdownButtonFormField<int>(
                    key: ValueKey('day-$_calendarType'),
                    initialValue: _day.clamp(1, dayCount),
                    decoration: const InputDecoration(
                      labelText: '日',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (var d = 1; d <= dayCount; d++)
                        DropdownMenuItem<int>(
                          value: d,
                          child: Text(
                            _calendarType == 'lunar'
                                ? _lunarDayNames[d - 1]
                                : '$d 日',
                          ),
                        ),
                    ],
                    onChanged: _submitting
                        ? null
                        : (v) {
                            if (v != null) setState(() => _day = v);
                          },
                  ),
                ),
              ],
            ),
            if (_calendarType == 'lunar') ...[
              const SizedBox(height: 4),
              SwitchListTile(
                key: const ValueKey('reminderLeapMonthSwitch'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('闰月日期'),
                subtitle: const Text('若当年无对应闰月，系统将自动顺延按同月平月提醒'),
                value: _isLeapMonth,
                onChanged: _submitting
                    ? null
                    : (v) => setState(() => _isLeapMonth = v),
              ),
            ],
            const SizedBox(height: 10),
            Text('重复周期', style: theme.textTheme.labelMedium),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final rule in _availableRepeatRules)
                  ChoiceChip(
                    label: Text(rule.label),
                    selected: _repeatRule == rule.id,
                    onSelected: _submitting
                        ? null
                        : (_) => setState(() => _repeatRule = rule.id),
                  ),
              ],
            ),
            if (_repeatRule == 'interval_days') ...[
              const SizedBox(height: 8),
              TextField(
                controller: _intervalCtrl,
                enabled: !_submitting,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '每隔几天重复',
                  hintText: '例如 30',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text('提前提醒天数', style: theme.textTheme.labelMedium),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final d in _advanceDayOptions)
                  FilterChip(
                    label: Text(d == 0 ? '当天' : '提前 $d 天'),
                    selected: _remindDays.contains(d),
                    onSelected: _submitting
                        ? null
                        : (selected) {
                            setState(() {
                              if (selected) {
                                _remindDays.add(d);
                              } else if (_remindDays.length > 1) {
                                _remindDays.remove(d);
                              }
                            });
                          },
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text('卡片色调', style: theme.textTheme.labelMedium),
                const SizedBox(width: 10),
                for (final item in familyReminderColors)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: _submitting
                          ? null
                          : () => setState(() => _color = item.id),
                      child: AnimatedContainer(
                        duration: IsleMotion.fast,
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: item.color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _color == item.id
                                ? theme.colorScheme.onSurface
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('启用到期通知'),
              value: _notifyEnabled,
              onChanged: _submitting
                  ? null
                  : (v) => setState(() => _notifyEnabled = v),
            ),
            TextField(
              controller: _notesCtrl,
              enabled: !_submitting,
              maxLength: 300,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: '备注（可选）',
                hintText: '补充礼品清单、滤芯型号或交费账号提示…',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 6),
              Text(
                _error!,
                style: TextStyle(
                  color: theme.colorScheme.error,
                  fontSize: 12.5,
                ),
              ),
            ],
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const ValueKey('reminderSubmitButton'),
              onPressed: _submitting ? null : _submit,
              icon: const Icon(Icons.check_rounded, size: 18),
              label: Text(
                _submitting
                    ? '保存中…'
                    : (editing ? '保存修改' : '创建提醒'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
