<script setup lang="ts">
import { X } from "lucide-vue-next";
import { duration } from "./useCinemaMetadata.ts";
import type { Movie } from "./cinemaTypes.ts";

defineProps<{
  open: boolean;
  selected: Movie;
  sameDirectoryFilms: Movie[];
  playlistDirLabel: string;
  directoryError: string;
  directoryLoading: boolean;
  directoryNextCursor: number;
  leavingPlayer: boolean;
  autoplayNext: boolean;
}>();

const emit = defineEmits<{
  (e: "close"): void;
  (e: "reload", append: boolean): void;
  (e: "select-film", film: Movie): void;
  (e: "toggle-autoplay", checked: boolean): void;
}>();
</script>

<template>
  <Transition name="cinema-playlist-fade">
    <div
      v-if="open"
      class="cinema-player-inspector-backdrop"
      @click.self="emit('close')"
    >
      <section class="cinema-player-playlist" role="region" aria-label="同目录播放列表">
        <div class="cinema-inspector-header">
          <div>
            <strong>同目录播放列表</strong>
            <small class="cinema-playlist-sub">
              {{ playlistDirLabel }} · {{ sameDirectoryFilms.length }} 个视频
            </small>
          </div>
          <button
            type="button"
            title="关闭播放列表"
            aria-label="关闭播放列表"
            @click="emit('close')"
          >
            <X :size="18" />
          </button>
        </div>

        <div v-if="directoryError" class="cinema-alert" role="alert">
          读取失败：{{ directoryError }}
          <button type="button" class="cinema-toast-action" @click="emit('reload', false)">
            重试加载
          </button>
        </div>

        <p v-if="directoryLoading" class="cinema-hint" role="status">正在读取当前目录…</p>

        <div class="cinema-playlist-list">
          <button
            v-for="(item, index) in sameDirectoryFilms"
            :key="item.id"
            type="button"
            class="cinema-playlist-item"
            :class="{ active: item.id === selected.id }"
            :disabled="leavingPlayer"
            @click="emit('select-film', item)"
          >
            <span class="cinema-playlist-index">{{ index + 1 }}</span>
            <span class="cinema-playlist-main">
              <strong>{{ item.title }}</strong>
              <small>
                {{ item.path.split("/").pop() }} · {{ duration(item.durationSeconds || item.duration) }}
              </small>
            </span>
            <span v-if="item.id === selected.id" class="cinema-playlist-badge">正在播放</span>
          </button>
        </div>

        <div class="cinema-playlist-footer">
          <label class="cinema-hud-check">
            <input
              type="checkbox"
              :checked="autoplayNext"
              @change="emit('toggle-autoplay', ($event.target as HTMLInputElement).checked)"
            />
            <span>{{ selected.kind === "series" ? "播完自动下一集" : "播完自动连播" }}</span>
          </label>
          <button
            v-if="directoryNextCursor > 0"
            type="button"
            class="cinema-ghost-pill"
            :disabled="directoryLoading"
            @click="emit('reload', true)"
          >
            加载更多
          </button>
        </div>
      </section>
    </div>
  </Transition>
</template>

