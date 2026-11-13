<script setup lang="ts">
import { computed, nextTick, ref, watch } from "vue";
import { CheckCircle2, Play, RotateCcw, Tv } from "lucide-vue-next";
import IsleBadge from "./IsleBadge.vue";
import IsleBanner from "./IsleBanner.vue";
import IsleButton from "./IsleButton.vue";
import IsleModal from "./IsleModal.vue";
import { duration, percent } from "./useCinemaMetadata.ts";
import {
  formatCinemaEpisodeCode,
  formatCinemaResumeLabel,
  pickInitialSeriesSeason,
} from "./cinemaSubtitles.ts";
import type { Movie, SeriesInfo } from "./cinemaTypes.ts";

const props = defineProps<{
  open: boolean;
  seriesDetail: { series: SeriesInfo; films: Movie[] } | null;
  seriesDetailLoading: boolean;
  seriesDetailError: string;
  seriesTmdbId: string;
  seriesTmdbBusy: boolean;
  seriesTmdbMessage: string;
  admin: boolean;
  seasonNumbers: number[];
}>();

const emit = defineEmits<{
  (e: "close"): void;
  (e: "play-episode", episode: Movie): void;
  (e: "continue-series", series: SeriesInfo): void;
  (e: "toggle-watched", episode: Movie, completed: boolean): void;
  (e: "clear-progress", episode: Movie): void;
  (e: "update:seriesTmdbId", value: string): void;
  (e: "match-tmdb", series: SeriesInfo): void;
}>();

const activeSeason = ref<number | "all">("all");
const episodeRefs = new Map<number, HTMLElement>();

function setEpisodeRef(id: number, el: unknown) {
  if (el instanceof HTMLElement) episodeRefs.set(id, el);
  else episodeRefs.delete(id);
}

const activeResumeEpisode = computed<Movie | null>(() => {
  const detail = props.seriesDetail;
  if (!detail) return null;
  if (detail.series.nextFilmId) {
    const matched = detail.films.find((item) => item.id === detail.series.nextFilmId);
    if (matched) return matched;
  }
  const inProgress = detail.films.find((item) => (item.position || 0) > 5 && !item.completed);
  if (inProgress) return inProgress;
  if (detail.series.watchedCount > 0) {
    return detail.films.find((item) => !item.completed) ?? null;
  }
  return detail.films[0] ?? null;
});

const resumeButtonLabel = computed(() => {
  const ep = activeResumeEpisode.value;
  if (!ep) return "开始播放";
  if ((ep.position || 0) > 5 && !ep.completed) {
    return formatCinemaResumeLabel(ep);
  }
  const code = formatCinemaEpisodeCode(ep.season, ep.episode);
  if (props.seriesDetail && props.seriesDetail.series.watchedCount > 0) {
    return code ? `继续播放 ${code}` : "继续播放下一集";
  }
  return code ? `从 ${code} 开始播放` : "从第一集开始";
});

const visibleSeasons = computed(() => {
  if (activeSeason.value === "all") return props.seasonNumbers;
  return props.seasonNumbers.filter((s) => s === activeSeason.value);
});

watch(
  () => [props.open, props.seriesDetail?.series.id, props.seriesDetail?.films.length] as const,
  async ([isOpen]) => {
    const detail = props.seriesDetail;
    if (!isOpen || !detail) return;
    if (props.seasonNumbers.length > 1) {
      const picked = pickInitialSeriesSeason(detail.films, detail.series.nextFilmId);
      activeSeason.value = props.seasonNumbers.includes(picked) ? picked : props.seasonNumbers[0] ?? "all";
    } else {
      activeSeason.value = "all";
    }
    await nextTick();
    const target = activeResumeEpisode.value;
    if (!target) return;
    const el = episodeRefs.get(target.id);
    if (el) {
      const reduced = typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
      el.scrollIntoView({ block: "nearest", behavior: reduced ? "auto" : "smooth" });
    }
  },
  { immediate: true },
);

function seasonLabel(season: number): string {
  return season <= 0 ? "特别篇 / 未分季" : `第 ${season} 季`;
}
</script>

