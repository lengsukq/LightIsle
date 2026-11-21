export interface ModalLayerHandle {
  isTop: () => boolean;
  dispose: () => void;
}

interface ModalLayerEntry {
  id: symbol;
  onEsc?: () => void;
  lockScroll: boolean;
}

const activeLayers: ModalLayerEntry[] = [];
let keyListenerAttached = false;
let savedBodyOverflow: string | null = null;

function syncScrollLock() {
  if (typeof document === "undefined" || !document.body) return;
  const shouldLock = activeLayers.some((entry) => entry.lockScroll);
  if (shouldLock) {
    if (savedBodyOverflow === null) {
      savedBodyOverflow = document.body.style.overflow;
    }
    document.body.style.overflow = "hidden";
  } else if (savedBodyOverflow !== null) {
    document.body.style.overflow = savedBodyOverflow;
    savedBodyOverflow = null;
  }
}

function handleGlobalKeydown(event: KeyboardEvent) {
  if (event.key !== "Escape" || event.defaultPrevented) return;
  const top = activeLayers[activeLayers.length - 1];
  if (!top) return;
  if (top.onEsc) {
    event.preventDefault();
    event.stopPropagation();
    top.onEsc();
  }
}

function syncKeyListener() {
  if (typeof window === "undefined" || typeof window.addEventListener !== "function") return;
  if (activeLayers.length > 0 && !keyListenerAttached) {
    window.addEventListener("keydown", handleGlobalKeydown, true);
    keyListenerAttached = true;
  } else if (activeLayers.length === 0 && keyListenerAttached) {
    window.removeEventListener("keydown", handleGlobalKeydown, true);
    keyListenerAttached = false;
  }
}

export function pushModalLayer(options?: {
  onEsc?: () => void;
  lockScroll?: boolean;
}): ModalLayerHandle {
  const id = Symbol("isle-modal-layer");
  const entry: ModalLayerEntry = {
    id,
    onEsc: options?.onEsc,
    lockScroll: options?.lockScroll !== false,
  };
  activeLayers.push(entry);
  syncScrollLock();
  syncKeyListener();

  let disposed = false;
  return {
    isTop: () => activeLayers.length > 0 && activeLayers[activeLayers.length - 1]?.id === id,
    dispose: () => {
      if (disposed) return;
      disposed = true;
      const idx = activeLayers.findIndex((item) => item.id === id);
      if (idx >= 0) {
        activeLayers.splice(idx, 1);
      }
      syncScrollLock();
      syncKeyListener();
    },
  };
}

export function hasActiveModalLayer(): boolean {
  return activeLayers.length > 0;
}
