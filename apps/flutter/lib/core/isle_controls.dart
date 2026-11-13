import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'isle_theme.dart';

enum IslePillVariant { primary, tonal, glass, danger }

/// Unified iOS capsule button for primary actions (+ 上传), selection toggles (选择/完成),
/// navigation back pills (< 返回仪表盘), and semantic actions.
class IslePillButton extends StatefulWidget {
  const IslePillButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.variant = IslePillVariant.tonal,
    this.accent,
    this.compact = false,
    this.selected = false,
    this.tooltip,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final IslePillVariant variant;
  final Color? accent;
  final bool compact;
  final bool selected;
  final String? tooltip;

  @override
  State<IslePillButton> createState() => _IslePillButtonState();
}

class _IslePillButtonState extends State<IslePillButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final disabled = widget.onPressed == null;
    final reducedMotion = IsleMotion.reducedMotion(context);
    final isPrimary = widget.variant == IslePillVariant.primary;
    final isDanger = widget.variant == IslePillVariant.danger;
    final tone = isDanger ? colors.error : (widget.accent ?? colors.primary);

    final fg = disabled
        ? colors.onSurfaceVariant.withValues(alpha: 0.45)
        : isPrimary
        ? (dark ? const Color(0xff0b1324) : Colors.white)
        : (isDanger ||
              widget.selected ||
              widget.variant == IslePillVariant.tonal)
        ? tone
        : colors.onSurface;

    final decoration = disabled
        ? BoxDecoration(
            color: colors.surfaceContainerHighest.withValues(alpha: 0.45),
            borderRadius: IsleRadius.brPill,
          )
        : IsleDecorations.capsuleControl(
            context,
            selected:
                widget.selected || widget.variant == IslePillVariant.tonal,
            accent: tone,
            prominent: isPrimary,
            danger: isDanger,
          );

    Widget button = Material(
      color: Colors.transparent,
      borderRadius: IsleRadius.brPill,
      child: InkWell(
        borderRadius: IsleRadius.brPill,
        onHighlightChanged: disabled || reducedMotion ? null : _setPressed,
        onTap: widget.onPressed == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                widget.onPressed!();
              },
        child: AnimatedContainer(
          duration: reducedMotion ? Duration.zero : IsleMotion.fast,
          curve: IsleMotion.spring,
          constraints: BoxConstraints(minHeight: widget.compact ? 34 : 38),
          padding: EdgeInsets.symmetric(
            horizontal: widget.compact ? 11 : 14,
            vertical: widget.compact ? 6 : 8,
          ),
          decoration: decoration,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: widget.compact ? 15.5 : 17, color: fg),
                SizedBox(width: widget.compact ? 5 : 6),
              ],
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: widget.compact ? 12.5 : 13.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.15,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (!disabled && !reducedMotion) {
      button = AnimatedScale(
        scale: _pressed ? IsleMotion.pressScale : 1.0,
        duration: IsleMotion.micro,
        curve: IsleMotion.spring,
        child: button,
      );
    }
    button = RepaintBoundary(child: button);

    if (widget.tooltip != null && widget.tooltip!.isNotEmpty) {
      button = Tooltip(message: widget.tooltip!, child: button);
    }
    return button;
  }
}