<style scoped>
.cinema-player-inspector-backdrop {
  position: absolute;
  inset: 0;
  z-index: 15;
  background: rgba(8, 9, 12, 0.6);
  display: grid;
  place-items: center;
  padding: 20px;
}
.cinema-player-playlist {
  width: min(100%, 500px);
  max-height: 74dvh;
  overflow: hidden;
  padding: 15px 17px;
  border-radius: 16px;
  background: rgba(18, 19, 22, 0.94);
  border: 1px solid rgba(255, 255, 255, 0.16);
  -webkit-backdrop-filter: blur(24px) saturate(160%);
  backdrop-filter: blur(24px) saturate(160%);
  box-shadow: 0 22px 52px rgba(0, 0, 0, 0.72);
  display: flex;
  flex-direction: column;
  gap: 10px;
  color: #f8fafc;
}
.cinema-inspector-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding-bottom: 9px;
  border-bottom: 1px solid rgba(255, 255, 255, 0.12);
}
.cinema-inspector-header strong {
  font-size: 14px;
  color: #fff;
}
.cinema-inspector-header button {
  width: 28px;
  height: 28px;
  border-radius: 999px;
  border: 1px solid rgba(255, 255, 255, 0.16);
  background: rgba(255, 255, 255, 0.1);
  color: #fff;
  display: grid;
  place-items: center;
  cursor: pointer;
  transition: background-color 0.15s ease;
}
.cinema-inspector-header button:hover {
  background: rgba(255, 255, 255, 0.2);
}
.cinema-playlist-sub {
  display: block;
  margin-top: 2px;
  font-size: 11.5px;
  color: rgba(255, 255, 255, 0.64);
  font-variant-numeric: tabular-nums;
}
.cinema-playlist-list {
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 11px;
  background: rgba(255, 255, 255, 0.035);
}
.cinema-playlist-item {
  width: 100%;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 9px 11px;
  border: 0;
  border-bottom: 1px solid rgba(255, 255, 255, 0.08);
  background: transparent;
  color: #fff;
  text-align: left;
  cursor: pointer;
  transition: background-color 0.15s ease;
}
.cinema-playlist-item:last-child {
  border-bottom: 0;
}
.cinema-playlist-item:hover:not(:disabled) {
  background: rgba(255, 255, 255, 0.08);
}
.cinema-playlist-item.active {
  background: color-mix(in srgb, var(--accent-primary, #67d4e0) 15%, rgba(255, 255, 255, 0.03));
}
.cinema-playlist-index {
  width: 24px;
  height: 24px;
  border-radius: 7px;
  background: rgba(255, 255, 255, 0.1);
  display: grid;
  place-items: center;
  font-size: 11.5px;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  flex-shrink: 0;
}
.cinema-playlist-item.active .cinema-playlist-index {
  background: var(--accent-primary-solid, #1a8e9a);
  color: #fff;
}
.cinema-playlist-main {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 2px;
}
.cinema-playlist-main strong,
.cinema-playlist-main small {
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.cinema-playlist-main strong {
  font-size: 13px;
}
.cinema-playlist-main small {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.64);
  font-variant-numeric: tabular-nums;
}
.cinema-playlist-badge {
  padding: 2px 8px;
  border-radius: 999px;
  background: rgba(244, 185, 66, 0.18);
  border: 1px solid rgba(244, 185, 66, 0.34);
  color: #f7cd74;
  font-size: 10.5px;
  font-weight: 700;
  flex-shrink: 0;
}
.cinema-playlist-footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  padding-top: 2px;
}
.cinema-hud-check {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 12px;
  color: rgba(255, 255, 255, 0.88);
  cursor: pointer;
}
.cinema-playlist-fade-enter-active {
  transition: opacity 0.22s var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1));
}
.cinema-playlist-fade-leave-active {
  transition: opacity 0.15s cubic-bezier(0.32, 0, 0.67, 0);
}
.cinema-playlist-fade-enter-from,
.cinema-playlist-fade-leave-to {
  opacity: 0;
}
.cinema-playlist-fade-enter-active .cinema-player-playlist {
  transition: transform 0.24s var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1)), opacity 0.2s ease;
}
.cinema-playlist-fade-leave-active .cinema-player-playlist {
  transition: transform 0.15s ease, opacity 0.15s ease;
}
.cinema-playlist-fade-enter-from .cinema-player-playlist {
  opacity: 0;
  transform: scale(0.96) translate3d(0, 8px, 0);
}
.cinema-playlist-fade-leave-to .cinema-player-playlist {
  opacity: 0;
  transform: scale(0.98) translate3d(0, 4px, 0);
}
@media (prefers-reduced-motion: reduce) {
  .cinema-inspector-header button,
  .cinema-playlist-item,
  .cinema-playlist-fade-enter-active,
  .cinema-playlist-fade-leave-active,
  .cinema-playlist-fade-enter-active .cinema-player-playlist,
  .cinema-playlist-fade-leave-active .cinema-player-playlist {
    transition: none;
  }
}
</style>
