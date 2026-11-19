import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/isle_theme.dart';
import '../../core/widgets.dart';

/// Visual theme gallery & brightness mode settings page for LightIsle Flutter.
class AppearancePage extends StatelessWidget {
  const AppearancePage({super.key, this.controller});

  /// Optional override for isolated widget tests.
  final IsleThemeController? controller;

  @override
  Widget build(BuildContext context) {
    final activeController = controller ?? IsleThemeScope.maybeOf(context);
    final palette = IslePalette.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (activeController == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: const IsleAppBar(title: Text('外观与主题')),
        body: IsleListView(
          children: const [
            Notice('当前页面未连接到主题控制器，请从主应用设置页进入。'),
          ],
        ),
      );
    }

    return AnimatedBuilder(
      animation: activeController,
      builder: (context, _) {
        final currentPreset = activeController.preset;
        final currentMode = activeController.themeMode;
        final isDefault =
            currentPreset.id == IsleThemePresetId.warmGallery &&
            currentMode == ThemeMode.system;

        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: IsleAppBar(
            title: const Text('外观与主题'),
            actions: [
              if (!isDefault)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: TextButton.icon(
                    key: const Key('appearanceResetButton'),
                    onPressed: () {
                      HapticFeedback.selectionClick();
                      unawaited(activeController.reset());
                    },
                    icon: const Icon(Icons.restart_alt_rounded, size: 17),
                    label: const Text('恢复默认'),
                  ),
                ),
            ],
          ),
          body: IsleListView(
            maxWidth: IsleLayout.secondaryPageWidth,
            children: [
              IslePageHeader(
                title: '外观与主题',
                subtitle: '自由切换明暗模式与 5 套风格迥异的内置界面主题，所有更改即时生效并自动保存在本机。',
                accentColor: palette['accentPrimary'],
              ),
              IsleSectionHeader(
                title: '明暗模式',
                accentColor: palette['accentPrimary'],
                padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
              ),
              IsleSurface(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SegmentedButton<ThemeMode>(
                      key: const Key('appearanceThemeModeSelector'),
                      showSelectedIcon: false,
                      segments: const <ButtonSegment<ThemeMode>>[
                        ButtonSegment<ThemeMode>(
                          value: ThemeMode.system,
                          icon: Icon(Icons.brightness_auto_rounded, size: 17),
                          label: Text('跟随系统'),
                        ),
                        ButtonSegment<ThemeMode>(
                          value: ThemeMode.light,
                          icon: Icon(Icons.light_mode_rounded, size: 17),
                          label: Text('浅色'),
                        ),
                        ButtonSegment<ThemeMode>(
                          value: ThemeMode.dark,
                          icon: Icon(Icons.dark_mode_rounded, size: 17),
                          label: Text('深色'),
                        ),
                      ],
                      selected: <ThemeMode>{currentMode},
                      onSelectionChanged: (selection) {
                        if (selection.isEmpty) return;
                        HapticFeedback.selectionClick();
                        unawaited(
                          activeController.setThemeMode(selection.first),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      switch (currentMode) {
                        ThemeMode.system => '自动跟随当前设备的系统深浅色外观切换。',
                        ThemeMode.light => '始终使用当前主题的浅色版本。',
                        ThemeMode.dark => '始终使用当前主题的深色版本。',
                      },
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              IsleSectionHeader(
                title: '内置主题风格',
                accentColor: palette['accentSecondary'],
                padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
              ),
              IsleResponsiveGrid(
                minItemWidth: 260,
                maxColumns: 3,
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final preset in IsleThemePresets.all)
                    _ThemePresetCard(
                      preset: preset,
                      previewDark: switch (currentMode) {
                        ThemeMode.dark => true,
                        ThemeMode.light => false,
                        ThemeMode.system => isDark,
                      },
                      selected: preset.id == currentPreset.id,
                      onSelect: () {
                        HapticFeedback.selectionClick();
                        unawaited(activeController.setPreset(preset.id));
                      },
                    ),
                ],
              ),
              const SizedBox(height: 14),
              IsleSectionHeader(
                title: '当前主题实时预览',
                accentColor: palette['brandSage'],
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
              ),
              _LiveComponentPreview(preset: currentPreset),
            ],
          ),
        );
      },
    );
  }
}

class _ThemePresetCard extends StatelessWidget {
  const _ThemePresetCard({
    required this.preset,
    required this.previewDark,
    required this.selected,
    required this.onSelect,
  });

  final IsleThemePreset preset;
  final bool previewDark;
  final bool selected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final previewStyle = IsleThemeStyle(preset: preset, dark: previewDark);
    final previewPalette = previewStyle.palette;
    final swatches = preset.previewSwatches(previewDark);

