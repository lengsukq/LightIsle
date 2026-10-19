import tokens from "../../../design-tokens/tokens.json";
export type Theme = "light" | "dark";

export function applyTheme(theme: Theme) {
  const colors = tokens.color[theme];
  for (const [name, color] of Object.entries(colors)) {
    const cssVar = name.replace(/[A-Z]/g, (letter) => "-" + letter.toLowerCase());
    document.documentElement.style.setProperty("--" + cssVar, color);
  }

  // Radii
  for (const [name, value] of Object.entries(tokens.radiusPt)) {
    document.documentElement.style.setProperty(`--radius-${name}`, `${value}px`);
  }

  // Motion
  document.documentElement.style.setProperty("--motion-spring", tokens.motion.spring);
  document.documentElement.style.setProperty("--motion-fast", `${tokens.motion.fastMs}ms`);
  document.documentElement.style.setProperty("--motion-normal", `${tokens.motion.normalMs}ms`);
  document.documentElement.style.setProperty("--motion-slow", `${tokens.motion.slowMs}ms`);

  document.documentElement.dataset.theme = theme;
  document.documentElement.style.colorScheme = theme;
}
