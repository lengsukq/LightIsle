type Bindings = {
  dialog: HTMLElement | null;
  playing: boolean;
  playlistOpen: boolean;
  showControls: () => void;
  jump: (seconds: number) => void;
  togglePlay: () => void;
  closePlaylist: () => void;
  close: () => void;
};

export function handleCinemaKeydown(event: KeyboardEvent, bindings: Bindings) {
  if (bindings.dialog && event.key === "Tab") {
    trapDialogFocus(event, bindings.dialog);
    return;
  }
  const target = event.target;
  const interactive = target instanceof HTMLElement && Boolean(target.closest(
    'button,a,input,textarea,select,[contenteditable="true"],[role="slider"]',
  ));
  if (bindings.playing && !event.altKey && !event.ctrlKey && !event.metaKey && !interactive) {
    bindings.showControls();
    if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      event.preventDefault();
      bindings.jump(event.key === "ArrowLeft" ? -10 : 10);
      return;
    }
    if (event.key === " ") {
      event.preventDefault();
      bindings.togglePlay();
      return;
    }
  }
  if (event.key !== "Escape") return;
  if (bindings.playing && bindings.playlistOpen) {
    event.preventDefault();
    bindings.closePlaylist();
  } else if (bindings.dialog) {
    event.preventDefault();
    bindings.close();
  }
}

function trapDialogFocus(event: KeyboardEvent, dialog: HTMLElement) {
  const focusable = Array.from(dialog.querySelectorAll<HTMLElement>(
    'a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),textarea:not([disabled]),video[controls],[tabindex]:not([tabindex="-1"])',
  )).filter(element => element.offsetWidth > 0 || element.offsetHeight > 0 || element === document.activeElement);
  if (!focusable.length) {
    event.preventDefault();
    dialog.focus();
    return;
  }
  const first = focusable[0];
  const last = focusable[focusable.length - 1];
  const active = document.activeElement;
  if (!focusable.includes(active as HTMLElement) || (event.shiftKey ? active === first : active === last)) {
    event.preventDefault();
    (event.shiftKey ? last : first).focus();
  }
}
