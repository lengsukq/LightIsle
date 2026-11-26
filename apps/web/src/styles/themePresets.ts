export type Theme = "light" | "dark";

export type ThemePresetId =
  | "warm_gallery"
  | "nordic_glass"
  | "swiss_editorial"
  | "neo_brutal_pop"
  | "cyber_terminal";

export interface ThemePresetMeta {
  id: ThemePresetId;
  name: string;
  tagline: string;
  badge: string;
  icon: string;
  swatches: {
    light: readonly [string, string, string, string];
    dark: readonly [string, string, string, string];
  };
}

export interface PresetPalette {
  canvasTop: string;
  canvasBottom: string;
  cardTop: string;
  cardBottom: string;
  cardHover: string;
  cardItemTop: string;
  cardItemBottom: string;
  chrome: string;
  rim: string;
  shadowRgb: string;
  surfaceBase: string;
  surfaceRaised: string;
  surfaceElevated: string;
  surfaceGlass: string;
  surfaceGlassClear: string;
  surfaceGlassFallback: string;
  textPrimary: string;
  textSecondary: string;
  textTertiary: string;
  textDisabled: string;
  strokeSubtle: string;
  strokeGlass: string;
  strokeStrong: string;
  accentPrimary: string;
  accentPrimarySolid: string;
  accentPrimarySolidTop: string;
  onAccentPrimary: string;
  accentSecondary: string;
  accentMuted: string;
  accentGlow: string;
  brandBlue: string;
  brandCyan: string;
  brandViolet: string;
  brandAmber: string;
  success: string;
  warning: string;
  error: string;
  cardBorder: string;
  cardBorderStrong: string;
  divider: string;
  cardRim: string;
  cardShadow: string;
  hoverShadow: string;
  itemCardShadow: string;
  itemHoverShadow: string;
  shadowElevated: string;
  shadowFloat: string;
  shadowGlass: string;
  neoShadow?: string;
}

export interface PresetSpec {
  meta: ThemePresetMeta;
  radii: { xs: number; sm: number; md: number; lg: number; xl: number };
  borderWidth: string;
  headingFont: string;
  headingTracking: string;
  light: PresetPalette;
  dark: PresetPalette;
}

const SANS_FONT =
  '-apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", "Inter", "Helvetica Neue", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif';
const TECH_SANS_FONT =
  '-apple-system, BlinkMacSystemFont, "SF Pro Display", "Inter", "JetBrains Mono", "PingFang SC", "Hiragino Sans GB", sans-serif';

