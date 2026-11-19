import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'isle_theme.dart';

enum IslePillVariant { primary, tonal, glass, danger }

/// Unified tactile capsule button for primary actions, selection toggles,
/// navigation back pills, and semantic actions.
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
    final style = IsleThemeStyle.of(context);
    final disabled = widget.onPressed == null;
    final reducedMotion = IsleMotion.reducedMotion(context);
    final isPrimary = widget.variant == IslePillVariant.primary;
    final isDanger = widget.variant == IslePillVariant.danger;
    final tone = isDanger ? colors.error : (widget.accent ?? colors.primary);
    final isSharp = style.preset.cornerStyle == IsleCornerStyle.sharp;
    final borderRadius = isSharp
        ? style.borderRadiusFor(IsleRadius.control)
        : IsleRadius.brPill;

    final fg = disabled
        ? colors.onSurfaceVariant.withValues(alpha: 0.45)
        : isPrimary
        ? (ThemeData.estimateBrightnessForColor(tone) == Brightness.dark
              ? Colors.white
              : const Color(0xff111111))
        : (isDanger ||
              widget.selected ||
              widget.variant == IslePillVariant.tonal)
        ? tone
        : colors.onSurface;

    final decoration = disabled
        ? BoxDecoration(
            color: colors.surfaceContainerHighest.withValues(alpha: 0.45),
            borderRadius: borderRadius,
            border: Border.all(
              color: style.rimBorderColor().withValues(alpha: 0.20),
              width: 1.0,
            ),
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
      borderRadius: borderRadius,
      child: InkWell(
        borderRadius: borderRadius,
        onHighlightChanged: disabled || reducedMotion ? null : _setPressed,
        onTap: widget.onPressed == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                widget.onPressed!();
              },
        child: AnimatedContainer(
          duration: reducedMotion ? Duration.zero : IsleMotion.quick,
          curve: IsleMotion.silk,
          constraints: BoxConstraints(minHeight: widget.compact ? 30 : 34),
          padding: EdgeInsets.symmetric(
            horizontal: widget.compact ? 10.5 : 13.5,
            vertical: widget.compact ? 5 : 6.5,
          ),
          decoration: decoration,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: widget.compact ? 15 : 16.5, color: fg),
                SizedBox(width: widget.compact ? 4.5 : 6),
              ],
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: widget.compact ? 12 : 13,
                    fontWeight: FontWeight.w700,
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
        duration: _pressed ? IsleMotion.pressDown : IsleMotion.pressRelease,
        curve: _pressed ? Curves.easeOutCubic : IsleMotion.gentleSpring,
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

/// Unified recessed parchment search bar for Files, Photos, and Cinema.
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
    final style = IsleThemeStyle.of(context);
    final dark = style.dark;
    final palette = style.palette;
    final radius = style.borderRadiusFor(IsleRadius.control);
    final borderWidth = style.effectiveBorderWidth();
    final isBrutal = style.preset.surfaceMaterial == IsleSurfaceMaterial.neoBrutal;

    return TextField(
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      autofocus: autofocus,
      maxLength: maxLength,
      textInputAction: TextInputAction.search,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13.5),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        counterText: maxLength != null ? '' : null,
        fillColor: isBrutal
            ? palette['cardTop']
            : dark
            ? palette['cardItemTop'].withValues(alpha: 0.90)
            : palette['cardTop'].withValues(alpha: 0.96),
        hintText: hintText,
        hintStyle: theme.textTheme.bodyMedium?.copyWith(
          fontSize: 13.5,
          color: colors.onSurfaceVariant.withValues(alpha: 0.72),
        ),
        prefixIconConstraints: const BoxConstraints(
          minWidth: 36,
          minHeight: 34,
        ),
        prefixIcon: Icon(
          Icons.search_rounded,
          size: 17.5,
          color: colors.onSurfaceVariant,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 8.5,
        ),
        border: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(
            color: style.rimBorderColor(),
            width: borderWidth,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(
            color: style.rimBorderColor(),
            width: borderWidth,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(
            color: colors.primary,
            width: isBrutal ? 2.2 : 1.5,
          ),
        ),
        suffixIcon: onClear != null
            ? IconButton(
                tooltip: clearTooltip ?? (showClear ? '清除搜索' : '搜索'),
                visualDensity: VisualDensity.compact,
                onPressed: enabled ? onClear : null,
                icon: AnimatedSwitcher(
                  duration: IsleMotion.reducedMotion(context)
                      ? Duration.zero
                      : IsleMotion.fast,
                  switchInCurve: IsleMotion.gentleSpring,
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: ScaleTransition(scale: anim, child: child),
                  ),
                  child: Icon(
                    showClear
                        ? Icons.close_rounded
                        : Icons.arrow_forward_rounded,
                    key: ValueKey<bool>(showClear),
                    size: 17,
                  ),
                ),
              )
            : null,
      ),
    );
  }
}

