import 'package:flutter/material.dart';

import '../../core/lightisle_api.dart';
import '../../core/user_facing_error.dart';
import '../../core/widgets.dart';
import 'media_models.dart';

const _cityPresets = <(String, double, double)>[
  ('北京', 39.9042, 116.4074),
  ('上海', 31.2304, 121.4737),
  ('深圳', 22.5431, 114.0579),
  ('杭州', 30.2741, 120.1551),
  ('成都', 30.5728, 104.0668),
  ('三亚', 18.2528, 109.5120),
];

/// Opens a modal dialog to non-destructively override capture date/time and GPS
/// coordinates in LightIsle's derived gallery index without touching original files.
Future<bool> showPhotoMetadataEditDialog(
  BuildContext context, {
  required LightIsleApi api,
  required List<PhotoAsset> assets,
}) async {
  if (assets.isEmpty) return false;
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => _PhotoMetadataEditDialog(api: api, assets: assets),
  );
  return result == true;
}

class _PhotoMetadataEditDialog extends StatefulWidget {
  const _PhotoMetadataEditDialog({required this.api, required this.assets});

  final LightIsleApi api;
  final List<PhotoAsset> assets;

  @override
  State<_PhotoMetadataEditDialog> createState() =>
      _PhotoMetadataEditDialogState();
}

class _PhotoMetadataEditDialogState extends State<_PhotoMetadataEditDialog> {
  DateTime? _pickedDateTime;
  late final TextEditingController _latCtrl;
  late final TextEditingController _lonCtrl;
  bool _clearLocation = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final first = widget.assets.first;
    if (first.takenAt > 0) {
      _pickedDateTime = DateTime.fromMillisecondsSinceEpoch(
        first.takenAt * 1000,
      );
    }
    _latCtrl = TextEditingController(
      text: widget.assets.length == 1 && first.latitude != null
          ? first.latitude!.toStringAsFixed(5)
          : '',
    );
    _lonCtrl = TextEditingController(
      text: widget.assets.length == 1 && first.longitude != null
          ? first.longitude!.toStringAsFixed(5)
          : '',
    );
  }

  @override
  void dispose() {
    _latCtrl.dispose();
    _lonCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDateAndTime() async {
    final initial = _pickedDateTime ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1970),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (!mounted) return;
    setState(() {
      _pickedDateTime = DateTime(
        date.year,
        date.month,
        date.day,
        time?.hour ?? initial.hour,
        time?.minute ?? initial.minute,
      );
      _error = null;
    });
  }

  Future<void> _submit({bool reset = false}) async {
    if (_busy) return;
    final ids = widget.assets.map((a) => a.id).where((id) => id > 0).toList();
    if (ids.isEmpty) return;

    final body = <String, dynamic>{'ids': ids};
    if (reset) {
      body['reset'] = true;
    } else {
      if (_pickedDateTime != null) {
        body['takenAt'] = _pickedDateTime!.millisecondsSinceEpoch ~/ 1000;
      }
      if (_clearLocation) {
        body['clearLocation'] = true;
      } else if (_latCtrl.text.trim().isNotEmpty ||
          _lonCtrl.text.trim().isNotEmpty) {
        final lat = double.tryParse(_latCtrl.text.trim());
        final lon = double.tryParse(_lonCtrl.text.trim());
        if (lat == null ||
            lon == null ||
            lat < -90 ||
            lat > 90 ||
            lon < -180 ||
            lon > 180) {
          setState(() => _error = '请输入合法经纬度（纬度 -90~90，经度 -180~180）。');
          return;
        }
        body['latitude'] = lat;
        body['longitude'] = lon;
      }
      if (!body.containsKey('takenAt') &&
          !body.containsKey('latitude') &&
          !_clearLocation) {
        setState(() => _error = '请至少选择拍摄时间、填写坐标或勾选清除位置。');
        return;
      }
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.send('PATCH', '/api/v2/photos/metadata', body: body);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _error = '保存修正失败：${userFacingError(e)}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.assets.length;
    final dateLabel = _pickedDateTime == null
        ? '未选择拍摄时间'
        : '${_pickedDateTime!.year}-${_pickedDateTime!.month.toString().padLeft(2, '0')}-${_pickedDateTime!.day.toString().padLeft(2, '0')} '
              '${_pickedDateTime!.hour.toString().padLeft(2, '0')}:${_pickedDateTime!.minute.toString().padLeft(2, '0')}';

    return AlertDialog(
      title: Text(count > 1 ? '批量修正时间与地点（$count 项）' : '修正拍摄时间与地点'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '修正结果仅写入轻屿元数据索引，绝不修改硬盘原片；时间线与足迹地图会立即更新。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (_error != null) ...[
                Notice(_error!, error: true),
                const SizedBox(height: 10),
              ],
              OutlinedButton.icon(
                onPressed: _busy ? null : _pickDateAndTime,
                icon: const Icon(Icons.calendar_today_rounded, size: 16),
                label: Text('拍摄时间：$dateLabel'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _latCtrl,
                      enabled: !_busy && !_clearLocation,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                        signed: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: '纬度',
                        hintText: '39.9042',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _lonCtrl,
                      enabled: !_busy && !_clearLocation,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                        signed: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: '经度',
                        hintText: '116.4074',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final (name, lat, lon) in _cityPresets)
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      label: Text(name),
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _clearLocation = false;
                              _latCtrl.text = lat.toStringAsFixed(4);
                              _lonCtrl.text = lon.toStringAsFixed(4);
                            }),
                    ),
                ],
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _clearLocation,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _clearLocation = v == true),
                title: const Text('清除已有位置信息（从足迹地图隐藏）'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => _submit(reset: true),
          child: const Text('恢复原片 EXIF'),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : () => _submit(),
          child: Text(_busy ? '保存中…' : '保存修正'),
        ),
      ],
    );
  }
}
