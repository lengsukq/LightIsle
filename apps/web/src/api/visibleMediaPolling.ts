export function createVisibleMediaPolling(refresh: () => unknown, interval: number) {
  let active = false;
  let timer: number | undefined;
  function sync() {
    if (active && !document.hidden) {
      if (timer !== undefined) return;
      timer = window.setInterval(() => void refresh(), interval);
    } else if (timer !== undefined) {
      window.clearInterval(timer);
      timer = undefined;
    }
  }
  function visibilityChanged() {
    sync();
    if (active && !document.hidden) void refresh();
  }
  return (next: boolean) => {
    if (active === next) return;
    active = next;
    if (active) document.addEventListener("visibilitychange", visibilityChanged);
    else document.removeEventListener("visibilitychange", visibilityChanged);
    sync();
  };
}
