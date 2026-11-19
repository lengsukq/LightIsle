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
  '-apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", "Helvetica Neue", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif';
const MONO_FONT =
  '"SF Mono", ui-monospace, "JetBrains Mono", Menlo, Monaco, Consolas, "PingFang SC", monospace';

export const PRESET_SPECS: Record<ThemePresetId, PresetSpec> = {
  warm_gallery: {
    meta: {
      id: "warm_gallery",
      name: "温润画廊",
      tagline: "宣纸米白与黛青陶土，温润超椭圆浮雕质感",
      badge: "默认",
      icon: "🏛️",
      swatches: {
        light: ["#F7F5F0", "#FFFFFF", "#1F5162", "#B85D3B"],
        dark: ["#151413", "#1E1D1B", "#72BCCB", "#E08A67"],
      },
    },
    radii: { xs: 6, sm: 10, md: 14, lg: 18, xl: 22 },
    borderWidth: "1px",
    headingFont: SANS_FONT,
    headingTracking: "-0.25px",
    light: {
      canvasTop: "#F7F5F0", canvasBottom: "#EFECE4", cardTop: "#FFFFFF", cardBottom: "#FCFBF8",
      cardHover: "#F5F2EA", cardItemTop: "#FAF8F3", cardItemBottom: "#F2EFE7", chrome: "#FAF8F3",
      rim: "#FFFFFF", shadowRgb: "34 29 23", surfaceBase: "#F7F5F0",
      surfaceRaised: "rgba(255, 254, 251, 0.94)", surfaceElevated: "#FFFDF9",
      surfaceGlass: "rgba(252, 250, 246, 0.84)", surfaceGlassClear: "rgba(252, 250, 246, 0.54)",
      surfaceGlassFallback: "#FCFBF8EB", textPrimary: "#181715", textSecondary: "#635E57",
      textTertiary: "#948D84", textDisabled: "#C9C3B9", strokeSubtle: "rgba(24, 23, 21, 0.075)",
      strokeGlass: "rgba(255, 253, 249, 0.86)", strokeStrong: "rgba(24, 23, 21, 0.15)",
      accentPrimary: "#1F5162", accentPrimarySolid: "#1F5162", accentPrimarySolidTop: "#2B677B",
      onAccentPrimary: "#FFFFFF", accentSecondary: "#B85D3B",
      accentMuted: "rgba(31, 81, 98, 0.085)", accentGlow: "rgba(31, 81, 98, 0.18)",
      brandBlue: "#1F5162", brandCyan: "#28666E", brandViolet: "#5E4B7A", brandAmber: "#B86B19",
      success: "#1F7A56", warning: "#B86B19", error: "#B94032",
      cardBorder: "rgba(34, 29, 23, 0.085)", cardBorderStrong: "rgba(34, 29, 23, 0.15)",
      divider: "rgba(34, 29, 23, 0.068)", cardRim: "inset 0 1px 0 rgba(255, 255, 255, 0.94)",
      cardShadow: "0 1px 2px rgba(34, 29, 23, 0.04), 0 8px 22px -8px rgba(34, 29, 23, 0.065), inset 0 1px 0 rgba(255, 255, 255, 0.94)",
      hoverShadow: "0 3px 8px rgba(34, 29, 23, 0.055), 0 14px 30px -10px rgba(34, 29, 23, 0.1), inset 0 1px 0 rgba(255, 255, 255, 0.94)",
      itemCardShadow: "0 1px 2px rgba(34, 29, 23, 0.03), inset 0 1px 0 rgba(255, 255, 255, 0.88)",
      itemHoverShadow: "0 4px 12px -2px rgba(34, 29, 23, 0.075), inset 0 1px 0 rgba(255, 255, 255, 0.94)",
      shadowElevated: "0 1px 2px rgba(32, 28, 22, 0.04), 0 8px 22px -8px rgba(32, 28, 22, 0.065)",
      shadowFloat: "0 4px 12px rgba(32, 28, 22, 0.06), 0 20px 42px -10px rgba(32, 28, 22, 0.12)",
      shadowGlass: "0 14px 36px rgba(32, 28, 22, 0.065), inset 0 1px 0 rgba(255, 255, 255, 0.92)",
    },
    dark: {
      canvasTop: "#151413", canvasBottom: "#0E0E0D", cardTop: "#1E1D1B", cardBottom: "#181715",
      cardHover: "#262421", cardItemTop: "#23221F", cardItemBottom: "#1B1A18", chrome: "#181715",
      rim: "#3E3A34", shadowRgb: "0 0 0", surfaceBase: "#131312",
      surfaceRaised: "rgba(29, 28, 26, 0.90)", surfaceElevated: "#1D1C1A",
      surfaceGlass: "rgba(24, 23, 21, 0.82)", surfaceGlassClear: "rgba(24, 23, 21, 0.52)",
      surfaceGlassFallback: "#191816", textPrimary: "#F4F1EA", textSecondary: "#A69F95",
      textTertiary: "#756F66", textDisabled: "#524D46", strokeSubtle: "rgba(244, 241, 234, 0.085)",
      strokeGlass: "rgba(244, 241, 234, 0.13)", strokeStrong: "rgba(244, 241, 234, 0.19)",
      accentPrimary: "#72BCCB", accentPrimarySolid: "#286578", accentPrimarySolidTop: "#347C92",
      onAccentPrimary: "#F8F6F1", accentSecondary: "#E08A67",
      accentMuted: "rgba(114, 188, 203, 0.14)", accentGlow: "rgba(114, 188, 203, 0.28)",
      brandBlue: "#72BCCB", brandCyan: "#66B8B2", brandViolet: "#B49FD4", brandAmber: "#E09A4B",
      success: "#4BAE86", warning: "#E09A4B", error: "#E26D5E",
      cardBorder: "rgba(244, 241, 234, 0.088)", cardBorderStrong: "rgba(244, 241, 234, 0.16)",
      divider: "rgba(244, 241, 234, 0.068)", cardRim: "inset 0 1px 0 rgba(244, 241, 234, 0.065)",
      cardShadow: "0 1px 3px rgba(0, 0, 0, 0.32), 0 12px 28px -8px rgba(0, 0, 0, 0.46), inset 0 1px 0 rgba(244, 241, 234, 0.065)",
      hoverShadow: "0 4px 12px rgba(0, 0, 0, 0.38), 0 18px 36px -10px rgba(0, 0, 0, 0.58), inset 0 1px 0 rgba(244, 241, 234, 0.065)",
      itemCardShadow: "0 1px 2px rgba(0, 0, 0, 0.24), inset 0 1px 0 rgba(244, 241, 234, 0.045)",
      itemHoverShadow: "0 6px 16px -2px rgba(0, 0, 0, 0.4), inset 0 1px 0 rgba(244, 241, 234, 0.085)",
      shadowElevated: "0 2px 6px rgba(0, 0, 0, 0.36), 0 12px 28px -8px rgba(0, 0, 0, 0.48)",
      shadowFloat: "0 6px 18px rgba(0, 0, 0, 0.46), 0 22px 46px -10px rgba(0, 0, 0, 0.62)",
      shadowGlass: "0 16px 40px rgba(0, 0, 0, 0.50), inset 0 1px 0 rgba(244, 241, 234, 0.08)",
    },
  },

  nordic_glass: {
    meta: {
      id: "nordic_glass",
      name: "极光玻璃",
      tagline: "冷雾深空与极光弥散光晕，通透磨砂液态玻璃",
      badge: "通透",
      icon: "❄️",
      swatches: {
        light: ["#EDF4FF", "#FFFFFF", "#1D63E6", "#7C4DFF"],
        dark: ["#070D19", "#142038", "#5EA6FF", "#A78BFA"],
      },
    },
    radii: { xs: 8, sm: 12, md: 17, lg: 21, xl: 26 },
    borderWidth: "1px",
    headingFont: SANS_FONT,
    headingTracking: "-0.35px",
    light: {
      canvasTop: "#EDF4FF", canvasBottom: "#E1ECFB", cardTop: "#FFFFFF", cardBottom: "#F4F8FF",
      cardHover: "#E9F2FF", cardItemTop: "#F6FAFF", cardItemBottom: "#EAF2FE", chrome: "#F1F6FF",
      rim: "#CAD9F0", shadowRgb: "19 34 59", surfaceBase: "#EDF4FF",
      surfaceRaised: "rgba(255, 255, 255, 0.80)", surfaceElevated: "#FFFFFF",
      surfaceGlass: "rgba(244, 249, 255, 0.72)", surfaceGlassClear: "rgba(244, 249, 255, 0.46)",
      surfaceGlassFallback: "#F0F5FF", textPrimary: "#0F1C2E", textSecondary: "#4C5E78",
      textTertiary: "#7D90AD", textDisabled: "#B8C7DC", strokeSubtle: "rgba(19, 34, 59, 0.085)",
      strokeGlass: "rgba(255, 255, 255, 0.82)", strokeStrong: "rgba(29, 99, 230, 0.24)",
      accentPrimary: "#1D63E6", accentPrimarySolid: "#1D63E6", accentPrimarySolidTop: "#3B7DF2",
      onAccentPrimary: "#FFFFFF", accentSecondary: "#7C4DFF",
      accentMuted: "rgba(29, 99, 230, 0.11)", accentGlow: "rgba(29, 99, 230, 0.24)",
      brandBlue: "#1D63E6", brandCyan: "#0891B2", brandViolet: "#7C4DFF", brandAmber: "#D97706",
      success: "#059669", warning: "#D97706", error: "#DC2626",
      cardBorder: "rgba(255, 255, 255, 0.76)", cardBorderStrong: "rgba(147, 179, 224, 0.56)",
      divider: "rgba(19, 34, 59, 0.075)", cardRim: "inset 0 1px 0 rgba(255, 255, 255, 0.98)",
      cardShadow: "0 7px 24px -4px rgba(19, 34, 59, 0.08), inset 0 1px 0 rgba(255, 255, 255, 0.96)",
      hoverShadow: "0 12px 32px -4px rgba(19, 34, 59, 0.13), inset 0 1px 0 rgba(255, 255, 255, 0.98)",
      itemCardShadow: "0 2px 8px rgba(19, 34, 59, 0.05), inset 0 1px 0 rgba(255, 255, 255, 0.92)",
      itemHoverShadow: "0 8px 20px -2px rgba(19, 34, 59, 0.10), inset 0 1px 0 rgba(255, 255, 255, 0.98)",
      shadowElevated: "0 7px 20px rgba(19, 34, 59, 0.08)",
      shadowFloat: "0 14px 36px rgba(19, 34, 59, 0.14)",
      shadowGlass: "0 12px 34px rgba(19, 34, 59, 0.09), inset 0 1px 0 rgba(255, 255, 255, 0.96)",
    },
    dark: {
      canvasTop: "#070D19", canvasBottom: "#0C1528", cardTop: "#142038", cardBottom: "#0E182C",
      cardHover: "#1B2B4A", cardItemTop: "#172540", cardItemBottom: "#101B30", chrome: "#0E172A",
      rim: "#30466B", shadowRgb: "2 5 10", surfaceBase: "#070D19",
      surfaceRaised: "rgba(20, 32, 56, 0.78)", surfaceElevated: "#142038",
      surfaceGlass: "rgba(16, 26, 46, 0.72)", surfaceGlassClear: "rgba(16, 26, 46, 0.46)",
      surfaceGlassFallback: "#101A2E", textPrimary: "#F1F6FF", textSecondary: "#9BB0CF",
      textTertiary: "#6B80A3", textDisabled: "#425472", strokeSubtle: "rgba(234, 242, 255, 0.11)",
      strokeGlass: "rgba(214, 233, 255, 0.22)", strokeStrong: "rgba(94, 166, 255, 0.34)",
      accentPrimary: "#5EA6FF", accentPrimarySolid: "#2563EB", accentPrimarySolidTop: "#3B82F6",
      onAccentPrimary: "#F8FAFF", accentSecondary: "#A78BFA",
      accentMuted: "rgba(94, 166, 255, 0.16)", accentGlow: "rgba(94, 166, 255, 0.32)",
      brandBlue: "#5EA6FF", brandCyan: "#38D9E9", brandViolet: "#B392FF", brandAmber: "#FBBF24",
      success: "#34D399", warning: "#FBBF24", error: "#F87171",
      cardBorder: "rgba(234, 242, 255, 0.16)", cardBorderStrong: "rgba(234, 242, 255, 0.28)",
      divider: "rgba(234, 242, 255, 0.09)", cardRim: "inset 0 1px 0 rgba(214, 233, 255, 0.22)",
      cardShadow: "0 8px 26px rgba(2, 5, 10, 0.42), inset 0 1px 0 rgba(214, 233, 255, 0.20)",
      hoverShadow: "0 14px 36px rgba(2, 5, 10, 0.56), inset 0 1px 0 rgba(214, 233, 255, 0.28)",
      itemCardShadow: "0 3px 10px rgba(2, 5, 10, 0.32), inset 0 1px 0 rgba(214, 233, 255, 0.12)",
      itemHoverShadow: "0 8px 22px rgba(2, 5, 10, 0.46), inset 0 1px 0 rgba(214, 233, 255, 0.22)",
      shadowElevated: "0 8px 24px rgba(2, 5, 10, 0.44)",
      shadowFloat: "0 16px 40px rgba(2, 5, 10, 0.62)",
      shadowGlass: "0 14px 36px rgba(2, 5, 10, 0.48), inset 0 1px 0 rgba(214, 233, 255, 0.22)",
    },
  },

  swiss_editorial: {
    meta: {
      id: "swiss_editorial",
      name: "瑞士印刷",
      tagline: "极简高对比纸面、利落小圆角与国际橙红单点缀",
      badge: "极简",
      icon: "🗞️",
      swatches: {
        light: ["#FAFAFA", "#FFFFFF", "#E53912", "#111111"],
        dark: ["#0A0A0A", "#141414", "#FF552E", "#E5E5E5"],
      },
    },
    radii: { xs: 2, sm: 3, md: 4, lg: 6, xl: 8 },
    borderWidth: "1px",
    headingFont: SANS_FONT,
    headingTracking: "-0.45px",
    light: {
      canvasTop: "#FAFAFA", canvasBottom: "#F4F4F4", cardTop: "#FFFFFF", cardBottom: "#FFFFFF",
      cardHover: "#F2F2F2", cardItemTop: "#F7F7F7", cardItemBottom: "#F0F0F0", chrome: "#FFFFFF",
      rim: "#D4D4D4", shadowRgb: "0 0 0", surfaceBase: "#FAFAFA", surfaceRaised: "#FFFFFF",
      surfaceElevated: "#FFFFFF", surfaceGlass: "rgba(255, 255, 255, 0.96)",
      surfaceGlassClear: "rgba(255, 255, 255, 0.88)", surfaceGlassFallback: "#FFFFFF",
      textPrimary: "#0A0A0A", textSecondary: "#525252", textTertiary: "#8A8A8A",
      textDisabled: "#C4C4C4", strokeSubtle: "#E2E2E2", strokeGlass: "#D4D4D4", strokeStrong: "#111111",
      accentPrimary: "#E53912", accentPrimarySolid: "#E53912", accentPrimarySolidTop: "#EE4C26",
      onAccentPrimary: "#FFFFFF", accentSecondary: "#111111",
      accentMuted: "rgba(229, 57, 18, 0.09)", accentGlow: "rgba(229, 57, 18, 0.18)",
      brandBlue: "#175CD3", brandCyan: "#0E7490", brandViolet: "#5B21B6", brandAmber: "#B45309",
      success: "#15803D", warning: "#B45309", error: "#DC2626",
      cardBorder: "#D4D4D4", cardBorderStrong: "#E53912", divider: "#E5E5E5",
      cardRim: "none", cardShadow: "none", hoverShadow: "none", itemCardShadow: "none",
      itemHoverShadow: "none", shadowElevated: "none",
      shadowFloat: "0 4px 12px rgba(0, 0, 0, 0.08)", shadowGlass: "0 4px 12px rgba(0, 0, 0, 0.06)",
    },
    dark: {
      canvasTop: "#0A0A0A", canvasBottom: "#0A0A0A", cardTop: "#141414", cardBottom: "#141414",
      cardHover: "#1F1F1F", cardItemTop: "#1A1A1A", cardItemBottom: "#121212", chrome: "#0F0F0F",
      rim: "#2E2E2E", shadowRgb: "0 0 0", surfaceBase: "#0A0A0A", surfaceRaised: "#141414",
      surfaceElevated: "#141414", surfaceGlass: "rgba(18, 18, 18, 0.96)",
      surfaceGlassClear: "rgba(18, 18, 18, 0.88)", surfaceGlassFallback: "#121212",
      textPrimary: "#FAFAFA", textSecondary: "#A3A3A3", textTertiary: "#737373",
      textDisabled: "#4A4A4A", strokeSubtle: "#262626", strokeGlass: "#2E2E2E", strokeStrong: "#E5E5E5",
      accentPrimary: "#FF552E", accentPrimarySolid: "#E53912", accentPrimarySolidTop: "#FF552E",
      onAccentPrimary: "#FFFFFF", accentSecondary: "#E5E5E5",
      accentMuted: "rgba(255, 85, 46, 0.14)", accentGlow: "rgba(255, 85, 46, 0.24)",
      brandBlue: "#60A5FA", brandCyan: "#22D3EE", brandViolet: "#C084FC", brandAmber: "#F59E0B",
      success: "#4ADE80", warning: "#FBBF24", error: "#F87171",
      cardBorder: "#2E2E2E", cardBorderStrong: "#FF552E", divider: "#242424",
      cardRim: "none", cardShadow: "none", hoverShadow: "none", itemCardShadow: "none",
      itemHoverShadow: "none", shadowElevated: "none",
      shadowFloat: "0 4px 14px rgba(0, 0, 0, 0.45)", shadowGlass: "0 4px 14px rgba(0, 0, 0, 0.45)",
    },
  },

  neo_brutal_pop: {
    meta: {
      id: "neo_brutal_pop",
      name: "新粗野波普",
      tagline: "大胆撞色、粗实线硬边框与零模糊偏移投影",
      badge: "个性",
      icon: "⚡",
      swatches: {
        light: ["#FFF6D6", "#FFFFFF", "#2E5BFF", "#FF4D79"],
        dark: ["#181726", "#232136", "#FFD836", "#FF6B9D"],
      },
    },
    radii: { xs: 4, sm: 5, md: 6, lg: 8, xl: 10 },
    borderWidth: "2px",
    headingFont: SANS_FONT,
    headingTracking: "-0.2px",
    light: {
      canvasTop: "#FFF6D6", canvasBottom: "#FFF0BD", cardTop: "#FFFFFF", cardBottom: "#FFFFFF",
      cardHover: "#FFFAE8", cardItemTop: "#FFF9E3", cardItemBottom: "#FFF2C6", chrome: "#FFF7D9",
      rim: "#141414", shadowRgb: "20 20 20", surfaceBase: "#FFF6D6", surfaceRaised: "#FFFFFF",
      surfaceElevated: "#FFFFFF", surfaceGlass: "#FFFFFF", surfaceGlassClear: "#FFF9E3",
      surfaceGlassFallback: "#FFFFFF", textPrimary: "#121212", textSecondary: "#3F3D36",
      textTertiary: "#6E6A5E", textDisabled: "#A8A293", strokeSubtle: "#141414",
      strokeGlass: "#141414", strokeStrong: "#141414",
      accentPrimary: "#2E5BFF", accentPrimarySolid: "#2E5BFF", accentPrimarySolidTop: "#446CFF",
      onAccentPrimary: "#FFFFFF", accentSecondary: "#FF4D79",
      accentMuted: "rgba(46, 91, 255, 0.14)", accentGlow: "rgba(46, 91, 255, 0.28)",
      brandBlue: "#2E5BFF", brandCyan: "#00A896", brandViolet: "#8B3DFF", brandAmber: "#E08E00",
      success: "#009E60", warning: "#E08E00", error: "#E5243B",
      cardBorder: "#141414", cardBorderStrong: "#141414", divider: "rgba(20, 20, 20, 0.22)",
      cardRim: "none", cardShadow: "4px 4px 0 0 #141414", hoverShadow: "6px 6px 0 0 #141414",
      itemCardShadow: "2px 2px 0 0 #141414", itemHoverShadow: "4px 4px 0 0 #141414",
      shadowElevated: "4px 4px 0 0 #141414", shadowFloat: "6px 6px 0 0 #141414",
      shadowGlass: "4px 4px 0 0 #141414", neoShadow: "#141414",
    },
    dark: {
      canvasTop: "#181726", canvasBottom: "#131220", cardTop: "#232136", cardBottom: "#232136",
      cardHover: "#2D2A45", cardItemTop: "#29263F", cardItemBottom: "#1E1C30", chrome: "#1E1C30",
      rim: "#F7F3E3", shadowRgb: "6 5 11", surfaceBase: "#181726", surfaceRaised: "#232136",
      surfaceElevated: "#232136", surfaceGlass: "#232136", surfaceGlassClear: "#1E1C30",
      surfaceGlassFallback: "#232136", textPrimary: "#FFFBF0", textSecondary: "#CBC5DF",
      textTertiary: "#948DB3", textDisabled: "#635D7D", strokeSubtle: "#F7F3E3",
      strokeGlass: "#F7F3E3", strokeStrong: "#FFD836",
      accentPrimary: "#FFD836", accentPrimarySolid: "#FFD836", accentPrimarySolidTop: "#FFE161",
      onAccentPrimary: "#141320", accentSecondary: "#FF6B9D",
      accentMuted: "rgba(255, 216, 54, 0.18)", accentGlow: "rgba(255, 216, 54, 0.34)",
      brandBlue: "#6E92FF", brandCyan: "#34E8D4", brandViolet: "#C084FF", brandAmber: "#FFD836",
      success: "#3CE39A", warning: "#FFD836", error: "#FF5C74",
      cardBorder: "#F7F3E3", cardBorderStrong: "#FFD836", divider: "rgba(247, 243, 227, 0.22)",
      cardRim: "none", cardShadow: "4px 4px 0 0 #06050B", hoverShadow: "6px 6px 0 0 #06050B",
      itemCardShadow: "2px 2px 0 0 #06050B", itemHoverShadow: "4px 4px 0 0 #06050B",
      shadowElevated: "4px 4px 0 0 #06050B", shadowFloat: "6px 6px 0 0 #06050B",
      shadowGlass: "4px 4px 0 0 #06050B", neoShadow: "#06050B",
    },
  },

  cyber_terminal: {
    meta: {
      id: "cyber_terminal",
      name: "赛博终端",
      tagline: "工程网格底纹、锐利微圆角与荧光仪表台质感",
      badge: "极客",
      icon: "⌘",
      swatches: {
        light: ["#ECF4EF", "#F7FBF8", "#007A4D", "#C97A00"],
        dark: ["#060C0A", "#0E1B16", "#00E68A", "#FFB300"],
      },
    },
    radii: { xs: 3, sm: 3, md: 4, lg: 5, xl: 6 },
    borderWidth: "1px",
    headingFont: MONO_FONT,
    headingTracking: "0.35px",
    light: {
      canvasTop: "#ECF4EF", canvasBottom: "#E2EEE6", cardTop: "#F7FBF8", cardBottom: "#F0F7F2",
      cardHover: "#E6F2EA", cardItemTop: "#EDF6F0", cardItemBottom: "#E4EFE8", chrome: "#EEF6F1",
      rim: "#9FC4AE", shadowRgb: "11 56 38", surfaceBase: "#ECF4EF",
      surfaceRaised: "rgba(247, 251, 248, 0.94)", surfaceElevated: "#F7FBF8",
      surfaceGlass: "rgba(242, 248, 244, 0.88)", surfaceGlassClear: "rgba(242, 248, 244, 0.66)",
      surfaceGlassFallback: "#F2F8F4", textPrimary: "#0B2218", textSecondary: "#335746",
      textTertiary: "#628574", textDisabled: "#9BB5A8", strokeSubtle: "rgba(0, 122, 77, 0.22)",
      strokeGlass: "rgba(159, 196, 174, 0.85)", strokeStrong: "rgba(0, 122, 77, 0.62)",
      accentPrimary: "#007A4D", accentPrimarySolid: "#007A4D", accentPrimarySolidTop: "#00945E",
      onAccentPrimary: "#F4FFF9", accentSecondary: "#C97A00",
      accentMuted: "rgba(0, 122, 77, 0.11)", accentGlow: "rgba(0, 122, 77, 0.22)",
      brandBlue: "#0077A8", brandCyan: "#00838F", brandViolet: "#6D44B8", brandAmber: "#C97A00",
      success: "#007A4D", warning: "#C97A00", error: "#C62828",
      cardBorder: "rgba(159, 196, 174, 0.92)", cardBorderStrong: "rgba(0, 122, 77, 0.65)",
      divider: "rgba(0, 122, 77, 0.14)", cardRim: "none",
      cardShadow: "0 0 12px rgba(0, 122, 77, 0.08)", hoverShadow: "0 0 20px rgba(0, 122, 77, 0.16)",
      itemCardShadow: "0 0 8px rgba(0, 122, 77, 0.06)", itemHoverShadow: "0 0 14px rgba(0, 122, 77, 0.14)",
      shadowElevated: "0 0 12px rgba(0, 122, 77, 0.08)",
      shadowFloat: "0 6px 22px rgba(0, 122, 77, 0.14)",
      shadowGlass: "0 0 16px rgba(0, 122, 77, 0.10)",
    },
    dark: {
      canvasTop: "#060C0A", canvasBottom: "#0A1410", cardTop: "#0E1B16", cardBottom: "#0A1410",
      cardHover: "#14261F", cardItemTop: "#11211B", cardItemBottom: "#0B1712", chrome: "#0A1410",
      rim: "#1E4736", shadowRgb: "0 0 0", surfaceBase: "#060C0A",
      surfaceRaised: "rgba(14, 27, 22, 0.94)", surfaceElevated: "#0E1B16",
      surfaceGlass: "rgba(11, 22, 18, 0.88)", surfaceGlassClear: "rgba(11, 22, 18, 0.66)",
      surfaceGlassFallback: "#0B1612", textPrimary: "#E0FFEF", textSecondary: "#7EC4A3",
      textTertiary: "#4C876C", textDisabled: "#2D5241", strokeSubtle: "rgba(0, 230, 138, 0.22)",
      strokeGlass: "rgba(30, 71, 54, 0.90)", strokeStrong: "rgba(0, 230, 138, 0.68)",
      accentPrimary: "#00E68A", accentPrimarySolid: "#008F57", accentPrimarySolidTop: "#00AD69",
      onAccentPrimary: "#04160E", accentSecondary: "#FFB300",
      accentMuted: "rgba(0, 230, 138, 0.14)", accentGlow: "rgba(0, 230, 138, 0.30)",
      brandBlue: "#38D2FF", brandCyan: "#00E5CC", brandViolet: "#B78CFF", brandAmber: "#FFB300",
      success: "#00E68A", warning: "#FFB300", error: "#FF5252",
      cardBorder: "rgba(30, 71, 54, 0.90)", cardBorderStrong: "rgba(0, 230, 138, 0.72)",
      divider: "rgba(0, 230, 138, 0.14)", cardRim: "none",
      cardShadow: "0 0 14px rgba(0, 230, 138, 0.12)", hoverShadow: "0 0 22px rgba(0, 230, 138, 0.24)",
      itemCardShadow: "0 0 8px rgba(0, 230, 138, 0.08)", itemHoverShadow: "0 0 16px rgba(0, 230, 138, 0.20)",
      shadowElevated: "0 0 14px rgba(0, 230, 138, 0.12)",
      shadowFloat: "0 6px 24px rgba(0, 230, 138, 0.22)",
      shadowGlass: "0 0 18px rgba(0, 230, 138, 0.14)",
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
