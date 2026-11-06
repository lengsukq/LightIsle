import 'dart:async';
import 'package:flutter/material.dart';

/// An authorized server-side month entry. The cursor refers to the full
/// gallery, so dragging may seek beyond pages already held in memory.
class PhotoTimelineMonth {
  const PhotoTimelineMonth({
    required this.year,
    required this.month,
    required this.count,
    required this.firstIndex,
  });

  final int year;
  final int month;
  final int count;
  final int firstIndex;

  String get label => '$year 年 $month 月';

  static List<PhotoTimelineMonth> parse(Object? raw) {
    if (raw is! List) throw const FormatException('缺少年月索引');
    final months = <PhotoTimelineMonth>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final year = item['year'];
      final month = item['month'];
      final count = item['count'];
      final cursor = item['firstIndex'];
      if (year is! int ||
          year < 1970 ||
          year > 9999 ||
          month is! int ||
          month < 1 ||
          month > 12 ||
          count is! int ||
          count < 1 ||
          cursor is! int ||
          cursor < 0) {
        continue;
      }
      months.add(
        PhotoTimelineMonth(
          year: year,
          month: month,
          count: count,
          firstIndex: cursor,
        ),
      );
    }
    months.sort(
      (a, b) => b.year.compareTo(a.year) != 0
          ? b.year.compareTo(a.year)
          : b.month.compareTo(a.month),
    );
    return months;
  }
}

/// A high-performance, smooth fast-scrolling timeline scrollbar.
/// It synchronizes continuously with [scrollController] for 1:1 fluid dragging,
/// avoiding discrete snapping or intrusive opaque track backgrounds.
class PhotoTimelineScrubber extends StatefulWidget {
  const PhotoTimelineScrubber({
    required this.months,
    required this.onSelected,
    this.scrollController,
    this.activeFirstIndex,
    this.wide = false,
    super.key,
  });

  final List<PhotoTimelineMonth> months;
  final ValueChanged<PhotoTimelineMonth> onSelected;
  final ScrollController? scrollController;
  final int? activeFirstIndex;
  final bool wide;

  @override
  State<PhotoTimelineScrubber> createState() => _PhotoTimelineScrubberState();
}

class _PhotoTimelineScrubberState extends State<PhotoTimelineScrubber> {
  bool _isDragging = false;
  double _dragProgress = 0.0;
  double _scrollProgress = 0.0;
  bool _isHovered = false;
  bool _isVisible = true;
  Timer? _fadeTimer;

  int get _activeMonthIndex {
    final index = widget.months.indexWhere(
      (month) => month.firstIndex == widget.activeFirstIndex,
    );
    return index < 0 ? 0 : index;
  }

  double get _currentProgress {
    if (_isDragging) return _dragProgress;
    final controller = widget.scrollController;
    if (controller != null && controller.hasClients) {
      final pos = controller.position;
      if (pos.hasContentDimensions && pos.maxScrollExtent > 0) {
        return _scrollProgress;
      }
    }
    if (widget.months.isNotEmpty) {
      return (_activeMonthIndex / widget.months.length).clamp(0.0, 1.0);
    }
    return 0.0;
  }

  int get _displayedMonthIndex {
    if (widget.months.isEmpty) return 0;
    final p = _currentProgress;
    return (p * widget.months.length).floor().clamp(0, widget.months.length - 1);
  }

  @override
  void initState() {
    super.initState();
    widget.scrollController?.addListener(_onScroll);
    _syncScrollProgress();
    _resetFadeTimer();
  }