    return IsleSurface(
      key: Key('themePresetCard_${preset.id.storageKey}'),
      onTap: onSelect,
      tint: selected ? colors.primary : null,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ThemeMiniaturePreview(
            preset: preset,
            style: previewStyle,
            palette: previewPalette,
            dark: previewDark,
            selected: selected,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  preset.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IsleBadgePill(
                label: selected ? '使用中' : preset.badgeLabel,
                color: selected ? colors.primary : previewPalette['accentPrimary'],
                icon: selected ? Icons.check_rounded : null,
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            preset.tagline,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (var i = 0; i < swatches.length; i++) ...[
                Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: swatches[i],
                    shape: preset.cornerStyle == IsleCornerStyle.sharp
                        ? BoxShape.rectangle
                        : BoxShape.circle,
                    borderRadius: preset.cornerStyle == IsleCornerStyle.sharp
                        ? BorderRadius.circular(3)
                        : null,
                    border: Border.all(
                      color: colors.outlineVariant.withValues(alpha: 0.75),
                      width: 0.9,
                    ),
                  ),
                ),
                if (i < swatches.length - 1) const SizedBox(width: 6),
              ],
              const Spacer(),
              Text(
                _materialSummary(preset.surfaceMaterial),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _materialSummary(IsleSurfaceMaterial material) =>
      switch (material) {
        IsleSurfaceMaterial.paperEmbossed => '浮雕纸面',
        IsleSurfaceMaterial.frostedGlass => '磨砂玻璃',
        IsleSurfaceMaterial.flatHairline => '极简细线',
        IsleSurfaceMaterial.neoBrutal => '粗框硬影',
        IsleSurfaceMaterial.terminalGlow => '网格微光',
      };
}

class _ThemeMiniaturePreview extends StatelessWidget {
  const _ThemeMiniaturePreview({
    required this.preset,
    required this.style,
    required this.palette,
    required this.dark,
    required this.selected,
  });

  final IsleThemePreset preset;
  final IsleThemeStyle style;
  final IslePalette palette;
  final bool dark;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final outerRadius = style.borderRadiusFor(IsleRadius.md);
    final miniCardShape = style.shapeFor(
      IsleRadius.sm,
      side: BorderSide(
        color: style.rimBorderColor(),
        width: preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal
            ? 1.7
            : 0.9,
      ),
    );
    final primary = palette['accentPrimary'];
    final secondary = palette['accentSecondary'];

    return Container(
      height: 102,
      decoration: BoxDecoration(
        borderRadius: outerRadius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [palette['canvasTop'], palette['canvasBottom']],
        ),
        border: Border.all(
          color: selected ? primary : style.rimBorderColor(),
          width: selected ? 1.8 : 1.0,
        ),
      ),
      child: ClipRRect(
        borderRadius: outerRadius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildMiniBackdrop(),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 24,
                        height: 6,
                        decoration: BoxDecoration(
                          color: palette['textPrimary'].withValues(alpha: 0.78),
                          borderRadius: style.borderRadiusFor(IsleRadius.xs),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Container(
                        width: 14,
                        height: 6,
                        decoration: BoxDecoration(
                          color: primary,
                          borderRadius: style.borderRadiusFor(IsleRadius.xs),
                        ),
                      ),
                      const Spacer(),
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: secondary,
                          shape: preset.cornerStyle == IsleCornerStyle.sharp
                              ? BoxShape.rectangle
                              : BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 7,
                      ),
                      decoration: ShapeDecoration(
                        shape: miniCardShape,
                        color: preset.surfaceMaterial ==
                                IsleSurfaceMaterial.frostedGlass
                            ? palette['cardTop'].withValues(
                                alpha: dark ? 0.68 : 0.78,
                              )
                            : palette['cardTop'],
                        shadows: preset.surfaceMaterial ==
                                IsleSurfaceMaterial.neoBrutal
                            ? [
                                BoxShadow(
                                  color: palette['shadow'],
                                  blurRadius: 0,
                                  offset: const Offset(3, 3),
                                ),
                              ]
                            : preset.surfaceMaterial ==
                                  IsleSurfaceMaterial.terminalGlow
                            ? [
                                BoxShadow(
                                  color: primary.withValues(alpha: 0.25),
                                  blurRadius: 8,
                                ),
                              ]
                            : const [],
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: primary.withValues(
                                alpha: dark ? 0.24 : 0.14,
                              ),
                              borderRadius: style.borderRadiusFor(
                                IsleRadius.xs,
                              ),
                              border: Border.all(
                                color: primary.withValues(alpha: 0.45),
                                width: 0.8,
                              ),
                            ),
                            child: Icon(
                              Icons.cloud_done_rounded,
                              size: 13,
                              color: primary,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  height: 6,
                                  width: double.infinity,
                                  decoration: BoxDecoration(
                                    color: palette['textPrimary'].withValues(
                                      alpha: 0.72,
                                    ),
                                    borderRadius: style.borderRadiusFor(4),
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Container(
                                  height: 4.5,
                                  width: 58,
                                  decoration: BoxDecoration(
                                    color: palette['secondaryText'].withValues(
                                      alpha: 0.55,
                                    ),
                                    borderRadius: style.borderRadiusFor(4),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            width: 24,
                            height: 14,
                            decoration: BoxDecoration(
                              color: primary,
                              borderRadius: style.borderRadiusFor(
                                preset.cornerStyle == IsleCornerStyle.sharp
                                    ? 6
                                    : IsleRadius.pill,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMiniBackdrop() {
    return switch (preset.canvasBackdrop) {
      IsleCanvasBackdrop.warmGlow => Positioned(
        top: -20,
        right: -18,
        width: 90,
        height: 70,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              colors: [
                palette['brandAmber'].withValues(alpha: 0.22),
                Colors.transparent,
              ],
            ),
          ),
        ),
      ),
      IsleCanvasBackdrop.auroraGlow => Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: -24,
            left: -16,
            width: 110,
            height: 80,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [
                    palette['accentPrimary'].withValues(alpha: 0.34),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -24,
            right: -14,
            width: 100,
            height: 76,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [
                    palette['accentSecondary'].withValues(alpha: 0.28),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      IsleCanvasBackdrop.flatRule => Align(
        alignment: Alignment.topCenter,
        child: Container(height: 3, color: palette['accentPrimary']),
      ),
      IsleCanvasBackdrop.dotMatrix => CustomPaint(
        painter: _MiniPatternPainter(
          dots: true,
          color: palette['rim'].withValues(alpha: 0.22),
        ),
      ),
      IsleCanvasBackdrop.techGrid => CustomPaint(
        painter: _MiniPatternPainter(
          dots: false,
          color: palette['accentPrimary'].withValues(alpha: 0.16),
        ),
      ),
    };
  }
}

class _MiniPatternPainter extends CustomPainter {
  const _MiniPatternPainter({required this.dots, required this.color});

  final bool dots;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    if (dots) {
      for (double y = 8; y < size.height; y += 12) {
        for (double x = 8; x < size.width; x += 12) {
          canvas.drawCircle(Offset(x, y), 1.0, paint);
        }
      }
      return;
    }
    paint.strokeWidth = 0.7;
    for (double x = 0; x < size.width; x += 16) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += 16) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _MiniPatternPainter oldDelegate) =>
      oldDelegate.dots != dots || oldDelegate.color != color;
}

class _LiveComponentPreview extends StatelessWidget {
  const _LiveComponentPreview({required this.preset});

  final IsleThemePreset preset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = IslePalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IsleResponsiveGrid(
          minItemWidth: 260,
          maxColumns: 2,
          spacing: 12,
          runSpacing: 12,
          children: [
            IsleBentoStatCard(
              title: '存储池 · 仪表盘样式',
              value: '3.2 / 8.0 TiB',
              detail: '${preset.displayName} · 在线稳定',
              icon: Icons.storage_rounded,
              color: palette['accentPrimary'],
              progress: 0.42,
            ),
            IsleBentoStatCard(
              title: '家庭图库 · 相册样式',
              value: '18,420 项',
              detail: '原画同步已完成',
              icon: Icons.photo_library_rounded,
              color: palette['brandRose'],
              progress: 0.86,
            ),
          ],
        ),
        const SizedBox(height: 12),
        IsleSurface(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IsleSquircleBadge(
                    icon: Icons.folder_rounded,
                    color: palette['brandAmber'],
                    size: 34,
                    iconSize: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '文件与控件预览 · ${preset.displayName}',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '同步预览画布纹理、边框粗细、圆角几何、阴影与按钮质感。',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  IsleStatusBadge(label: '在线', color: palette['brandSage']),
                ],
              ),
              const SizedBox(height: 12),
              const LinearProgressIndicator(value: 0.64),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: () {},
                    icon: const Icon(Icons.cloud_upload_outlined, size: 17),
                    label: const Text('主操作按钮'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {},
                    icon: const Icon(Icons.tune_rounded, size: 17),
                    label: const Text('次级按钮'),
                  ),
                  IslePillButton(
                    label: '胶囊标签',
                    icon: Icons.auto_awesome_rounded,
                    variant: IslePillVariant.tonal,
                    accent: palette['accentSecondary'],
                    onPressed: () {},
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