<template>
  <IsleModal
    :open="open && Boolean(seriesDetail)"
    :title="seriesDetail?.series.name || ''"
    :description="
      seriesDetail
        ? (seriesDetail.series.year || '剧集') +
          ' · 已看 ' +
          seriesDetail.series.watchedCount +
          '/' +
          seriesDetail.series.episodeCount +
          ' 集' +
          (seriesDetail.series.tmdbId ? ' · TMDB' : '')
        : ''
    "
    size="wide"
    role="dialog"
    :aria-label="(seriesDetail?.series.name || '剧集') + ' · 剧集列表'"
    @close="emit('close')"
  >
    <template #icon><Tv :size="18" /></template>

    <template v-if="seriesDetail">
      <div v-if="activeResumeEpisode" class="series-resume-bar">
        <div class="series-resume-text">
          <strong>{{ activeResumeEpisode.title }}</strong>
          <small>
            {{ formatCinemaEpisodeCode(activeResumeEpisode.season, activeResumeEpisode.episode) || "单集" }}
            · {{ duration(activeResumeEpisode.durationSeconds || activeResumeEpisode.duration) }}
          </small>
        </div>
        <IsleButton variant="primary" size="sm" @click="emit('play-episode', activeResumeEpisode)">
          <template #icon><Play :size="15" fill="currentColor" /></template>
          {{ resumeButtonLabel }}
        </IsleButton>
      </div>

      <p v-if="seriesDetail.series.overview" class="cinema-synopsis">{{ seriesDetail.series.overview }}</p>

      <IsleBanner v-if="seriesDetailLoading" type="info" compact message="正在读取剧集分集…" class="series-banner" />
      <IsleBanner v-if="seriesDetailError" type="error" compact :message="seriesDetailError" class="series-banner" />

      <div v-if="seasonNumbers.length > 1" class="series-season-tabs" role="tablist" aria-label="剧季切换">
        <button
          v-for="s in seasonNumbers"
          :key="s"
          type="button"
          role="tab"
          class="series-season-pill"
          :class="{ active: activeSeason === s }"
          :aria-selected="activeSeason === s"
          @click="activeSeason = s"
        >
          {{ seasonLabel(s) }}
        </button>
        <button
          type="button"
          role="tab"
          class="series-season-pill"
          :class="{ active: activeSeason === 'all' }"
          :aria-selected="activeSeason === 'all'"
          @click="activeSeason = 'all'"
        >
          全部季（{{ seriesDetail.films.length }}）
        </button>
      </div>

      <div v-for="season in visibleSeasons" :key="season" class="cinema-season">
        <h4>{{ seasonLabel(season) }}</h4>
        <div
          v-for="episode in seriesDetail.films.filter((f) => f.season === season)"
          :key="episode.id"
          :ref="(el) => setEpisodeRef(episode.id, el)"
          class="cinema-episode-row"
          :class="{ 'cinema-episode-row--resume': activeResumeEpisode?.id === episode.id }"
        >
          <button type="button" class="cinema-episode-main" @click="emit('play-episode', episode)">
            <span class="cinema-episode-no">E{{ episode.episode }}</span>
            <span class="cinema-episode-title">{{ episode.title }}</span>
            <span class="cinema-episode-meta">{{ duration(episode.durationSeconds || episode.duration) }}</span>
            <IsleBadge v-if="episode.completed" variant="online" size="sm">已看完</IsleBadge>
            <IsleBadge v-else-if="episode.position > 5" variant="accent" size="sm">已看 {{ percent(episode) }}%</IsleBadge>
          </button>
          <div class="cinema-episode-actions">
            <button
              type="button"
              class="cinema-episode-action-btn"
              :title="episode.completed ? '标记为未看' : '标记为已看完'"
              @click="emit('toggle-watched', episode, !episode.completed)"
            >
              <CheckCircle2 :size="14" />
              <span>{{ episode.completed ? "标未看" : "标已看" }}</span>
            </button>
            <button
              v-if="episode.position > 5 && !episode.completed"
              type="button"
              class="cinema-episode-action-btn"
              title="清除本集播放进度，移出继续观看"
              @click="emit('clear-progress', episode)"
            >
              <RotateCcw :size="13" />
              <span>重头/移除续播</span>
            </button>
          </div>
        </div>
      </div>

      <p v-if="seriesTmdbMessage" class="cinema-alert" role="status">{{ seriesTmdbMessage }}</p>

      <details v-if="admin" class="cinema-tmdb-panel">
        <summary>匹配 TMDB 剧集资料（使用 Mac App 配置的 Token）</summary>
        <form class="cinema-tmdb-form" @submit.prevent="emit('match-tmdb', seriesDetail.series)">
          <input
            :value="seriesTmdbId"
            type="text"
            inputmode="numeric"
            placeholder="TMDB 剧集 ID（数字，可在 themoviedb.org 剧集页地址中找到）"
            :disabled="seriesTmdbBusy"
            @input="emit('update:seriesTmdbId', ($event.target as HTMLInputElement).value)"
          />
          <IsleButton type="submit" variant="primary" size="sm" :disabled="seriesTmdbBusy">
            {{ seriesTmdbBusy ? "匹配中…" : "匹配" }}
          </IsleButton>
        </form>
      </details>
    </template>
  </IsleModal>
</template>

