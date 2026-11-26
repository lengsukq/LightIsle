import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/isle_theme.dart';
import '../../core/lightisle_api.dart';
import '../../core/widgets.dart';
import '../overview/family_board_card.dart';
import '../overview/family_reminders_card.dart';
import 'media_models.dart';
import 'media_ui.dart';

/// Shared clock/date/night-hour helpers used by both pure Photo Frame mode
/// and the Family Dashboard overlay.
String formatPhotoFrameClock(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';

String formatPhotoFrameSolarDate(DateTime value) {
  const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  return '${value.year}年${value.month}月${value.day}日 · '
      '${weekdays[value.weekday - 1]}';
}

bool isPhotoFrameNightHour(DateTime value) => value.hour >= 22 || value.hour < 7;

/// Platform channel bridge (`lightisle/device-display`) keeping idle iPad /
/// tablet screens awake while Photo Frame or Family Dashboard mode is open.
abstract final class DeviceDisplayKeepAwake {
  static const MethodChannel channel = MethodChannel('lightisle/device-display');

  static Future<void> setKeepScreenOn(bool enabled) async {
    try {
      await channel.invokeMethod<Object?>('setKeepScreenOn', <String, Object>{
        'enabled': enabled,
      });
    } on MissingPluginException {
      // Desktop platforms and widget tests without a native handler ignore this.
    } on PlatformException {
      // Never block photo frame presentation on display-lock channel errors.
    }
  }
}

/// Frosted-glass family dashboard overlay rendered on top of the ambient photo
/// frame slideshow for idle iPads and tablets.
class PhotoFrameDashboardOverlay extends StatefulWidget {
  const PhotoFrameDashboardOverlay({
    super.key,
    required this.api,
    required this.now,
    required this.albumTitle,
    required this.currentAsset,
    required this.currentIndex,
    required this.totalPhotos,
    this.nightDimOverride,
    this.refreshInterval = const Duration(minutes: 5),
    this.burnInShiftInterval = const Duration(seconds: 60),
  });

  final LightIsleApi api;
  final DateTime now;
  final String albumTitle;
  final PhotoAsset? currentAsset;
  final int currentIndex;
  final int totalPhotos;
  final bool? nightDimOverride;
  final Duration refreshInterval;
  final Duration burnInShiftInterval;

  @override
  State<PhotoFrameDashboardOverlay> createState() =>
      _PhotoFrameDashboardOverlayState();
}

class _PhotoFrameDashboardOverlayState
    extends State<PhotoFrameDashboardOverlay> {
  static const List<Offset> _burnInOffsets = <Offset>[
    Offset(0, 0),
    Offset(3, 2),
    Offset(-2, 3),
    Offset(-3, -2),
    Offset(2, -3),
  ];

  List<FamilyBoardMessage> _boardMessages = const [];
  FamilyRemindersSnapshot _reminders = const FamilyRemindersSnapshot();
  bool _refreshing = false;
  int _shiftStep = 0;

  Timer? _refreshTimer;
  Timer? _shiftTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshSilently());
    _refreshTimer = Timer.periodic(
      widget.refreshInterval,
      (_) => unawaited(_refreshSilently()),
    );
    _shiftTimer = Timer.periodic(widget.burnInShiftInterval, (_) {
      if (mounted) {
        setState(() => _shiftStep = (_shiftStep + 1) % _burnInOffsets.length);
      }
    });
  }

  @override
  void didUpdateWidget(covariant PhotoFrameDashboardOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) {
      unawaited(_refreshSilently());
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _shiftTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshSilently() async {
    if (_refreshing) return;
    _refreshing = true;
    List<FamilyBoardMessage>? nextMessages;
    FamilyRemindersSnapshot? nextReminders;

    await Future.wait<void>([
      () async {
        try {
          final res = await widget.api.get(
            '/api/v2/board/messages',
            query: const {'limit': '10'},
          );
          final parsed = objectList(res['messages'])
              .map(FamilyBoardMessage.fromJson)
              .where((m) => m.id > 0)
              .toList(growable: false);
          final pinned = parsed.where((m) => m.pinned).toList(growable: false);
          final regular = parsed.where((m) => !m.pinned).toList(growable: false);
          nextMessages = [...pinned, ...regular].take(2).toList(growable: false);
        } catch (_) {
          // Silent background refresh keeps last known snapshot.
        }
      }(),
      () async {
        try {
          nextReminders = await FamilyRemindersApi(widget.api).list(days: 14);
        } catch (_) {
          // Silent background refresh keeps last known snapshot.
        }
      }(),
    ]);

    _refreshing = false;
    if (!mounted) return;
    if (nextMessages != null || nextReminders != null) {
      setState(() {
        if (nextMessages != null) _boardMessages = nextMessages!;
        if (nextReminders != null) _reminders = nextReminders!;
      });
    }
  }

  bool get _isNightSoftGlow =>
      widget.nightDimOverride ?? isPhotoFrameNightHour(widget.now);

  Widget _glassPanel({
    required Widget child,
    required bool nightMode,
    EdgeInsetsGeometry padding = const EdgeInsets.all(16),
  }) {
    final bgAlpha = nightMode ? 0.56 : 0.42;
    final borderAlpha = nightMode ? 0.14 : 0.22;
    return ClipRRect(
      borderRadius: BorderRadius.circular(IsleRadius.hero),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Color.fromRGBO(14, 16, 22, bgAlpha),
            borderRadius: BorderRadius.circular(IsleRadius.hero),
            border: Border.all(
              color: Colors.white.withValues(alpha: borderAlpha),
              width: 1.0,
            ),
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _buildClockCard(
    bool nightMode,
    bool compact,
    IslePalette darkPalette,
  ) {
    final lunar = _reminders.todayLunar?.display.trim() ?? '';
    final primaryColor = nightMode ? const Color(0xFFD8D4CC) : Colors.white;
    final secondaryColor = nightMode
        ? const Color(0xB3D8D4CC)
        : const Color(0xE6FFFFFF);
    final mutedColor = nightMode
        ? const Color(0x8CD8D4CC)
        : const Color(0xBFFFFFFF);
    final warmAmber = darkPalette['brandAmber'];

    return _glassPanel(
      nightMode: nightMode,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 16 : 22,
        vertical: compact ? 14 : 18,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              Text(
                formatPhotoFrameClock(widget.now),
                style: TextStyle(
                  color: primaryColor,
                  fontSize: compact ? 44 : 62,
                  fontWeight: FontWeight.w600,
                  height: 1.0,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (nightMode)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: warmAmber.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(IsleRadius.pill),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.bedtime_rounded,
                          size: 12,
                          color: warmAmber,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '夜间柔光',
                          style: TextStyle(
                            color: warmAmber,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            formatPhotoFrameSolarDate(widget.now),
            style: TextStyle(
              color: secondaryColor,
              fontSize: compact ? 14 : 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (lunar.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              lunar,
              key: const ValueKey('dashboardLunarDateText'),
              style: TextStyle(
                color: warmAmber.withValues(
                  alpha: nightMode ? 0.88 : 0.98,
                ),
                fontSize: compact ? 13 : 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (widget.currentAsset != null) ...[
            const SizedBox(height: 8),
            Text(
              '${widget.albumTitle} · ${formatMediaDate(widget.currentAsset!.takenAt)}'
              '${widget.totalPhotos > 1 ? ' (${widget.currentIndex + 1}/${widget.totalPhotos})' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: mutedColor, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBoardCard(bool nightMode, IslePalette darkPalette) {
    final textColor = nightMode ? const Color(0xD9E2DDD5) : Colors.white;
    final subColor = nightMode ? const Color(0x99E2DDD5) : Colors.white70;
    final amber = darkPalette['brandAmber'];
    return _glassPanel(
      nightMode: nightMode,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        key: const ValueKey('dashboardBoardCard'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.forum_outlined,
                size: 15,
                color: amber,
              ),
              const SizedBox(width: 6),
              Text(
                '家庭留言板',
                style: TextStyle(
                  color: textColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_boardMessages.isEmpty)
            Text(
              '暂无家庭留言',
              style: TextStyle(color: subColor, fontSize: 12.5),
            )
          else
            for (var i = 0; i < _boardMessages.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 12,
                  color: Colors.white.withValues(alpha: 0.12),
                ),
              Row(
                children: [
                  if (_boardMessages[i].pinned) ...[
                    Icon(
                      Icons.push_pin_rounded,
                      size: 12,
                      color: amber,
                    ),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(
                      '${_boardMessages[i].authorUsername} · ${_boardMessages[i].tag}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: subColor,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                _boardMessages[i].content,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: textColor,
                  fontSize: 13.5,
                  height: 1.4,
                ),
              ),
            ],
        ],
      ),
    );
  }

  Widget _buildRemindersCard(bool nightMode, IslePalette darkPalette) {
    final textColor = nightMode ? const Color(0xD9E2DDD5) : Colors.white;
    final subColor = nightMode ? const Color(0x99E2DDD5) : Colors.white70;
    final items = _reminders.reminders.take(4).toList(growable: false);

    return _glassPanel(
      nightMode: nightMode,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        key: const ValueKey('dashboardRemindersCard'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.event_available_rounded,
                size: 15,
                color: darkPalette['brandRose'],
              ),
              const SizedBox(width: 6),
              Text(
                '未来 14 天提醒',
                style: TextStyle(
                  color: textColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (items.isEmpty)
            Text(
              '近期 14 天内无待办或纪念日',
              style: TextStyle(color: subColor, fontSize: 12.5),
            )
          else
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) const SizedBox(height: 6),
              Builder(
                builder: (_) {
                  final tone = items[i].resolveToneColor(darkPalette);
                  return Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: tone.withValues(alpha: 0.24),
                          borderRadius: BorderRadius.circular(IsleRadius.pill),
                        ),
                        child: Text(
                          items[i].countdownLabel,
                          style: TextStyle(
                            color: tone,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          items[i].title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: textColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        items[i].yearsBadge.isNotEmpty
                            ? items[i].yearsBadge
                            : items[i].nextSolarDate,
                        style: TextStyle(color: subColor, fontSize: 11.5),
                      ),
                    ],
                  );
                },
              ),
            ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final size = MediaQuery.sizeOf(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final nightMode = _isNightSoftGlow;
    final wide = size.width >= 760;
    final offset = reduceMotion ? Offset.zero : _burnInOffsets[_shiftStep];
    // Photo frame overlays sit permanently over a dark glass backdrop, so
    // always map semantic tones against the high-contrast dark palette.
    final darkPalette = IslePalette(
      true,
      preset: IslePalette.of(context).effectivePreset,
    );

    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (nightMode)
            const ColoredBox(
              key: ValueKey('dashboardNightDimScrim'),
              color: Color(0x57080604),
            ),
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                safe.left + (wide ? 28 : 16),
                safe.top + 68,
                safe.right + (wide ? 28 : 16),
                safe.bottom + (wide ? 24 : 16),
              ),
              child: Transform.translate(
                offset: offset,
                child: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 360),
                            child: _buildClockCard(nightMode, false, darkPalette),
                          ),
                          const Spacer(),
                          SizedBox(
                            width: 340,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _buildBoardCard(nightMode, darkPalette),
                                const SizedBox(height: 12),
                                _buildRemindersCard(nightMode, darkPalette),
                              ],
                            ),
                          ),
                        ],
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildClockCard(nightMode, true, darkPalette),
                          const SizedBox(height: 10),
                          _buildBoardCard(nightMode, darkPalette),
                          const SizedBox(height: 10),
                          _buildRemindersCard(nightMode, darkPalette),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
