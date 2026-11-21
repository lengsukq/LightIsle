type PreloadImageLike = Pick<HTMLImageElement, "src" | "onload" | "onerror" | "removeAttribute">;

// Keep only the current preloader and settle cancelled loads so their async
// callers can release the previous photo. The browser owns its decoded cache.
export function createViewerImageLoader(
  makeImage: () => PreloadImageLike = () => new Image(),
): {
  load(url: string): Promise<boolean>;
  cancel(): void;
} {
  let cancelPending: (() => void) | null = null;
  function cancel() {
    cancelPending?.();
  }
  function load(url: string): Promise<boolean> {
    cancel();
    return new Promise((resolve) => {
      const image = makeImage();
      let settled = false;
      function finish(ok: boolean, aborted = false) {
        if (settled) return;
        settled = true;
        image.onload = image.onerror = null;
        cancelPending = null;
        if (aborted) image.removeAttribute("src");
        resolve(ok);
      }
      cancelPending = () => finish(false, true);
      image.onload = () => finish(true);
      image.onerror = () => finish(false);
      image.src = url;
    });
  }
  return { load, cancel };
}