/// Unified iOS frosted capsule search bar for Files, Photos, and Cinema.
class IsleSearchBar extends StatelessWidget {
  const IsleSearchBar({
    super.key,
    required this.controller,
    required this.hintText,
    this.onSubmitted,
    this.onChanged,
    this.onClear,
    this.focusNode,
    this.showClear = false,
    this.clearTooltip,
    this.maxLength,
    this.enabled = true,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;
  final FocusNode? focusNode;
  final bool showClear;
  final String? clearTooltip;
  final int? maxLength;
  final bool enabled;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;

    return TextField(
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      autofocus: autofocus,
      maxLength: maxLength,
      textInputAction: TextInputAction.search,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        counterText: maxLength != null ? '' : null,
        fillColor: dark
            ? Colors.white.withValues(alpha: 0.07)
            : colors.surface.withValues(alpha: 0.88),
        hintText: hintText,
        prefixIcon: Icon(
          Icons.search_rounded,
          size: 19,
          color: colors.onSurfaceVariant,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: IsleRadius.brPill,
          borderSide: BorderSide(
            color: IsleGlass.rimBorderColor(dark),
            width: 0.8,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: IsleRadius.brPill,
          borderSide: BorderSide(
            color: IsleGlass.rimBorderColor(dark),
            width: 0.8,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: IsleRadius.brPill,
          borderSide: BorderSide(color: colors.primary, width: 1.5),
        ),
        suffixIcon: onClear != null
            ? IconButton(
                tooltip: clearTooltip ?? (showClear ? '清除搜索' : '搜索'),
                visualDensity: VisualDensity.compact,
                onPressed: enabled ? onClear : null,
                icon: Icon(
                  showClear ? Icons.close_rounded : Icons.arrow_forward_rounded,
                  size: 18,
                ),
              )
            : null,
      ),
    );
  }
}

/// Unified Liquid Glass multi-select action bar shared across Files, Photos, and Cinema.
class IsleSelectionBar extends StatelessWidget {
  const IsleSelectionBar({
    super.key,
    required this.label,
    required this.actions,
    this.padding = EdgeInsets.zero,
  });

  final String label;
  final List<Widget> actions;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final reducedMotion = IsleMotion.reducedMotion(context);

    return RepaintBoundary(
      child: Padding(
        padding: padding,
        child: IsleSurface(
          glass: true,
          radius: IsleRadius.item,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          tint: dark
              ? colors.primaryContainer.withValues(alpha: 0.42)
              : colors.primaryContainer.withValues(alpha: 0.68),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            spacing: 8,
            runSpacing: 8,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: dark ? 0.24 : 0.14),
                  borderRadius: IsleRadius.brPill,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.check_circle_rounded,
                      size: 15,
                      color: colors.primary,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: AnimatedSwitcher(
                        duration: reducedMotion
                            ? Duration.zero
                            : IsleMotion.micro,
                        child: Text(
                          label,
                          key: ValueKey<String>(label),
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: colors.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: actions,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Refined iOS Liquid Glass loading indicator with a luminous frosted orb,
/// rounded-cap spinner, and optional calm status caption.
class IsleLoadingState extends StatelessWidget {
  const IsleLoadingState({
    super.key,
    this.label,
    this.padding = const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
    this.compact = false,
  });

  final String? label;
  final EdgeInsetsGeometry padding;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final palette = IslePalette.of(context);
    final orbSize = compact ? 44.0 : 54.0;
    final indicatorSize = compact ? 20.0 : 24.0;
    final reducedMotion = IsleMotion.reducedMotion(context);

    return Padding(
      padding: padding,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RepaintBoundary(
              child: Container(
                width: orbSize,
                height: orbSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    center: const Alignment(-0.3, -0.4),
                    radius: 1.1,
                    colors: [
                      palette['cardTop'].withValues(alpha: dark ? 0.92 : 0.96),
                      Color.lerp(
                        palette['cardBottom'],
                        colors.primary,
                        dark ? 0.14 : 0.06,
                      )!,
                    ],
                  ),
                  border: Border.all(
                    color: IsleGlass.rimBorderColor(dark, isGlass: true),
                    width: 0.9,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: colors.primary.withValues(
                        alpha: dark ? 0.22 : 0.12,
                      ),
                      blurRadius: 20,
                      spreadRadius: 1,
                    ),
                    ...IsleShadows.card(dark),
                  ],
                ),
                child: Center(
                  child: SizedBox(
                    width: indicatorSize,
                    height: indicatorSize,
                    child: CircularProgressIndicator(
                      value: reducedMotion ? 0.72 : null,
                      strokeWidth: 2.6,
                      strokeCap: StrokeCap.round,
                      color: colors.primary,
                      backgroundColor: colors.primary.withValues(
                        alpha: dark ? 0.18 : 0.12,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (label != null && label!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                label!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.1,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