/// Unified floating multi-select action bar shared across Files, Photos, and Cinema.
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
    final style = IsleThemeStyle.of(context);
    final dark = style.dark;
    final palette = style.palette;
    final reducedMotion = IsleMotion.reducedMotion(context);
    final badgeRadius = style.preset.cornerStyle == IsleCornerStyle.sharp
        ? style.borderRadiusFor(IsleRadius.xs)
        : IsleRadius.brPill;

    return RepaintBoundary(
      child: Padding(
        padding: padding,
        child: IsleSurface(
          glass: true,
          radius: IsleRadius.card,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          tint: palette['accentPrimary'],
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            spacing: 8,
            runSpacing: 6,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 9.5,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: dark ? 0.22 : 0.12),
                  borderRadius: badgeRadius,
                  border: Border.all(
                    color: style.preset.surfaceMaterial ==
                            IsleSurfaceMaterial.neoBrutal
                        ? style.rimBorderColor()
                        : colors.primary.withValues(alpha: dark ? 0.35 : 0.22),
                    width: style.preset.surfaceMaterial ==
                            IsleSurfaceMaterial.neoBrutal
                        ? 1.5
                        : 1.0,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.check_circle_rounded,
                      size: 14.5,
                      color: colors.primary,
                    ),
                    const SizedBox(width: 5.5),
                    Flexible(
                      child: AnimatedSwitcher(
                        duration: reducedMotion
                            ? Duration.zero
                            : IsleMotion.fast,
                        switchInCurve: IsleMotion.gentleSpring,
                        transitionBuilder: (child, anim) => FadeTransition(
                          opacity: anim,
                          child: SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(0, 0.18),
                              end: Offset.zero,
                            ).animate(anim),
                            child: child,
                          ),
                        ),
                        child: Text(
                          label,
                          key: ValueKey<String>(label),
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontSize: 12.5,
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
                spacing: 6,
                runSpacing: 6,
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

/// Refined loading indicator with a warm ceramic vessel and calm status caption.
class IsleLoadingState extends StatelessWidget {
  const IsleLoadingState({
    super.key,
    this.label,
    this.padding = const EdgeInsets.symmetric(vertical: 26, horizontal: 16),
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
    final orbSize = compact ? 38.0 : 48.0;
    final indicatorSize = compact ? 18.0 : 21.0;
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
                  color: palette['cardTop'].withValues(
                    alpha: dark ? 0.92 : 0.98,
                  ),
                  border: Border.all(
                    color: IsleGlass.rimBorderColor(dark),
                    width: 1.0,
                  ),
                  boxShadow: IsleShadows.subtle(dark),
                ),
                child: Center(
                  child: SizedBox(
                    width: indicatorSize,
                    height: indicatorSize,
                    child: CircularProgressIndicator(
                      value: reducedMotion ? 0.72 : null,
                      strokeWidth: 2.4,
                      strokeCap: StrokeCap.round,
                      color: colors.primary,
                      backgroundColor: colors.primary.withValues(
                        alpha: dark ? 0.16 : 0.10,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (label != null && label!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                label!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