export const PRESET_SPECS: Record<ThemePresetId, PresetSpec> = {
  warm_gallery: {
    meta: {
      id: "warm_gallery",
      name: "温润画廊",
      tagline: "现代暖白石膏与深海青釉，克制留白与柔润层次",
      badge: "默认",
      icon: "🏛️",
      swatches: {
        light: ["#F7F6F3", "#FFFFFF", "#0E6B74", "#D4653E"],
        dark: ["#0E0E0D", "#191917", "#5CC8D4", "#E88864"],
      },
    },
    radii: { xs: 7, sm: 10, md: 14, lg: 18, xl: 22 },
    borderWidth: "1px",
    headingFont: SANS_FONT,
    headingTracking: "-0.3px",
    light: {
      canvasTop: "#F7F6F3", canvasBottom: "#F1EFEA", cardTop: "#FFFFFF", cardBottom: "#FDFDFC",
      cardHover: "#F5F4F0", cardItemTop: "#F8F7F4", cardItemBottom: "#F3F1EC", chrome: "#FAF9F6",
      rim: "#E7E4DD", shadowRgb: "20 19 17", surfaceBase: "#F7F6F3",
      surfaceRaised: "rgba(255, 255, 254, 0.94)", surfaceElevated: "#FFFFFF",
      surfaceGlass: "rgba(252, 251, 249, 0.84)", surfaceGlassClear: "rgba(252, 251, 249, 0.56)",
      surfaceGlassFallback: "#FCFBF9EB", textPrimary: "#141413", textSecondary: "#5A5852",
      textTertiary: "#6D6A63", textDisabled: "#C7C4BC", strokeSubtle: "rgba(20, 19, 17, 0.068)",
      strokeGlass: "rgba(255, 255, 255, 0.90)", strokeStrong: "rgba(20, 19, 17, 0.14)",
      accentPrimary: "#0E6B74", accentPrimarySolid: "#0E6B74", accentPrimarySolidTop: "#14818B",
      onAccentPrimary: "#FFFFFF", accentSecondary: "#D4653E",
      accentMuted: "rgba(14, 107, 116, 0.09)", accentGlow: "rgba(14, 107, 116, 0.20)",
      brandBlue: "#0E6B74", brandCyan: "#0D7C86", brandViolet: "#6B5799", brandAmber: "#A66010",
      success: "#167A54", warning: "#9A5506", error: "#C93B3B",
      cardBorder: "rgba(20, 19, 17, 0.068)", cardBorderStrong: "rgba(20, 19, 17, 0.14)",
      divider: "rgba(20, 19, 17, 0.058)", cardRim: "inset 0 1px 0 rgba(255, 255, 255, 0.92)",
      cardShadow: "0 1px 2px rgba(20, 19, 17, 0.032), 0 10px 26px -10px rgba(20, 19, 17, 0.068)",
      hoverShadow: "0 4px 12px rgba(20, 19, 17, 0.05), 0 16px 34px -12px rgba(20, 19, 17, 0.11)",
      itemCardShadow: "0 1px 2px rgba(20, 19, 17, 0.025)",
      itemHoverShadow: "0 4px 12px -2px rgba(20, 19, 17, 0.075)",
      shadowElevated: "0 1px 2px rgba(20, 19, 17, 0.035), 0 10px 26px -10px rgba(20, 19, 17, 0.07)",
      shadowFloat: "0 6px 18px rgba(20, 19, 17, 0.07), 0 24px 48px -14px rgba(20, 19, 17, 0.14)",
      shadowGlass: "0 14px 36px rgba(20, 19, 17, 0.065), inset 0 1px 0 rgba(255, 255, 255, 0.94)",
    },
    dark: {
      canvasTop: "#0E0E0D", canvasBottom: "#131311", cardTop: "#191917", cardBottom: "#161614",
      cardHover: "#22221F", cardItemTop: "#20201D", cardItemBottom: "#1B1B18", chrome: "#151513",
      rim: "#2E2E2A", shadowRgb: "0 0 0", surfaceBase: "#0E0E0D",
      surfaceRaised: "rgba(25, 25, 23, 0.90)", surfaceElevated: "#1C1C1A",
      surfaceGlass: "rgba(22, 22, 20, 0.80)", surfaceGlassClear: "rgba(22, 22, 20, 0.52)",
      surfaceGlassFallback: "#171715", textPrimary: "#F5F4F0", textSecondary: "#B3AFA6",
      textTertiary: "#8F8B83", textDisabled: "#56534D", strokeSubtle: "rgba(245, 244, 240, 0.08)",
      strokeGlass: "rgba(245, 244, 240, 0.12)", strokeStrong: "rgba(245, 244, 240, 0.18)",
      accentPrimary: "#5CC8D4", accentPrimarySolid: "#13747E", accentPrimarySolidTop: "#1A8E9A",
      onAccentPrimary: "#F8FAF9", accentSecondary: "#E88864",
      accentMuted: "rgba(92, 200, 212, 0.14)", accentGlow: "rgba(92, 200, 212, 0.28)",
      brandBlue: "#5CC8D4", brandCyan: "#52C7BA", brandViolet: "#B8A1E3", brandAmber: "#E8A64D",
      success: "#47C28D", warning: "#E8A64D", error: "#EC6E66",
      cardBorder: "rgba(245, 244, 240, 0.082)", cardBorderStrong: "rgba(245, 244, 240, 0.16)",
      divider: "rgba(245, 244, 240, 0.065)", cardRim: "inset 0 1px 0 rgba(255, 253, 248, 0.065)",
      cardShadow: "0 1px 3px rgba(0, 0, 0, 0.34), 0 14px 32px -10px rgba(0, 0, 0, 0.48), inset 0 1px 0 rgba(255, 253, 248, 0.06)",
      hoverShadow: "0 6px 16px rgba(0, 0, 0, 0.42), 0 20px 42px -12px rgba(0, 0, 0, 0.60), inset 0 1px 0 rgba(255, 253, 248, 0.08)",
      itemCardShadow: "0 1px 2px rgba(0, 0, 0, 0.24), inset 0 1px 0 rgba(255, 253, 248, 0.04)",
      itemHoverShadow: "0 6px 16px -2px rgba(0, 0, 0, 0.42), inset 0 1px 0 rgba(255, 253, 248, 0.08)",
      shadowElevated: "0 2px 6px rgba(0, 0, 0, 0.36), 0 14px 32px -10px rgba(0, 0, 0, 0.50)",
      shadowFloat: "0 8px 22px rgba(0, 0, 0, 0.48), 0 26px 52px -14px rgba(0, 0, 0, 0.66)",
      shadowGlass: "0 16px 40px rgba(0, 0, 0, 0.50), inset 0 1px 0 rgba(255, 253, 248, 0.075)",
    },
  },

  nordic_glass: {
    meta: {
      id: "nordic_glass",
      name: "极光玻璃",
      tagline: "银雾铂金与暗曜液态玻璃，通透折射与柔和极光",
      badge: "通透",
      icon: "❄️",
      swatches: {
        light: ["#F3F5FA", "#FFFFFF", "#0A66FF", "#6E56CF"],
        dark: ["#080A0F", "#161A24", "#5BA4FF", "#A78BFA"],
      },
    },
    radii: { xs: 8, sm: 12, md: 16, lg: 20, xl: 24 },
    borderWidth: "1px",
    headingFont: SANS_FONT,
    headingTracking: "-0.38px",
    light: {
      canvasTop: "#F3F5FA", canvasBottom: "#E9EEF7", cardTop: "#FFFFFF", cardBottom: "#FAFBFD",
      cardHover: "#F1F5FC", cardItemTop: "#F8FAFE", cardItemBottom: "#F0F4FB", chrome: "#F6F8FC",
      rim: "#D7DFEC", shadowRgb: "15 23 42", surfaceBase: "#F3F5FA",
      surfaceRaised: "rgba(255, 255, 255, 0.78)", surfaceElevated: "#FFFFFF",
      surfaceGlass: "rgba(255, 255, 255, 0.70)", surfaceGlassClear: "rgba(255, 255, 255, 0.44)",
      surfaceGlassFallback: "#F7F9FD", textPrimary: "#0E131F", textSecondary: "#4B566B",
      textTertiary: "#59657B", textDisabled: "#BAC4D6", strokeSubtle: "rgba(15, 23, 42, 0.068)",
      strokeGlass: "rgba(255, 255, 255, 0.88)", strokeStrong: "rgba(10, 102, 255, 0.24)",
      accentPrimary: "#0A66FF", accentPrimarySolid: "#0A66FF", accentPrimarySolidTop: "#2E7DFF",
      onAccentPrimary: "#FFFFFF", accentSecondary: "#6E56CF",
      accentMuted: "rgba(10, 102, 255, 0.095)", accentGlow: "rgba(10, 102, 255, 0.22)",
      brandBlue: "#0A66FF", brandCyan: "#0891B2", brandViolet: "#6E56CF", brandAmber: "#D97706",
      success: "#059669", warning: "#D97706", error: "#DC2626",
      cardBorder: "rgba(15, 23, 42, 0.072)", cardBorderStrong: "rgba(10, 102, 255, 0.26)",
      divider: "rgba(15, 23, 42, 0.06)", cardRim: "inset 0 1px 0 rgba(255, 255, 255, 0.96)",
      cardShadow: "0 2px 6px rgba(15, 23, 42, 0.035), 0 12px 30px -8px rgba(15, 23, 42, 0.075), inset 0 1px 0 rgba(255, 255, 255, 0.94)",
      hoverShadow: "0 6px 16px rgba(15, 23, 42, 0.055), 0 18px 40px -10px rgba(15, 23, 42, 0.12), inset 0 1px 0 rgba(255, 255, 255, 0.98)",
      itemCardShadow: "0 1px 3px rgba(15, 23, 42, 0.035), inset 0 1px 0 rgba(255, 255, 255, 0.90)",
      itemHoverShadow: "0 6px 18px -4px rgba(15, 23, 42, 0.09), inset 0 1px 0 rgba(255, 255, 255, 0.96)",
      shadowElevated: "0 8px 24px -6px rgba(15, 23, 42, 0.08)",
      shadowFloat: "0 16px 42px -10px rgba(15, 23, 42, 0.15)",
      shadowGlass: "0 12px 36px -6px rgba(15, 23, 42, 0.085), inset 0 1px 0 rgba(255, 255, 255, 0.95)",
    },
    dark: {
      canvasTop: "#080A0F", canvasBottom: "#0E1119", cardTop: "#161A24", cardBottom: "#12151E",
      cardHover: "#1D2230", cardItemTop: "#1A1F2B", cardItemBottom: "#141822", chrome: "#10131C",
      rim: "#2B3245", shadowRgb: "0 0 0", surfaceBase: "#080A0F",
      surfaceRaised: "rgba(22, 26, 36, 0.76)", surfaceElevated: "#181C27",
      surfaceGlass: "rgba(22, 26, 36, 0.66)", surfaceGlassClear: "rgba(22, 26, 36, 0.42)",
      surfaceGlassFallback: "#141822", textPrimary: "#F4F7FC", textSecondary: "#A6B1C6",
      textTertiary: "#8E9AB2", textDisabled: "#4E576B", strokeSubtle: "rgba(226, 236, 255, 0.09)",
      strokeGlass: "rgba(226, 236, 255, 0.16)", strokeStrong: "rgba(91, 164, 255, 0.34)",
      accentPrimary: "#5BA4FF", accentPrimarySolid: "#2563EB", accentPrimarySolidTop: "#3B82F6",
      onAccentPrimary: "#F8FAFF", accentSecondary: "#A78BFA",
      accentMuted: "rgba(91, 164, 255, 0.15)", accentGlow: "rgba(91, 164, 255, 0.30)",
      brandBlue: "#5BA4FF", brandCyan: "#38D9E9", brandViolet: "#A78BFA", brandAmber: "#FBBF24",
      success: "#34D399", warning: "#FBBF24", error: "#F87171",
      cardBorder: "rgba(226, 236, 255, 0.11)", cardBorderStrong: "rgba(226, 236, 255, 0.22)",
      divider: "rgba(226, 236, 255, 0.075)", cardRim: "inset 0 1px 0 rgba(235, 243, 255, 0.14)",
      cardShadow: "0 8px 28px -6px rgba(0, 0, 0, 0.46), inset 0 1px 0 rgba(235, 243, 255, 0.13)",
      hoverShadow: "0 14px 38px -8px rgba(0, 0, 0, 0.58), inset 0 1px 0 rgba(235, 243, 255, 0.20)",
      itemCardShadow: "0 2px 10px rgba(0, 0, 0, 0.30), inset 0 1px 0 rgba(235, 243, 255, 0.08)",
      itemHoverShadow: "0 8px 22px -4px rgba(0, 0, 0, 0.46), inset 0 1px 0 rgba(235, 243, 255, 0.16)",
      shadowElevated: "0 8px 26px rgba(0, 0, 0, 0.46)",
      shadowFloat: "0 18px 44px rgba(0, 0, 0, 0.64)",
      shadowGlass: "0 14px 38px rgba(0, 0, 0, 0.50), inset 0 1px 0 rgba(235, 243, 255, 0.15)",
    },
  },

  swiss_editorial: {
    meta: {
      id: "swiss_editorial",
      name: "瑞士印刷",
      tagline: "现代黑白极简、精准发丝线框与国际朱红点睛",
      badge: "极简",
      icon: "🗞️",
      swatches: {
        light: ["#FAFAFA", "#FFFFFF", "#E5381A", "#09090B"],
        dark: ["#09090B", "#121215", "#FF5733", "#FAFAFA"],
      },
    },
    radii: { xs: 4, sm: 6, md: 8, lg: 10, xl: 12 },
    borderWidth: "1px",
    headingFont: SANS_FONT,
    headingTracking: "-0.42px",
    light: {
      canvasTop: "#FAFAFA", canvasBottom: "#F5F5F6", cardTop: "#FFFFFF", cardBottom: "#FFFFFF",
      cardHover: "#F4F4F5", cardItemTop: "#F8F8F9", cardItemBottom: "#F4F4F5", chrome: "#FFFFFF",
      rim: "#E4E4E7", shadowRgb: "9 9 11", surfaceBase: "#FAFAFA", surfaceRaised: "#FFFFFF",
      surfaceElevated: "#FFFFFF", surfaceGlass: "rgba(255, 255, 255, 0.94)",
      surfaceGlassClear: "rgba(255, 255, 255, 0.86)", surfaceGlassFallback: "#FFFFFF",
      textPrimary: "#09090B", textSecondary: "#52525B", textTertiary: "#676770",
      textDisabled: "#C4C4CC", strokeSubtle: "#E4E4E7", strokeGlass: "#E4E4E7", strokeStrong: "#18181B",
      accentPrimary: "#E5381A", accentPrimarySolid: "#E5381A", accentPrimarySolidTop: "#F04A2E",
      onAccentPrimary: "#FFFFFF", accentSecondary: "#18181B",
      accentMuted: "rgba(229, 56, 26, 0.085)", accentGlow: "rgba(229, 56, 26, 0.18)",
      brandBlue: "#1D4ED8", brandCyan: "#0E7490", brandViolet: "#6D28D9", brandAmber: "#B45309",
      success: "#15803D", warning: "#B45309", error: "#DC2626",
      cardBorder: "#E4E4E7", cardBorderStrong: "#18181B", divider: "#ECECEF",
      cardRim: "none", cardShadow: "none", hoverShadow: "none", itemCardShadow: "none",
      itemHoverShadow: "none", shadowElevated: "none",
      shadowFloat: "0 8px 24px -6px rgba(9, 9, 11, 0.10), 0 0 0 1px rgba(9, 9, 11, 0.06)",
      shadowGlass: "0 6px 20px -6px rgba(9, 9, 11, 0.08)",
    },
    dark: {
      canvasTop: "#09090B", canvasBottom: "#09090B", cardTop: "#121215", cardBottom: "#121215",
      cardHover: "#1C1C21", cardItemTop: "#18181C", cardItemBottom: "#141418", chrome: "#0D0D10",
      rim: "#27272A", shadowRgb: "0 0 0", surfaceBase: "#09090B", surfaceRaised: "#121215",
      surfaceElevated: "#141418", surfaceGlass: "rgba(18, 18, 21, 0.92)",
      surfaceGlassClear: "rgba(18, 18, 21, 0.84)", surfaceGlassFallback: "#121215",
      textPrimary: "#FAFAFA", textSecondary: "#ADADB6", textTertiary: "#92929C",
      textDisabled: "#46464D", strokeSubtle: "#27272A", strokeGlass: "#27272A", strokeStrong: "#E4E4E7",
      accentPrimary: "#FF5733", accentPrimarySolid: "#E5381A", accentPrimarySolidTop: "#FF5733",
      onAccentPrimary: "#FFFFFF", accentSecondary: "#E4E4E7",
      accentMuted: "rgba(255, 87, 51, 0.13)", accentGlow: "rgba(255, 87, 51, 0.24)",
      brandBlue: "#60A5FA", brandCyan: "#22D3EE", brandViolet: "#C084FC", brandAmber: "#F59E0B",
      success: "#4ADE80", warning: "#FBBF24", error: "#F87171",
      cardBorder: "#27272A", cardBorderStrong: "#FF5733", divider: "#202024",
      cardRim: "none", cardShadow: "none", hoverShadow: "none", itemCardShadow: "none",
      itemHoverShadow: "none", shadowElevated: "none",
      shadowFloat: "0 10px 28px rgba(0, 0, 0, 0.55), 0 0 0 1px rgba(255, 255, 255, 0.08)",
      shadowGlass: "0 8px 24px rgba(0, 0, 0, 0.48)",
    },
  },

  neo_brutal_pop: {
    meta: {
      id: "neo_brutal_pop",
      name: "新粗野波普",
      tagline: "现代工作室波普撞色、利落墨线与硬朗立体投影",
      badge: "个性",
      icon: "⚡",
      swatches: {
        light: ["#FAF6EE", "#FFFFFF", "#3B5BDB", "#F43F5E"],
        dark: ["#111118", "#1A1A25", "#FACC15", "#FB7185"],
      },
    },
    radii: { xs: 5, sm: 7, md: 9, lg: 12, xl: 14 },
    borderWidth: "1.75px",
    headingFont: SANS_FONT,
    headingTracking: "-0.25px",
    light: {
      canvasTop: "#FAF6EE", canvasBottom: "#F3EDE0", cardTop: "#FFFFFF", cardBottom: "#FFFFFF",
      cardHover: "#FDFBF7", cardItemTop: "#FAF8F3", cardItemBottom: "#F4EFE4", chrome: "#FAF6EE",
      rim: "#18181B", shadowRgb: "24 24 27", surfaceBase: "#FAF6EE", surfaceRaised: "#FFFFFF",
      surfaceElevated: "#FFFFFF", surfaceGlass: "#FFFFFF", surfaceGlassClear: "#FAF8F3",
      surfaceGlassFallback: "#FFFFFF", textPrimary: "#141417", textSecondary: "#45433E",
      textTertiary: "#666259", textDisabled: "#ADA89D", strokeSubtle: "#18181B",
      strokeGlass: "#18181B", strokeStrong: "#18181B",
      accentPrimary: "#3B5BDB", accentPrimarySolid: "#3B5BDB", accentPrimarySolidTop: "#4C6EF5",
      onAccentPrimary: "#FFFFFF", accentSecondary: "#F43F5E",
      accentMuted: "rgba(59, 91, 219, 0.12)", accentGlow: "rgba(59, 91, 219, 0.24)",
      brandBlue: "#3B5BDB", brandCyan: "#0891B2", brandViolet: "#7C3AED", brandAmber: "#D97706",
      success: "#059669", warning: "#D97706", error: "#E11D48",
      cardBorder: "#18181B", cardBorderStrong: "#18181B", divider: "rgba(24, 24, 27, 0.14)",
      cardRim: "none", cardShadow: "3.5px 3.5px 0 0 #18181B", hoverShadow: "5px 5px 0 0 #18181B",
      itemCardShadow: "2px 2px 0 0 #18181B", itemHoverShadow: "3px 3px 0 0 #18181B",
      shadowElevated: "3.5px 3.5px 0 0 #18181B", shadowFloat: "5px 5px 0 0 #18181B",
      shadowGlass: "3.5px 3.5px 0 0 #18181B", neoShadow: "#18181B",
    },
    dark: {
      canvasTop: "#111118", canvasBottom: "#0C0C12", cardTop: "#1A1A25", cardBottom: "#1A1A25",
      cardHover: "#232333", cardItemTop: "#20202E", cardItemBottom: "#171722", chrome: "#161620",
      rim: "#D8D4C8", shadowRgb: "5 5 8", surfaceBase: "#111118", surfaceRaised: "#1A1A25",
      surfaceElevated: "#1E1E2B", surfaceGlass: "#1A1A25", surfaceGlassClear: "#161620",
      surfaceGlassFallback: "#1A1A25", textPrimary: "#FAF8F2", textSecondary: "#C5C2D4",
      textTertiary: "#8E8AA3", textDisabled: "#5C5870", strokeSubtle: "rgba(216, 212, 200, 0.42)",
      strokeGlass: "#D8D4C8", strokeStrong: "#FACC15",
      accentPrimary: "#FACC15", accentPrimarySolid: "#FACC15", accentPrimarySolidTop: "#FDE047",
      onAccentPrimary: "#111118", accentSecondary: "#FB7185",
      accentMuted: "rgba(250, 204, 21, 0.16)", accentGlow: "rgba(250, 204, 21, 0.30)",
      brandBlue: "#748FFC", brandCyan: "#22D3EE", brandViolet: "#C084FC", brandAmber: "#FACC15",
      success: "#34D399", warning: "#FACC15", error: "#FB7185",
      cardBorder: "rgba(216, 212, 200, 0.72)", cardBorderStrong: "#FACC15", divider: "rgba(216, 212, 200, 0.15)",
      cardRim: "none", cardShadow: "3.5px 3.5px 0 0 #050508", hoverShadow: "5px 5px 0 0 #050508",
      itemCardShadow: "2px 2px 0 0 #050508", itemHoverShadow: "3px 3px 0 0 #050508",
      shadowElevated: "3.5px 3.5px 0 0 #050508", shadowFloat: "5px 5px 0 0 #050508",
      shadowGlass: "3.5px 3.5px 0 0 #050508", neoShadow: "#050508",
    },
  },

  cyber_terminal: {
    meta: {
      id: "cyber_terminal",
      name: "赛博终端",
      tagline: "碳黑精密仪表台、微距工程网格与翡翠信号光",
      badge: "极客",
      icon: "⌘",
      swatches: {
        light: ["#F2F5F4", "#FFFFFF", "#059669", "#D97706"],
        dark: ["#090C0B", "#111715", "#34D399", "#F59E0B"],
      },
    },
    radii: { xs: 4, sm: 6, md: 8, lg: 10, xl: 12 },
    borderWidth: "1px",
    headingFont: TECH_SANS_FONT,
    headingTracking: "-0.15px",
    light: {
      canvasTop: "#F2F5F4", canvasBottom: "#E9EEEC", cardTop: "#FFFFFF", cardBottom: "#F9FBFA",
      cardHover: "#EFF4F2", cardItemTop: "#F5F8F6", cardItemBottom: "#EDF2F0", chrome: "#F6F9F8",
      rim: "#CFDCD6", shadowRgb: "10 34 26", surfaceBase: "#F2F5F4",
      surfaceRaised: "rgba(255, 255, 255, 0.92)", surfaceElevated: "#FFFFFF",
      surfaceGlass: "rgba(248, 251, 250, 0.86)", surfaceGlassClear: "rgba(248, 251, 250, 0.62)",
      surfaceGlassFallback: "#F6F9F8", textPrimary: "#0C1915", textSecondary: "#3F574E",
      textTertiary: "#526A61", textDisabled: "#A8BAB3", strokeSubtle: "rgba(12, 34, 26, 0.09)",
      strokeGlass: "rgba(188, 208, 199, 0.85)", strokeStrong: "rgba(5, 150, 105, 0.45)",
      accentPrimary: "#059669", accentPrimarySolid: "#059669", accentPrimarySolidTop: "#10B981",
      onAccentPrimary: "#FFFFFF", accentSecondary: "#D97706",
      accentMuted: "rgba(5, 150, 105, 0.095)", accentGlow: "rgba(5, 150, 105, 0.20)",
      brandBlue: "#0284C7", brandCyan: "#0891B2", brandViolet: "#7C3AED", brandAmber: "#D97706",
      success: "#059669", warning: "#D97706", error: "#DC2626",
      cardBorder: "rgba(12, 34, 26, 0.11)", cardBorderStrong: "rgba(5, 150, 105, 0.48)",
      divider: "rgba(12, 34, 26, 0.075)", cardRim: "inset 0 1px 0 rgba(255, 255, 255, 0.90)",
      cardShadow: "0 1px 2px rgba(10, 34, 26, 0.04), 0 8px 20px -8px rgba(10, 34, 26, 0.07)",
      hoverShadow: "0 0 0 1px rgba(5, 150, 105, 0.20), 0 10px 26px -8px rgba(5, 150, 105, 0.14)",
      itemCardShadow: "0 1px 2px rgba(10, 34, 26, 0.03)",
      itemHoverShadow: "0 4px 12px -2px rgba(5, 150, 105, 0.12)",
      shadowElevated: "0 2px 8px rgba(10, 34, 26, 0.06)",
      shadowFloat: "0 12px 32px -8px rgba(10, 34, 26, 0.14)",
      shadowGlass: "0 10px 28px -6px rgba(10, 34, 26, 0.10)",
    },
    dark: {
      canvasTop: "#090C0B", canvasBottom: "#0D1210", cardTop: "#111715", cardBottom: "#0E1412",
      cardHover: "#17201D", cardItemTop: "#141C19", cardItemBottom: "#101714", chrome: "#0C110F",
      rim: "#23362E", shadowRgb: "0 0 0", surfaceBase: "#090C0B",
      surfaceRaised: "rgba(17, 23, 21, 0.90)", surfaceElevated: "#141C19",
      surfaceGlass: "rgba(14, 20, 18, 0.84)", surfaceGlassClear: "rgba(14, 20, 18, 0.60)",
      surfaceGlassFallback: "#0E1412", textPrimary: "#ECF5F1", textSecondary: "#98B5A9",
      textTertiary: "#7E9D90", textDisabled: "#435950", strokeSubtle: "rgba(52, 211, 153, 0.13)",
      strokeGlass: "rgba(52, 211, 153, 0.20)", strokeStrong: "rgba(52, 211, 153, 0.52)",
      accentPrimary: "#34D399", accentPrimarySolid: "#059669", accentPrimarySolidTop: "#10B981",
      onAccentPrimary: "#04160E", accentSecondary: "#F59E0B",
      accentMuted: "rgba(52, 211, 153, 0.13)", accentGlow: "rgba(52, 211, 153, 0.26)",
      brandBlue: "#38BDF8", brandCyan: "#22D3EE", brandViolet: "#A78BFA", brandAmber: "#F59E0B",
      success: "#34D399", warning: "#F59E0B", error: "#F87171",
      cardBorder: "rgba(52, 211, 153, 0.16)", cardBorderStrong: "rgba(52, 211, 153, 0.52)",
      divider: "rgba(52, 211, 153, 0.10)", cardRim: "inset 0 1px 0 rgba(52, 211, 153, 0.08)",
      cardShadow: "0 1px 3px rgba(0, 0, 0, 0.40), 0 10px 26px -8px rgba(0, 0, 0, 0.54)",
      hoverShadow: "0 0 0 1px rgba(52, 211, 153, 0.28), 0 12px 30px -8px rgba(16, 185, 129, 0.22)",
      itemCardShadow: "0 1px 2px rgba(0, 0, 0, 0.28)",
      itemHoverShadow: "0 0 0 1px rgba(52, 211, 153, 0.22), 0 8px 20px -6px rgba(16, 185, 129, 0.18)",
      shadowElevated: "0 4px 16px rgba(0, 0, 0, 0.44)",
      shadowFloat: "0 14px 36px rgba(0, 0, 0, 0.62), 0 0 0 1px rgba(52, 211, 153, 0.18)",
      shadowGlass: "0 12px 32px rgba(0, 0, 0, 0.52), inset 0 1px 0 rgba(52, 211, 153, 0.10)",
    },
  },
};

export const THEME_PRESETS: ReadonlyArray<ThemePresetMeta> = [
  PRESET_SPECS.warm_gallery.meta,
  PRESET_SPECS.nordic_glass.meta,
  PRESET_SPECS.swiss_editorial.meta,
  PRESET_SPECS.neo_brutal_pop.meta,
  PRESET_SPECS.cyber_terminal.meta,
];
