import { onMounted, onUnmounted, ref } from "vue";
import { applyTheme, type Theme } from "./theme";

type Atmosphere = "aurora" | "azure" | "sunset" | "nebula";

export const atmospheres: ReadonlyArray<{ id: Atmosphere; name: string; icon: string }> = [
  { id: "aurora", name: "七彩极光", icon: "🌈" },
  { id: "azure", name: "琉璃晴海", icon: "🌊" },
  { id: "sunset", name: "落日晚霞", icon: "🌅" },
  { id: "nebula", name: "幻紫星云", icon: "🌌" },
];

/** User appearance preferences do not depend on authentication or NAS APIs. */
export function useShellAppearance() {
  const theme = ref<Theme>("light");
  const atmosphere = ref<Atmosphere>("aurora");
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

  function applyAtmosphere(value: Atmosphere) {
    atmosphere.value = value;
    document.documentElement.dataset.atmosphere = value;
    try {
      localStorage.setItem("lightisle_atmosphere", value);
    } catch {
      // Privacy mode may disable persistent storage.
    }
  }

  function cycleAtmosphere() {
    const current = atmospheres.findIndex(item => item.id === atmosphere.value);
    applyAtmosphere(atmospheres[(current + 1) % atmospheres.length].id);
  }

  function switchTheme() {
    theme.value = theme.value === "light" ? "dark" : "light";
    applyTheme(theme.value);
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
    theme.value = matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
    applyTheme(theme.value);
    try {
      const saved = localStorage.getItem("lightisle_atmosphere") as Atmosphere | null;
      applyAtmosphere(saved && atmospheres.some(a => a.id === saved) ? saved : "aurora");
    } catch {
      applyAtmosphere("aurora");
    }
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
    theme, atmosphere, atmospheres, sidebarExpanded,
    moreMenuOpen, fileViewMode, setFileViewMode, createFolderOpen,
    cycleAtmosphere, switchTheme, toggleSidebar,
  };
}
