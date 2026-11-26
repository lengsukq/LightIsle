<script setup lang="ts">
import { computed } from "vue";
import { Info, Play, Star } from "lucide-vue-next";
import CinemaPosterArtwork from "./CinemaPosterArtwork.vue";
import {
  cinemaPosterPalette,
  formatCinemaCodec,
  formatCinemaResolution,
} from "./cinemaCatalogDisplay.ts";
import { duration, percent } from "./useCinemaMetadata.ts";
import {
  displayCinemaTitle,
  formatCinemaEpisodeCode,
  formatCinemaResumeLabel,
} from "./cinemaSubtitles.ts";
import type { Movie } from "./cinemaTypes.ts";

const props = defineProps<{
  film: Movie;
  posterReady: boolean;
  posterSrc: string;
  posterFailed: boolean;
}>();

const emit = defineEmits<{
  (e: "open-film", film: Movie, autoStart?: boolean): void;
  (e: "poster-error", id: number): void;
}>();

const displayTitle = computed(() => displayCinemaTitle(props.film));
const hasPoster = computed(() => props.posterReady && !props.posterFailed && Boolean(props.posterSrc));
const isResumable = computed(() => props.film.position > 5 && !props.film.completed);
const progressPct = computed(() => percent(props.film));

const posterKicker = computed(() => {
  if (props.film.kind === "series") {
    const code = formatCinemaEpisodeCode(props.film.season, props.film.episode);
    return code || "剧集";
  }
  return props.film.year ? String(props.film.year) : "电影";
});

const metaSummary = computed(() => {
  const parts: Array<string | number> = [];
  if (props.film.year) parts.push(props.film.year);
  if (props.film.kind === "series") {
    parts.push(formatCinemaEpisodeCode(props.film.season, props.film.episode) || "剧集");
  } else {
    parts.push("电影");
  }
  const dur = duration(props.film.durationSeconds || props.film.duration);
  if (dur && dur !== "时长未知") parts.push(dur);
  return parts.join(" · ");
});

const specTags = computed(() => {
  const tags: string[] = [];
  const res = formatCinemaResolution(props.film.width, props.film.height);
  if (res) tags.push(res);
  const vCodec = formatCinemaCodec(props.film.videoCodec);
  if (vCodec) tags.push(vCodec);
  const aCodec = formatCinemaCodec(props.film.audioCodec);
  if (aCodec) tags.push(aCodec);
  if (props.film.isStrm) tags.push("STRM");
  return tags;
});

const ambientPalette = computed(() => cinemaPosterPalette(props.film.id || displayTitle.value));
</script>

<template>
  <section class="cinema-featured" aria-label="影视库精选">
    <div class="cinema-featured-backdrop" aria-hidden="true">
      <img
        v-if="hasPoster"
        :src="posterSrc"
        alt=""
        loading="lazy"
        decoding="async"
        class="cinema-featured-backdrop-img"
      />
      <div
        v-else
        class="cinema-featured-backdrop-glow"
        :style="{
          background: `${ambientPalette.glow}, ${ambientPalette.bg}`,
        }"
      />
      <div class="cinema-featured-scrim" />
    </div>

    <button
      type="button"
      class="cinema-featured-poster"
      :aria-label="'查看影片 ' + displayTitle"
      @click="emit('open-film', film, false)"
    >
      <img
        v-if="hasPoster"
        :src="posterSrc"
        :alt="displayTitle + '海报'"
        loading="lazy"
        decoding="async"
        @error="emit('poster-error', film.id)"
      />
      <CinemaPosterArtwork
        v-else
        :title="displayTitle"
        :kind="film.kind"
        :year="film.year"
        :seed="film.id"
        :kicker="posterKicker"
      />
    </button>

    <div class="cinema-featured-info">
      <div class="cinema-featured-kicker-row">
        <span class="cinema-featured-kicker">
          {{ isResumable ? "继续观看" : "精选放映" }}
        </span>
        <span
          v-if="film.rating && film.rating > 0"
          class="cinema-featured-rating"
          :aria-label="'评分 ' + film.rating.toFixed(1)"
        >
          <Star :size="11" fill="currentColor" aria-hidden="true" />
          <span>{{ film.rating.toFixed(1) }}</span>
        </span>
      </div>

      <h3>{{ displayTitle }}</h3>

      <div class="cinema-featured-meta-row">
        <p class="cinema-featured-meta">{{ metaSummary }}</p>
        <div v-if="specTags.length" class="cinema-featured-tags" aria-label="视频编码与规格">
          <span v-for="tag in specTags" :key="tag" class="cinema-spec-tag">{{ tag }}</span>
        </div>
      </div>

      <p v-if="film.overview" class="cinema-featured-description">{{ film.overview }}</p>

      <div
        v-if="isResumable && progressPct > 0"
        class="cinema-featured-progress"
        aria-hidden="true"
      >
        <span :style="{ width: `${progressPct}%` }" />
      </div>

      <div class="cinema-featured-actions">
        <button type="button" class="cinema-featured-play" @click="emit('open-film', film, true)">
          <Play :size="16" fill="currentColor" />
          <span>{{ isResumable ? formatCinemaResumeLabel(film) : "开始播放" }}</span>
        </button>
        <button type="button" class="cinema-featured-detail" @click="emit('open-film', film, false)">
          <Info :size="15" />
          <span>影片详情</span>
        </button>
      </div>
    </div>
  </section>
</template>