<style scoped>
.series-resume-bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  flex-wrap: wrap;
  padding: 12px 14px;
  margin-bottom: 14px;
  border-radius: 14px;
  border: 1px solid color-mix(in srgb, var(--accent-primary) 34%, var(--fluid-card-border));
  background: color-mix(in srgb, var(--accent-primary) 10%, var(--fluid-card-fill));
}
.series-resume-text {
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-width: 0;
}
.series-resume-text strong {
  font-size: 13.5px;
  color: var(--text-primary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.series-resume-text small {
  font-size: 12px;
  color: var(--text-secondary);
}
.cinema-synopsis {
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  max-height: 150px;
  overflow: auto;
  font-size: 13px;
  color: var(--text-secondary);
  line-height: 1.6;
  margin: 0 0 12px;
}
.series-banner {
  margin-bottom: 10px;
}
.series-season-tabs {
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
  margin: 10px 0 14px;
}
.series-season-pill {
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-fill);
  color: var(--text-secondary);
  border-radius: var(--radius-pill);
  padding: 6px 13px;
  font-size: 12.5px;
  font-weight: 600;
  cursor: pointer;
  transition: background var(--motion-fast) ease, color var(--motion-fast) ease, border-color var(--motion-fast) ease;
}
.series-season-pill:hover {
  color: var(--text-primary);
  background: var(--fluid-card-hover);
}
.series-season-pill.active {
  background: var(--accent-primary);
  border-color: var(--accent-primary);
  color: #fff;
}
.cinema-season h4 {
  margin: 10px 0 8px;
  font-size: 14px;
  color: var(--text-primary);
}
.cinema-episode-row {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 6px 10px;
  border: 1px solid var(--fluid-card-border);
  border-radius: var(--radius-md);
  background: var(--fluid-card-fill);
  margin-bottom: 8px;
  transition: background var(--motion-fast) ease, border-color var(--motion-fast) ease;
}
.cinema-episode-row:hover {
  background: var(--fluid-card-hover);
}
.cinema-episode-row--resume {
  border-color: color-mix(in srgb, var(--accent-primary) 55%, var(--fluid-card-border));
  background: color-mix(in srgb, var(--accent-primary) 8%, var(--fluid-card-fill));
}
.cinema-episode-main {
  flex: 1;
  min-width: 0;
  display: flex;
  align-items: center;
  gap: 10px;
  border: 0;
  background: transparent;
  color: var(--text-primary);
  text-align: left;
  padding: 6px 4px;
  cursor: pointer;
}
.cinema-episode-no {
  font-weight: 700;
  font-size: 12.5px;
  color: var(--accent-primary);
  min-width: 34px;
  flex-shrink: 0;
}
.cinema-episode-title {
  flex: 1;
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  font-size: 13px;
}
.cinema-episode-meta {
  color: var(--text-tertiary);
  font-size: 11.5px;
  flex-shrink: 0;
}
.cinema-episode-actions {
  display: flex;
  align-items: center;
  gap: 4px;
  flex-shrink: 0;
}
.cinema-episode-action-btn {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  border: 1px solid var(--fluid-card-border);
  background: transparent;
  color: var(--text-secondary);
  border-radius: var(--radius-sm);
  padding: 4px 8px;
  font-size: 11.5px;
  font-weight: 600;
  cursor: pointer;
}
.cinema-episode-action-btn:hover {
  color: var(--accent-primary);
  border-color: var(--accent-primary);
}
.cinema-alert {
  background: var(--fluid-card-fill);
  color: var(--accent-primary);
  border: 1px solid var(--fluid-card-border);
  border-radius: var(--radius-md);
  padding: 10px 14px;
  font-size: 12.5px;
  margin: 12px 0;
}
.cinema-tmdb-panel {
  margin: 14px 0 4px;
  padding: 10px 0 0;
  border-top: 1px solid var(--stroke-subtle);
  font-size: 12px;
}
.cinema-tmdb-panel summary {
  cursor: pointer;
  font-weight: 650;
  color: var(--text-primary);
  padding: 4px 0;
}
.cinema-tmdb-form {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  margin: 10px 0;
}
.cinema-tmdb-form input {
  min-width: 170px;
  flex: 1;
  border: 1px solid var(--stroke-subtle);
  border-radius: 8px;
  background: var(--surface-base);
  color: var(--text-primary);
  padding: 8px;
}
@media (max-width: 640px) {
  .cinema-episode-row {
    flex-direction: column;
    align-items: stretch;
  }
  .cinema-episode-actions {
    justify-content: flex-end;
    padding-bottom: 2px;
  }
}
@media (prefers-reduced-motion: reduce) {
  .series-season-pill,
  .cinema-episode-row {
    transition: none;
  }
}
</style>
