import 'package:flutter/material.dart';

typedef PhotoExifFilterSelection = ({
  String camera,
  String location,
  int year,
  int takenFrom,
  int takenTo,
});

/// Bottom sheet letting users combine camera body, GPS status, year, or custom
/// date range facets before resetting the gallery timeline.
Future<PhotoExifFilterSelection?> showPhotoExifFilterSheet(
  BuildContext context, {
  required List<String> facetCameras,
  required List<int> facetYears,
  required String cameraFilter,
  required String locationFilter,
  required int yearFilter,
  required int takenFromFilter,
  required int takenToFilter,
}) async {
  var cam = cameraFilter;
  var loc = locationFilter;
  var yr = yearFilter;
  var fromSec = takenFromFilter;
  var toSec = takenToFilter;

  final applied = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, setSheetState) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('多维筛选', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                if (facetCameras.isNotEmpty)
                  DropdownButtonFormField<String>(
                    initialValue: cam,
                    decoration: const InputDecoration(labelText: '相机型号'),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('全部相机')),
                      for (final model in facetCameras)
                        DropdownMenuItem(value: model, child: Text(model)),
                    ],
                    onChanged: (v) => setSheetState(() => cam = v ?? ''),
                  ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: loc,
                  decoration: const InputDecoration(labelText: '地理位置'),
                  items: const [
                    DropdownMenuItem(value: '', child: Text('全部位置')),
                    DropdownMenuItem(value: '1', child: Text('含定位')),
                    DropdownMenuItem(value: '0', child: Text('无定位')),
                  ],
                  onChanged: (v) => setSheetState(() => loc = v ?? ''),
                ),
                if (facetYears.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: yr,
                    decoration: const InputDecoration(labelText: '拍摄年份'),
                    items: [
                      const DropdownMenuItem(value: 0, child: Text('全部年份')),
                      for (final y in facetYears)
                        DropdownMenuItem(value: y, child: Text('$y 年')),
                    ],
                    onChanged: (v) => setSheetState(() {
                      yr = v ?? 0;
                      if (yr > 0) {
                        fromSec = 0;
                        toSec = 0;
                      }
                    }),
                  ),
                ],
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    final now = DateTime.now();
                    final picked = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime(1970, 1, 1),
                      lastDate: DateTime(now.year + 1, 12, 31),
                      initialDateRange: fromSec > 0 && toSec > 0
                          ? DateTimeRange(
                              start: DateTime.fromMillisecondsSinceEpoch(
                                fromSec * 1000,
                              ),
                              end: DateTime.fromMillisecondsSinceEpoch(
                                toSec * 1000,
                              ),
                            )
                          : null,
                    );
                    if (picked != null) {
                      setSheetState(() {
                        yr = 0;
                        fromSec =
                            DateTime(
                              picked.start.year,
                              picked.start.month,
                              picked.start.day,
                            ).millisecondsSinceEpoch ~/
                            1000;
                        toSec =
                            DateTime(
                              picked.end.year,
                              picked.end.month,
                              picked.end.day,
                              23,
                              59,
                              59,
                            ).millisecondsSinceEpoch ~/
                            1000;
                      });
                    }
                  },
                  icon: const Icon(Icons.date_range_rounded, size: 18),
                  label: Text(
                    fromSec > 0 && toSec > 0 ? '已选自定义日期区间（点击重选）' : '按自定义日期区间筛选',
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () {
                        cam = '';
                        loc = '';
                        yr = 0;
                        fromSec = 0;
                        toSec = 0;
                        Navigator.pop(sheetContext, true);
                      },
                      child: const Text('重置'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.pop(sheetContext, true),
                      child: const Text('应用筛选'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  if (applied != true) return null;
  return (
    camera: cam,
    location: loc,
    year: yr,
    takenFrom: fromSec,
    takenTo: toSec,
  );
}
