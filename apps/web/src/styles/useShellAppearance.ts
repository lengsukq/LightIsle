import { onMounted, onUnmounted, ref } from "vue";
import {
  applyTheme,
  resolveThemePreset,
  THEME_PRESETS,
  type Theme,
  type ThemePresetId,
  type ThemePresetMeta,
} from "./theme.ts";

export const atmospheres: ReadonlyArray<ThemePresetMeta> = THEME_PRESETS;

const THEME_STORAGE_KEY = "lightisle_theme";
const PRESET_STORAGE_KEY = "lightisle_theme_preset";
const LEGACY_ATMOSPHERE_KEY = "lightisle_atmosphere";

/** User appearance preferences do not depend on authentication or NAS APIs. */
export function useShellAppearance() {
  const theme = ref<Theme>("light");
  const atmosphere = ref<ThemePresetId>("warm_gallery");
  const sidebarExpanded = ref(true);
  const moreMenuOpen = ref(false);
  const fileViewMode = ref<"list" | "grid">("list");
  const createFolderOpen = ref(false);

  function setFileViewMode(mode: "list" | "grid") {
    fileViewMode.value = mode;
    try {
      localStorage.setItem("lightisle_file_view_mode", mode);
    } catch {
      // Ignore storage restrictions.
    }
  }

  function applyAtmosphere(value: ThemePresetId) {
    const resolved = resolveThemePreset(value);
    atmosphere.value = resolved;
    applyTheme(theme.value, resolved);
    try {
      localStorage.setItem(PRESET_STORAGE_KEY, resolved);
      localStorage.setItem(LEGACY_ATMOSPHERE_KEY, resolved);
    } catch {
      // Privacy mode may disable persistent storage.
    }
  }

  function setAtmosphere(value: ThemePresetId) {
    applyAtmosphere(value);
  }

  function switchTheme() {
    const next: Theme = theme.value === "light" ? "dark" : "light";
    theme.value = next;
    applyTheme(next, atmosphere.value);
    try {
      localStorage.setItem(THEME_STORAGE_KEY, next);
    } catch {
      // Privacy mode may disable persistent storage.
    }
  }

  function toggleSidebar() {
    sidebarExpanded.value = !sidebarExpanded.value;
    try {
      sessionStorage.setItem("lightisle_sidebar_expanded", sidebarExpanded.value ? "1" : "0");
    } catch {
      // Collapsing the sidebar works even if session storage is unavailable.
    }
  }

  function handleDockKeydown(event: KeyboardEvent) {
    if ((event.metaKey || event.ctrlKey) &&
        (event.key === "s" || event.key === "S") &&
        (event.metaKey && event.ctrlKey || event.shiftKey)) {
      event.preventDefault();
      toggleSidebar();
    }
  }

  onMounted(() => {
    let initialTheme: Theme = matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
    try {
      const savedTheme = localStorage.getItem(THEME_STORAGE_KEY);
      if (savedTheme === "light" || savedTheme === "dark") {
        initialTheme = savedTheme;
      }
    } catch {
      // Fall back to system preference.
    }
    theme.value = initialTheme;

    let initialPreset: ThemePresetId = "warm_gallery";
    try {
      const savedPreset =
        localStorage.getItem(PRESET_STORAGE_KEY) ??
        localStorage.getItem(LEGACY_ATMOSPHERE_KEY);
      initialPreset = resolveThemePreset(savedPreset);
    } catch {
      initialPreset = "warm_gallery";
    }
    atmosphere.value = initialPreset;
    applyTheme(initialTheme, initialPreset);

    try {
      const savedView = localStorage.getItem("lightisle_file_view_mode");
      if (savedView === "grid" || savedView === "list") fileViewMode.value = savedView;
    } catch {
      // Keep default list view.
    }
    try {
      const saved = sessionStorage.getItem("lightisle_sidebar_expanded");
      if (saved !== null) sidebarExpanded.value = saved === "1";
      else if (window.innerWidth <= 1080) sidebarExpanded.value = false;
    } catch {
      if (window.innerWidth <= 1080) sidebarExpanded.value = false;
    }
    window.addEventListener("keydown", handleDockKeydown);
  });

  onUnmounted(() => window.removeEventListener("keydown", handleDockKeydown));
  return {
    theme,
    atmosphere,
    atmospheres,
    sidebarExpanded,
    moreMenuOpen,
    fileViewMode,
    setFileViewMode,
    createFolderOpen,
    setAtmosphere,
    switchTheme,
    toggleSidebar,
  };
}
