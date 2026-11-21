<script setup lang="ts">
import { Film, Play, X } from "lucide-vue-next";
import { duration, percent } from "./useCinemaMetadata.ts";
import { displayCinemaTitle, formatCinemaEpisodeCode, formatCinemaResumeLabel } from "./cinemaSubtitles.ts";
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
  (e: "clear-progress", film: Movie): void;
  (e: "filter-mode", mode: string): void;
  (e: "poster-error", id: number): void;
}>();

function cardLabel(movie: Movie, prefix: string): string {
  const title = displayCinemaTitle(movie);
  const code = movie.kind === "series" ? formatCinemaEpisodeCode(movie.season, movie.episode) : "";
  return code ? `${prefix} ${title} ${code}` : `${prefix} ${title}`;
}
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
          :alt="displayCinemaTitle(featuredFilm) + '海报'"
          loading="lazy"
          decoding="async"
          @error="emit('poster-error', featuredFilm.id)"
        />
        <Film v-else :size="48" />
      </div>
      <div class="cinema-featured-info">
        <span class="cinema-featured-kicker">
          {{ featuredFilm.position > 5 && !featuredFilm.completed ? "继续观看" : "来自你的影视库" }}
        </span>
        <h3>{{ displayCinemaTitle(featuredFilm) }}</h3>
        <p class="cinema-featured-meta">
          {{
            [
              featuredFilm.year || "",
              featuredFilm.kind === "series"
                ? (formatCinemaEpisodeCode(featuredFilm.season, featuredFilm.episode) || "剧集")
                : "电影",
              duration(featuredFilm.durationSeconds || featuredFilm.duration),
            ].filter(Boolean).join(" · ")
          }}
        </p>
        <p v-if="featuredFilm.overview" class="cinema-featured-description">{{ featuredFilm.overview }}</p>
        <div class="cinema-featured-actions">
          <button type="button" class="cinema-featured-play" @click="emit('open-film', featuredFilm, true)">
            <Play :size="18" /> {{ featuredFilm.position > 5 && !featuredFilm.completed ? formatCinemaResumeLabel(featuredFilm) : "开始播放" }}
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
        <div
          v-for="movie in continueShelf"
          :key="movie.id"
          class="cinema-home-card-wrap"
        >
          <button
            type="button"
            class="cinema-home-card"
            :aria-label="cardLabel(movie, '继续观看')"
            @click="emit('open-film', movie, true)"
          >
            <span class="cinema-home-cover">
              <img
                v-if="(movie.posterURL || posterReady(movie)) && !posterFailed[movie.id]"
                :src="posterUrl(movie)"
                :alt="displayCinemaTitle(movie) + '海报'"
                loading="lazy"
                decoding="async"
                @error="emit('poster-error', movie.id)"
              />
              <Film v-else :size="32" />
            </span>
            <strong :title="displayCinemaTitle(movie)">{{ displayCinemaTitle(movie) }}</strong>
            <small>{{ formatCinemaResumeLabel(movie).replace(/^继续播放\s*/, "") || ("已看 " + percent(movie) + "%") }}</small>
            <span v-if="movie.overview" class="cinema-home-overview" :title="movie.overview">{{ movie.overview }}</span>
            <span class="cinema-home-progress"><span :style="{ width: percent(movie) + '%' }"></span></span>
          </button>
          <button
            type="button"
            class="cinema-home-remove"
            title="从「继续观看」移出（清除续播进度）"
            aria-label="从继续观看移出"
            @click="emit('clear-progress', movie)"
          >
            <X :size="12" />
          </button>
        </div>
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
          :aria-label="cardLabel(movie, '查看影片')"
          @click="emit('open-film', movie, false)"
        >
          <span class="cinema-home-cover">
            <img
              v-if="(movie.posterURL || posterReady(movie)) && !posterFailed[movie.id]"
              :src="posterUrl(movie)"
              :alt="displayCinemaTitle(movie) + '海报'"
              loading="lazy"
              decoding="async"
              @error="emit('poster-error', movie.id)"
            />
            <Film v-else :size="32" />
          </span>
          <strong :title="displayCinemaTitle(movie)">{{ displayCinemaTitle(movie) }}</strong>
          <small>
            {{
              movie.kind === "series"
                ? [formatCinemaEpisodeCode(movie.season, movie.episode) || "剧集", movie.year || "", duration(movie.durationSeconds || movie.duration)].filter(Boolean).join(" · ")
                : (movie.year || "影片") + " · " + duration(movie.durationSeconds || movie.duration)
            }}
          </small>
          <span v-if="movie.overview" class="cinema-home-overview" :title="movie.overview">{{ movie.overview }}</span>
        </button>
      </div>
    </div>
  </section>
</template>
