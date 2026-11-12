<script setup lang="ts">
import { Film, Play } from "lucide-vue-next";
import { duration, percent } from "./useCinemaMetadata.ts";
import type { Movie } from "./cinemaTypes.ts";

defineProps<{
  featuredFilm: Movie | null;
  continueShelf: Movie[];
  recentShelf: Movie[];
  showRecentShelf: boolean;
  shelvesError: string;
  posterFailed: Record<number, boolean>;
  posterReady: (movie: Movie) => boolean;
  posterUrl: (movie: Movie) => string;
}>();

const emit = defineEmits<{
  (e: "retry-shelves"): void;
  (e: "open-film", film: Movie, autoStart?: boolean): void;
  (e: "filter-mode", mode: string): void;
  (e: "poster-error", id: number): void;
}>();
</script>

<template>
  <section class="cinema-home">
    <div v-if="shelvesError" class="cinema-alert" role="status">
      内容推荐暂不可用，仍可浏览下方影片。
      <button type="button" class="account-action" @click="emit('retry-shelves')">重试</button>
    </div>

    <div v-if="featuredFilm" class="cinema-featured" aria-label="影视库精选">
      <div class="cinema-featured-poster">
        <img
          v-if="(featuredFilm.posterURL || posterReady(featuredFilm)) && !posterFailed[featuredFilm.id]"
          :src="posterUrl(featuredFilm)"
          :alt="featuredFilm.title + '海报'"
          loading="lazy"
          @error="emit('poster-error', featuredFilm.id)"
        />
        <Film v-else :size="48" />
      </div>
      <div class="cinema-featured-info">
        <span class="cinema-featured-kicker">
          {{ featuredFilm.position > 5 && !featuredFilm.completed ? "继续观看" : "来自你的影视库" }}
        </span>
        <h3>{{ featuredFilm.title }}</h3>
        <p class="cinema-featured-meta">
          {{
            [
              featuredFilm.year || "",
              featuredFilm.kind === "series" ? "剧集" : "电影",
              duration(featuredFilm.durationSeconds || featuredFilm.duration),
            ].filter(Boolean).join(" · ")
          }}
        </p>
        <p v-if="featuredFilm.overview" class="cinema-featured-description">{{ featuredFilm.overview }}</p>
        <div class="cinema-featured-actions">
          <button type="button" class="cinema-featured-play" @click="emit('open-film', featuredFilm, true)">
            <Play :size="18" /> {{ featuredFilm.position > 5 && !featuredFilm.completed ? "继续播放" : "开始播放" }}
          </button>
          <button type="button" class="cinema-featured-detail" @click="emit('open-film', featuredFilm, false)">影片详情</button>
        </div>
      </div>
    </div>

    <div v-if="continueShelf.length" class="cinema-home-section">
      <div class="cinema-home-heading">
        <h3>继续观看</h3>
        <button type="button" @click="emit('filter-mode', 'continue')">查看全部</button>
      </div>
      <div class="cinema-home-rail" role="group" aria-label="继续观看的影片">
        <button
          v-for="movie in continueShelf"
          :key="movie.id"
          type="button"
          class="cinema-home-card"
          :aria-label="'继续观看 ' + movie.title"
          @click="emit('open-film', movie, true)"
        >
          <span class="cinema-home-cover">
            <img
              v-if="(movie.posterURL || posterReady(movie)) && !posterFailed[movie.id]"
              :src="posterUrl(movie)"
              :alt="movie.title + '海报'"
              loading="lazy"
              @error="emit('poster-error', movie.id)"
            />
            <Film v-else :size="32" />
          </span>
          <strong :title="movie.title">{{ movie.title }}</strong>
          <small>已看 {{ percent(movie) }}%</small>
          <span class="cinema-home-progress"><span :style="{ width: percent(movie) + '%' }"></span></span>
        </button>
      </div>
    </div>

    <div v-if="showRecentShelf" class="cinema-home-section">
      <div class="cinema-home-heading">
        <h3>最近添加</h3>
        <button type="button" @click="emit('filter-mode', 'all')">浏览全部</button>
      </div>
      <div class="cinema-home-rail" role="group" aria-label="最近添加的影片">
        <button
          v-for="movie in recentShelf"
          :key="movie.id"
          type="button"
          class="cinema-home-card"
          :aria-label="'查看影片 ' + movie.title"
          @click="emit('open-film', movie, false)"
        >
          <span class="cinema-home-cover">
            <img
              v-if="(movie.posterURL || posterReady(movie)) && !posterFailed[movie.id]"
              :src="posterUrl(movie)"
              :alt="movie.title + '海报'"
              loading="lazy"
              @error="emit('poster-error', movie.id)"
            />
            <Film v-else :size="32" />
          </span>
          <strong :title="movie.title">{{ movie.title }}</strong>
          <small>{{ movie.year || "影片" }} · {{ duration(movie.durationSeconds || movie.duration) }}</small>
        </button>
      </div>
    </div>
  </section>
</template>