  @override
  void didUpdateWidget(covariant PhotoTimelineScrubber oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController?.removeListener(_onScroll);
      widget.scrollController?.addListener(_onScroll);
      _syncScrollProgress();
    }
  }

  @override
  void dispose() {
    _fadeTimer?.cancel();
    widget.scrollController?.removeListener(_onScroll);
    super.dispose();
  }

  void _syncScrollProgress() {
    final controller = widget.scrollController;
    if (controller != null && controller.hasClients) {
      final pos = controller.position;
      if (pos.hasContentDimensions && pos.maxScrollExtent > 0) {
        _scrollProgress = (pos.pixels / pos.maxScrollExtent).clamp(0.0, 1.0);
      }
    }
  }

  void _onScroll() {
    if (_isDragging || !mounted) return;
    final controller = widget.scrollController;
    if (controller != null && controller.hasClients) {
      final pos = controller.position;
      if (pos.hasContentDimensions && pos.maxScrollExtent > 0) {
        final newProgress = (pos.pixels / pos.maxScrollExtent).clamp(0.0, 1.0);
        if ((newProgress - _scrollProgress).abs() > 0.001) {
          setState(() {
            _scrollProgress = newProgress;
            _isVisible = true;
          });
          _resetFadeTimer();
        }
      }
    }
  }

  void _resetFadeTimer() {
    _fadeTimer?.cancel();
    _fadeTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted && !_isDragging && !_isHovered) {
        setState(() => _isVisible = false);
      }
    });
  }

  void _wakeUp() {
    if (!_isVisible) {
      setState(() => _isVisible = true);
    }
    _resetFadeTimer();
  }

  void _updateDrag(double localY, double height, double thumbHeight) {
    final available = height - thumbHeight;
    if (available <= 0) return;
    final progress = ((localY - thumbHeight / 2) / available).clamp(0.0, 1.0);

    setState(() {
      _dragProgress = progress;
      _isDragging = true;
      _isVisible = true;
    });

    final controller = widget.scrollController;
    if (controller != null && controller.hasClients) {
      final pos = controller.position;
      if (pos.hasContentDimensions && pos.maxScrollExtent > 0) {
        final targetPixels = progress * pos.maxScrollExtent;
        controller.jumpTo(targetPixels);
      }
    }
  }

  void _finishDrag() {
    if (!_isDragging) return;
    final finalProgress = _dragProgress;
    setState(() {
      _isDragging = false;
      _scrollProgress = finalProgress;
    });
    if (widget.months.isNotEmpty) {
      final index = (finalProgress * widget.months.length)
          .floor()
          .clamp(0, widget.months.length - 1);
      widget.onSelected(widget.months[index]);
    }
    _resetFadeTimer();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.months.length < 2) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, bounds) {
        final height = bounds.maxHeight;
        if (!height.isFinite || height < 100) return const SizedBox.shrink();

        final isInteractive = _isDragging || _isHovered;
        final thumbHeight = _isDragging ? 44.0 : (isInteractive ? 36.0 : 32.0);
        final thumbWidth = _isDragging ? 7.5 : (isInteractive ? 6.0 : 4.5);
        final trackWidth = widget.wide ? 48.0 : 38.0;

        // 连续且物理跟手的精确纵向位置计算，无动画延迟
        final availableHeight = height - thumbHeight;
        final thumbTop = (_currentProgress * availableHeight).clamp(0.0, availableHeight);
        final selectedMonthIndex = _displayedMonthIndex;
        final selectedMonth = widget.months[selectedMonthIndex];

        return Semantics(
          label: '按年月快速浏览照片',
          value: selectedMonth.label,
          increasedValue: widget
              .months[(selectedMonthIndex + 1).clamp(0, widget.months.length - 1)]
              .label,
          decreasedValue: widget
              .months[(selectedMonthIndex - 1).clamp(0, widget.months.length - 1)]
              .label,
          onIncrease: () => widget.onSelected(
            widget.months[(selectedMonthIndex + 1).clamp(
              0,
              widget.months.length - 1,
            )],
          ),
          onDecrease: () => widget.onSelected(
            widget.months[(selectedMonthIndex - 1).clamp(
              0,
              widget.months.length - 1,
            )],
          ),
          child: SizedBox(
            key: const ValueKey('photoTimelineScrubber'),
            width: widget.wide ? 180 : 156,
            height: height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // 完全透明但手势区域充裕的快速滚动条感应带
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  width: trackWidth,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) {
                      _wakeUp();
                      _updateDrag(details.localPosition.dy, height, thumbHeight);
                    },
                    onTapUp: (_) => _finishDrag(),
                    onVerticalDragStart: (details) {
                      _wakeUp();
                      _updateDrag(details.localPosition.dy, height, thumbHeight);
                    },
                    onVerticalDragUpdate: (details) {
                      _updateDrag(details.localPosition.dy, height, thumbHeight);
                    },
                    onVerticalDragEnd: (_) => _finishDrag(),
                    onVerticalDragCancel: () => setState(() => _isDragging = false),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      onEnter: (_) {
                        setState(() {
                          _isHovered = true;
                          _isVisible = true;
                        });
                        _wakeUp();
                      },
                      onExit: (_) {
                        setState(() => _isHovered = false);
                        _resetFadeTimer();
                      },
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 200),
                        opacity: _isVisible || isInteractive ? 1.0 : 0.35,
                        child: Stack(
                          children: [
                            // 拖拽或悬停时浮现的纤细参考线，平常不显示
                            AnimatedOpacity(
                              duration: const Duration(milliseconds: 160),
                              opacity: isInteractive ? 1.0 : 0.0,
                              child: Stack(
                                children: [
                                  Positioned(
                                    top: 14,
                                    bottom: 14,
                                    right: 6.5,
                                    child: Container(
                                      width: 1.5,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(1),
                                        color: scheme.outlineVariant
                                            .withValues(alpha: .35),
                                      ),
                                    ),
                                  ),
                                  for (var i = 0; i < widget.months.length; i++)
                                    if (i == 0 ||
                                        widget.months[i].year !=
                                            widget.months[i - 1].year)
                                      Positioned(
                                        top: ((i + .5) *
                                                height /
                                                widget.months.length)
                                            .clamp(8.0, height - 8.0),
                                        right: 9,
                                        child: Container(
                                          height: 1.5,
                                          width: 8,
                                          decoration: BoxDecoration(
                                            borderRadius:
                                                BorderRadius.circular(1),
                                            color: scheme.outlineVariant
                                                .withValues(alpha: .55),
                                          ),
                                        ),
                                      ),
                                ],
                              ),
                            ),
                            // 实时跟手位移的精致滚动条滑块（位置零延迟直接绘制）
                            Positioned(
                              top: thumbTop,
                              right: 3,
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 120),
                                curve: Curves.easeOutCubic,
                                width: thumbWidth,
                                height: thumbHeight,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(99),
                                  color: _isDragging
                                      ? scheme.primary
                                      : (isInteractive
                                          ? scheme.primary.withValues(alpha: .75)
                                          : scheme.onSurface
                                              .withValues(alpha: .4)),
                                  border: Border.all(
                                    color: _isDragging
                                        ? Colors.white.withValues(alpha: .65)
                                        : scheme.surface.withValues(alpha: .55),
                                    width: 0.5,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: _isDragging
                                          ? scheme.primary
                                              .withValues(alpha: .35)
                                          : Colors.black.withValues(alpha: .15),
                                      blurRadius: _isDragging ? 6 : 2,
                                      offset: const Offset(0, 1),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // 拖拽滚动时在滑块左侧浮现的年月指示气泡
                if (_isDragging)
                  Positioned(
                    right: trackWidth + 10,
                    top: (thumbTop + thumbHeight / 2 - 20.0)
                        .clamp(4.0, height - 48.0),
                    child: Material(
                      color: scheme.inverseSurface,
                      elevation: 4,
                      shadowColor: Colors.black38,
                      borderRadius: BorderRadius.circular(16),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 9,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Text(
                              selectedMonth.label,
                              style: TextStyle(
                                color: scheme.onInverseSurface,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                                letterSpacing: -0.2,
                              ),
                            ),
                            if (selectedMonth.count > 0) ...[
                              const SizedBox(width: 6),
                              Text(
                                '·  ${selectedMonth.count} 项',
                                style: TextStyle(
                                  color: scheme.onInverseSurface
                                      .withValues(alpha: .72),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
