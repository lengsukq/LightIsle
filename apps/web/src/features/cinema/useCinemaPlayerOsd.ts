import { ref } from "vue";

export function useCinemaPlayerOsd() {
  const osdMessage = ref("");
  let osdTimer: number | undefined;

  function clearOsd() {
    if (osdTimer) {
      window.clearTimeout(osdTimer);
      osdTimer = undefined;
    }
    osdMessage.value = "";
  }

  function showOsd(text: string) {
    osdMessage.value = text;
    if (osdTimer) window.clearTimeout(osdTimer);
    osdTimer = window.setTimeout(() => {
      osdTimer = undefined;
      osdMessage.value = "";
    }, 1100);
  }

  function showJumpOsd(seconds: number) {
    showOsd(seconds > 0 ? `+${seconds}s` : `${seconds}s`);
  }

  function showPlayOsd(willPlay: boolean) {
    showOsd(willPlay ? "继续播放" : "已暂停");
  }

  function showVolumeOsd(muted: boolean, volume: number) {
    showOsd(muted || volume === 0 ? "已静音" : `音量 ${Math.round(volume * 100)}%`);
  }

  return {
    osdMessage,
    clearOsd,
    showOsd,
    showJumpOsd,
    showPlayOsd,
    showVolumeOsd,
  };
}
