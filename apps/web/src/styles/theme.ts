import tokens from "../../../../design-tokens/tokens.json";
import {
  PRESET_SPECS,
  THEME_PRESETS,
  type Theme,
  type ThemePresetId,
  type ThemePresetMeta,
} from "./themePresets.ts";

export { THEME_PRESETS, type Theme, type ThemePresetId, type ThemePresetMeta };

const LEGACY_ATMOSPHERE_MAP: Record<string, ThemePresetId> = {
  aurora: "warm_gallery",
  azure: "nordic_glass",
  sunset: "neo_brutal_pop",
  nebula: "cyber_terminal",
};

export function resolveThemePreset(raw?: string | null): ThemePresetId {
  if (!raw) return "warm_gallery";
  if (raw in PRESET_SPECS) return raw as ThemePresetId;
  if (raw in LEGACY_ATMOSPHERE_MAP) return LEGACY_ATMOSPHERE_MAP[raw];
  return "warm_gallery";
}

export function getThemeVariables(
  theme: Theme,
  preset: ThemePresetId = "warm_gallery",
): Record<string, string> {
  const spec = PRESET_SPECS[preset] ?? PRESET_SPECS.warm_gallery;
  const p = spec[theme];
  return {
    "--fluid-canvas-top": p.canvasTop,
    "--fluid-canvas-bottom": p.canvasBottom,
    "--fluid-card-top": p.cardTop,
    "--fluid-card-bottom": p.cardBottom,
    "--fluid-card-hover": p.cardHover,
    "--fluid-card-item-top": p.cardItemTop,
    "--fluid-card-item-bottom": p.cardItemBottom,
    "--fluid-chrome": p.chrome,
    "--fluid-rim": p.rim,
    "--fluid-shadow-rgb": p.shadowRgb,
    "--fluid-card-fill": `linear-gradient(180deg, ${p.cardTop} 0%, ${p.cardBottom} 100%)`,
    "--fluid-card-item-fill": `linear-gradient(180deg, ${p.cardItemTop} 0%, ${p.cardItemBottom} 100%)`,
    "--fluid-card-border": p.cardBorder,
    "--fluid-card-border-strong": p.cardBorderStrong,
    "--fluid-divider": p.divider,
    "--fluid-card-rim": p.cardRim,
    "--fluid-card-shadow": p.cardShadow,
    "--fluid-hover-shadow": p.hoverShadow,
    "--fluid-item-card-shadow": p.itemCardShadow,
    "--fluid-item-hover-shadow": p.itemHoverShadow,
    "--surface-base": p.surfaceBase,
    "--surface-raised": p.surfaceRaised,
    "--surface-elevated": p.surfaceElevated,
    "--surface-glass": p.surfaceGlass,
    "--surface-glass-clear": p.surfaceGlassClear,
    "--surface-glass-fallback": p.surfaceGlassFallback,
    "--text-primary": p.textPrimary,
    "--text-secondary": p.textSecondary,
    "--text-tertiary": p.textTertiary,
    "--text-disabled": p.textDisabled,
    "--stroke-subtle": p.strokeSubtle,
    "--stroke-glass": p.strokeGlass,
    "--stroke-strong": p.strokeStrong,
    "--accent-primary": p.accentPrimary,
    "--accent-primary-solid": p.accentPrimarySolid,
    "--accent-primary-solid-top": p.accentPrimarySolidTop,
    "--on-accent-primary": p.onAccentPrimary,
    "--accent-secondary": p.accentSecondary,
    "--accent-muted": p.accentMuted,
    "--accent-glow": p.accentGlow,
    "--brand-blue": p.brandBlue,
    "--brand-cyan": p.brandCyan,
    "--brand-violet": p.brandViolet,
    "--brand-amber": p.brandAmber,
    "--success": p.success,
    "--warning": p.warning,
    "--error": p.error,
    "--shadow-elevated": p.shadowElevated,
    "--shadow-float": p.shadowFloat,
    "--shadow-glass": p.shadowGlass,
    "--neo-shadow": p.neoShadow ?? p.rim,
    "--radius-xs": `${spec.radii.xs}px`,
    "--radius-sm": `${spec.radii.sm}px`,
    "--radius-md": `${spec.radii.md}px`,
    "--radius-lg": `${spec.radii.lg}px`,
    "--radius-xl": `${spec.radii.xl}px`,
    "--theme-border-width": spec.borderWidth,
    "--theme-heading-font": spec.headingFont,
    "--theme-heading-tracking": spec.headingTracking,
    "--motion-spring": tokens.motion.spring,
    "--motion-spring-snappy": "cubic-bezier(0.2, 0.9, 0.22, 1.05)",
    "--motion-exit": "cubic-bezier(0.32, 0, 0.67, 0)",
    "--motion-fast": `${tokens.motion.fastMs}ms`,
    "--motion-normal": `${tokens.motion.normalMs}ms`,
    "--motion-slow": `${tokens.motion.slowMs}ms`,
  };
}

export function applyTheme(theme: Theme, preset?: ThemePresetId) {
  const root = document.documentElement;
  const resolvedPreset = resolveThemePreset(
    preset ?? root.dataset.themePreset ?? root.dataset.atmosphere,
  );
  const vars = getThemeVariables(theme, resolvedPreset);
  for (const [key, value] of Object.entries(vars)) {
    root.style.setProperty(key, value);
  }
  root.dataset.theme = theme;
  root.dataset.themePreset = resolvedPreset;
  root.dataset.atmosphere = resolvedPreset;
  root.style.colorScheme = theme;
  if (typeof document !== "undefined") {
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta && vars["--fluid-canvas-top"]) {
      meta.setAttribute("content", vars["--fluid-canvas-top"]);
    }
  }
}
