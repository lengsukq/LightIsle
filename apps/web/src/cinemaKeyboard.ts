export type CinemaKeyBindings = {
  dialog: HTMLElement | null;
  playing: boolean;
  playlistOpen: boolean;
  popoverOpen?: boolean;
  isFullscreen?: boolean;
  showControls: () => void;
  jump: (seconds: number) => void;
  togglePlay: () => void;
  adjustVolume?: (delta: number) => void;
  toggleMute?: () => void;
  toggleFullscreen?: () => void;
  exitFullscreen?: () => void;
  startHoldBoost?: () => void;
  stopHoldBoost?: () => void;
  closePopover?: () => void;
  closePlaylist: () => void;
  close: () => void;
};

type KeyEventLike = {
  key: string;
  code?: string;
  repeat?: boolean;
  altKey: boolean;
  ctrlKey: boolean;
  metaKey: boolean;
  shiftKey?: boolean;
  target: EventTarget | null;
  preventDefault: () => void;
};

function isTypingInteractiveTarget(target: EventTarget | null): boolean {
  if (!target || typeof (target as HTMLElement).closest !== "function") return false;
  return Boolean(
    (target as HTMLElement).closest(
      'input:not([type="range"]),textarea,select,[contenteditable="true"],.cinema-popover-menu,.cinema-player-playlist,.cinema-stage-card',
    ),
  );
}

function isNonPlayingInteractiveTarget(target: EventTarget | null): boolean {
  if (!target || typeof (target as HTMLElement).closest !== "function") return false;
  return Boolean(
    (target as HTMLElement).closest('button,a,input,textarea,select,[contenteditable="true"],[role="slider"]'),
  );
}

function trapDialogFocus(event: KeyEventLike & { shiftKey?: boolean }, dialog: HTMLElement) {
  const focusables = Array.from(
    dialog.querySelectorAll<HTMLElement>(
      'button:not([disabled]),a[href],input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])',
    ),
  ).filter((el) => el.offsetParent !== null || el === document.activeElement);
  if (!focusables.length) return;
  const first = focusables[0];
  const last = focusables[focusables.length - 1];
  const active = document.activeElement;
  if (event.shiftKey) {
    if (active === first || !dialog.contains(active)) {
      event.preventDefault();
      last.focus();
    }
    return;
  }
  if (active === last || !dialog.contains(active)) {
    event.preventDefault();
    first.focus();
  }
}

export const RIGHT_HOLD_BOOST_DELAY_MS = 260;

export function createCinemaKeyboardController(holdDelayMs = RIGHT_HOLD_BOOST_DELAY_MS) {
  let rightTimer: ReturnType<typeof setTimeout> | undefined;
  let rightHeld = false;
  let rightBoosted = false;
  let lastBindings: CinemaKeyBindings | null = null;

  function cancelRightHold(triggerStop: boolean) {
    if (rightTimer !== undefined) {
      clearTimeout(rightTimer);
      rightTimer = undefined;
    }
    const wasBoosted = rightBoosted;
    rightHeld = false;
    rightBoosted = false;
    if (triggerStop && wasBoosted) {
      lastBindings?.stopHoldBoost?.();
    }
  }

  function handleKeydown(event: KeyEventLike, bindings: CinemaKeyBindings) {
    lastBindings = bindings;
    if (bindings.dialog && event.key === "Tab") {
      trapDialogFocus(event, bindings.dialog);
      return;
    }

    if (event.key === "Escape") {
      if (bindings.playing && bindings.isFullscreen) {
        event.preventDefault();
        (bindings.exitFullscreen ?? bindings.toggleFullscreen)?.();
        return;
      }
      if (bindings.playing && bindings.popoverOpen) {
        event.preventDefault();
        bindings.closePopover?.();
        return;
      }
      if (bindings.playing && bindings.playlistOpen) {
        event.preventDefault();
        bindings.closePlaylist();
        return;
      }
      if (bindings.dialog) {
        event.preventDefault();
        cancelRightHold(true);
        bindings.close();
      }
      return;
    }

    const blocked = bindings.playing
      ? isTypingInteractiveTarget(event.target)
      : isNonPlayingInteractiveTarget(event.target);

    if (!bindings.playing || event.altKey || event.ctrlKey || event.metaKey || blocked) {
      return;
    }

    const isSpace = event.key === " " || event.code === "Space";
    if (isSpace) {
      event.preventDefault();
      bindings.showControls();
      bindings.togglePlay();
      return;
    }

    if (event.key === "ArrowLeft") {
      event.preventDefault();
      bindings.showControls();
      bindings.jump(-10);
      return;
    }

    if (event.key === "ArrowRight") {
      event.preventDefault();
      bindings.showControls();
      if (event.repeat || rightHeld) return;
      rightHeld = true;
      rightBoosted = false;
      if (bindings.startHoldBoost) {
        rightTimer = setTimeout(() => {
          rightTimer = undefined;
          if (!rightHeld) return;
          rightBoosted = true;
          bindings.startHoldBoost?.();
        }, holdDelayMs);
      } else {
        rightHeld = false;
        bindings.jump(10);
      }
      return;
    }

    if (event.key === "ArrowUp" || event.key === "ArrowDown") {
      event.preventDefault();
      bindings.showControls();
      bindings.adjustVolume?.(event.key === "ArrowUp" ? 0.05 : -0.05);
      return;
    }

    if (event.key === "m" || event.key === "M") {
      event.preventDefault();
      bindings.showControls();
      bindings.toggleMute?.();
      return;
    }

    if (event.key === "f" || event.key === "F") {
      event.preventDefault();
      bindings.showControls();
      bindings.toggleFullscreen?.();
    }
  }

  function handleKeyup(event: KeyEventLike, bindings?: CinemaKeyBindings) {
    if (bindings) lastBindings = bindings;
    if (event.key !== "ArrowRight" || !rightHeld) return;
    if (rightTimer !== undefined) {
      clearTimeout(rightTimer);
      rightTimer = undefined;
    }
    const wasBoosted = rightBoosted;
    rightHeld = false;
    rightBoosted = false;
    if (wasBoosted) {
      lastBindings?.stopHoldBoost?.();
    } else if (lastBindings?.playing) {
      lastBindings.showControls();
      lastBindings.jump(10);
    }
  }

  function reset() {
    cancelRightHold(true);
  }

  return {
    handleKeydown,
    handleKeyup,
    reset,
  };
}

const defaultKeyboardController = createCinemaKeyboardController();

export function handleCinemaKeydown(event: KeyboardEvent, bindings: CinemaKeyBindings) {
  defaultKeyboardController.handleKeydown(event, bindings);
}
