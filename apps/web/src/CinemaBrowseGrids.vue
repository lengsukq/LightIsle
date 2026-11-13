<script setup lang="ts">
import { Clapperboard, Download, Film, Pencil, Play, RotateCcw, Trash2, Tv } from "lucide-vue-next";
import { formatShortDate } from "./dateTimeFormat.ts";
import { describeUserFacingError } from "./userFacingError.ts";
import { duration, percent } from "./useCinemaMetadata.ts";
import IsleBadge from "./IsleBadge.vue";
import IsleButton from "./IsleButton.vue";
import IsleEmpty from "./IsleEmpty.vue";
import type { BrowserPlayback, Movie, Scan, SeriesInfo } from "./cinemaTypes.ts";

defineProps<{
  view: "films" | "series";
  mode: string;
  query: string;
  admin: boolean;
  movies: Movie[];
  next: number;
  loading: boolean;
  pageLoaded: boolean;
  loadError: string;
  actionError: string;
  scanActionError: string;
  scanStatusError: string;
  scanStatusLoaded: boolean;
  scanStatusLoading: boolean;
  scan: Scan;
  choosingTrash: boolean;
  trashIds: Set<number>;
  deleting: boolean;
  filteredView: boolean;
  emptyTitle: string;
  emptyMessage: string;
  featuredFilm: Movie | null;
  continueShelf: Movie[];
  showRecentShelf: boolean;
  disambiguationMap: ReadonlyMap<number, string>;
  matchingSeries: SeriesInfo[];
  seriesSearchLoading: boolean;
  seriesSearchError: string;
  seriesList: SeriesInfo[];
  seriesLoading: boolean;
  seriesError: string;
  historyFilms: Movie[];
  historyLoading: boolean;
  historyError: string;
  posterFailed: Record<number, boolean>;
  posterReady: (movie: Movie) => boolean;
  posterUrl: (movie: Movie) => string;
  playback: (movie: Movie) => BrowserPlayback;
}>();

const emit = defineEmits<{
  (e: "retry-series-search"): void;
  (e: "open-series", item: SeriesInfo): void;
  (e: "continue-series", item: SeriesInfo): void;
  (e: "reload-series"): void;
  (e: "retry-load"): void;
  (e: "retry-status"): void;
  (e: "start-scan"): void;
  (e: "reset-filters"): void;
  (e: "reload-history"): void;
  (e: "clear-history"): void;
  (e: "open-film", film: Movie, autoStart?: boolean): void;
  (e: "toggle-trash-film", id: number): void;
  (e: "trash-film", film: Movie): void;
  (e: "open-rename", film: Movie): void;
  (e: "mark-restart", film: Movie): void;
  (e: "load-more"): void;
  (e: "poster-error", id: number): void;
}>();
</script>

<template>
  <section v-if="query.trim()" class="cinema-home-section" aria-label="影视搜索结果">
    <div class="cinema-home-heading">
      <h3>剧集匹配</h3>
      <small v-if="seriesSearchLoading" role="status">正在搜索剧集…</small>
    </div>
    <p v-if="seriesSearchError" class="cinema-alert" role="alert">
      搜索剧集失败：{{ seriesSearchError }}
      <button type="button" class="account-action" @click="emit('retry-series-search')">重试</button>
    </p>
    <div v-if="matchingSeries.length" class="cinema-home-rail" role="group" aria-label="匹配的完整剧集">
      <button
        v-for="item in matchingSeries"
        :key="item.id"
        type="button"
        class="cinema-home-card"
        :aria-label="'查看剧集 ' + item.name"
        @click="emit('open-series', item)"
      >
        <span class="cinema-home-cover">
          <img v-if="item.posterURL" :src="item.posterURL" :alt="item.name + '海报'" loading="lazy" decoding="async" />
          <Tv v-else :size="32" />
        </span>
        <strong :title="item.name">{{ item.name }}</strong>
        <small>{{ item.episodeCount }} 集 · {{ item.year || "年份未知" }}</small>
      </button>
    </div>
    <p v-else-if="!seriesSearchLoading && !seriesSearchError" class="cinema-hint">
      没有匹配的完整剧集，可继续查看下方影片和单集。
    </p>
    <div class="cinema-home-heading"><h3>影片与单集匹配</h3></div>
  </section>

  <div v-if="view === 'series'" class="cinema-tools">
    <span v-if="seriesLoading" class="cinema-hint" role="status">正在读取剧集库…</span>
    <span v-else-if="seriesError" class="cinema-alert" role="alert">
      剧集库读取失败：{{ seriesError }}
      <button type="button" class="account-action" @click="emit('reload-series')">重试</button>
    </span>
    <span v-else-if="!seriesList.length" class="cinema-hint">
      暂无可聚合剧集；放入含剧集编号的视频并扫描后自动聚合。
    </span>
    <span v-else class="cinema-hint">共 {{ seriesList.length }} 部剧集</span>
  </div>

  <div v-if="view === 'series' && seriesList.length" class="cinema-grid isle-subview-pane">
    <article v-for="item in seriesList" :key="item.id" class="cinema-tile">
      <button class="cinema-poster" :aria-label="'查看剧集 ' + item.name" @click="emit('open-series', item)">
        <img
          v-if="item.posterURL"
          :src="item.posterURL"
          :alt="item.name + '海报'"
          loading="lazy"
          decoding="async"
          class="cinema-poster-image"
        />
        <template v-else><Tv :size="44" /></template>
        <span class="cinema-play"><Play v-if="item.nextFilmId" :size="18" fill="currentColor" /><Tv v-else :size="18" /></span>
        <span class="cinema-label">{{ item.year || "剧集" }}</span>
      </button>
      <div class="cinema-details">
        <strong :title="item.name">{{ item.name }}</strong>
        <small>已看 {{ item.watchedCount }}/{{ item.episodeCount }} 集</small>
        <IsleBadge v-if="item.inProgress && item.nextTitle" variant="accent" size="sm">继续：{{ item.nextTitle }}</IsleBadge>
        <IsleBadge v-else-if="item.watchedCount >= item.episodeCount && item.episodeCount" variant="online" size="sm">已看完</IsleBadge>
        <button v-if="item.nextFilmId" type="button" @click="emit('continue-series', item)" title="继续观看" aria-label="继续观看">
          <Play :size="14" />
        </button>
      </div>
    </article>
  </div>

  <IsleEmpty
    v-if="view === 'films' && mode !== 'history' && !movies.length && (loadError || actionError || scanActionError || scanStatusError || (scanStatusLoaded && scan.lastError))"
    :icon="Clapperboard"
    :icon-size="44"
    :title="loadError ? '暂时无法读取影视库' : actionError ? '操作未完成' : scanActionError ? '扫描无法启动' : scanStatusError ? '无法确认扫描状态' : '上次扫描未完成'"
    :description="
      loadError
        ? '加载影视库失败：' + loadError
        : actionError || scanActionError || (scanStatusError ? '扫描状态暂不可用：' + scanStatusError : '上次扫描未完成：' + describeUserFacingError(scan.lastError))
    "
    role="alert"
  >
    <template #action>
      <IsleButton v-if="loadError" variant="tonal" size="sm" :disabled="loading" @click="emit('retry-load')">重试读取影视库</IsleButton>
      <IsleButton v-if="scanStatusError" variant="tonal" size="sm" :disabled="scanStatusLoading" @click="emit('retry-status')">重试读取扫描状态</IsleButton>
      <IsleButton v-if="admin && (!loadError || scanActionError || scan.lastError)" variant="tonal" size="sm" :disabled="scan.running && !scanStatusError" @click="emit('start-scan')">重新扫描</IsleButton>
    </template>
  </IsleEmpty>

  <IsleEmpty
    v-else-if="view === 'films' && mode !== 'history' && !movies.length && (loading || !pageLoaded || (!scanStatusLoaded && !scanStatusError) || (scan.running && !scanStatusError))"
    :icon="Clapperboard"
    :icon-size="44"
    :title="scan.running && !scanStatusError ? '正在扫描影视库…' : !scanStatusLoaded && !scanStatusError ? '正在确认扫描状态…' : '正在读取影视库…'"
    description="正在检查 Mac 授权的共享目录。"
  />

  <IsleEmpty
    v-else-if="view === 'films' && mode !== 'history' && !movies.length && !(query.trim() && matchingSeries.length)"
    :icon="Clapperboard"
    :icon-size="44"
    :title="emptyTitle"
    :description="emptyMessage"
  >
    <template v-if="filteredView" #action>
      <IsleButton variant="tonal" size="sm" @click="emit('reset-filters')">查看全部影片</IsleButton>
    </template>
  </IsleEmpty>

  <div v-if="view === 'films' && mode === 'history'" class="cinema-tools">
    <span v-if="historyLoading" class="cinema-hint" role="status">正在读取历史记录…</span>
    <span v-else-if="historyError" class="cinema-alert" role="alert">
      历史读取失败：{{ historyError }}
      <button type="button" class="account-action" @click="emit('reload-history')">重试</button>
    </span>
    <span v-else-if="!historyFilms.length" class="cinema-hint">还没有观看记录；播放过的影片和剧集会按时间出现在这里。</span>
    <span v-else class="cinema-hint">
      共 {{ historyFilms.length }} 条记录（仅当前账号可见）
      <button type="button" class="account-action" @click="emit('clear-history')">清空历史</button>
    </span>
  </div>

  <div v-if="view === 'films' && mode === 'history'" class="cinema-grid isle-subview-pane">
    <article v-for="movie in historyFilms" :key="movie.id" class="cinema-tile">
      <button class="cinema-poster" @click="emit('open-film', movie, true)">
        <img
          v-if="(movie.posterURL || posterReady(movie)) && !posterFailed[movie.id]"
          :src="posterUrl(movie)"
          :alt="movie.title + '海报'"
          loading="lazy"
          decoding="async"
          class="cinema-poster-image"
          @error="emit('poster-error', movie.id)"
        />
        <template v-else><Tv v-if="movie.kind === 'series'" :size="44" /><Film v-else :size="44" /></template>
        <span class="cinema-play"><Play :size="18" fill="currentColor" /></span>
        <span class="cinema-label">{{ formatShortDate(movie.updatedAt) }}</span>
        <span class="cinema-watchbar" :style="{ width: percent(movie) + '%' }"></span>
      </button>
      <div class="cinema-details">
        <strong :title="movie.title">{{ movie.title }}</strong>
        <small>{{ movie.completed ? "已看完" : "看到 " + percent(movie) + "%" }} · {{ duration(movie.durationSeconds || movie.duration) }}</small>
        <button v-if="movie.position > 5 && !movie.completed" type="button" @click="emit('mark-restart', movie)" title="从头播放" aria-label="从头播放">
          <RotateCcw :size="14" />
        </button>
      </div>
    </article>
  </div>

  <div
    v-if="view === 'films' && mode === 'all' && !query.trim() && !choosingTrash && movies.length && (featuredFilm || continueShelf.length || showRecentShelf)"
    class="cinema-home-heading cinema-all-heading"
  >
    <h3>全部影片</h3>
    <small class="cinema-hint-inline">共 {{ next ? movies.length + "+" : movies.length }} 部</small>
  </div>

  <div v-if="view === 'films' && mode !== 'history'" class="cinema-grid isle-subview-pane">
    <article v-for="movie in movies" :key="movie.id" class="cinema-tile">
      <button
        class="cinema-poster"
        :aria-label="choosingTrash ? '选择 ' + movie.title : '查看影片 ' + movie.title"
        :aria-pressed="choosingTrash ? trashIds.has(movie.id) : undefined"
        :style="choosingTrash && trashIds.has(movie.id) ? { outline: '3px solid var(--accent-primary)' } : undefined"
        @click="choosingTrash ? emit('toggle-trash-film', movie.id) : emit('open-film', movie)"
      >
        <img
          v-if="(movie.posterURL || posterReady(movie)) && !posterFailed[movie.id]"
          :src="posterUrl(movie)"
          :alt="movie.title + '海报'"
          loading="lazy"
          decoding="async"
          class="cinema-poster-image"
          @error="emit('poster-error', movie.id)"
        />
        <template v-else><Tv v-if="movie.kind === 'series'" :size="44" /><Film v-else :size="44" /></template>
        <span class="cinema-play">
          <Download v-if="playback(movie) === 'download-only'" :size="18" />
          <Play v-else :size="18" fill="currentColor" />
        </span>
        <span v-if="disambiguationMap.get(movie.id)" class="cinema-scope-label">{{ disambiguationMap.get(movie.id) }}</span>
        <span class="cinema-label">{{ movie.kind === "series" ? "S" + movie.season + "E" + movie.episode : (movie.year || (movie.isStrm ? "STRM 直链" : "电影")) }}</span>
        <span v-if="choosingTrash" class="cinema-label" style="left:auto;right:8px">{{ trashIds.has(movie.id) ? "✓" : "○" }}</span>
        <span class="cinema-watchbar" :style="{ width: percent(movie) + '%' }"></span>
      </button>
      <div class="cinema-details">
        <strong :title="movie.title">{{ movie.title }}</strong>
        <small>
          {{ movie.kind === "series" ? "剧集" : "电影" }}<template v-if="movie.isStrm"> · STRM 直链</template> · {{ duration(movie.durationSeconds || movie.duration) }}<template v-if="disambiguationMap.get(movie.id)"> · {{ disambiguationMap.get(movie.id) }}</template><template v-if="movie.completed"> · 已看完</template><template v-else-if="movie.position > 5"> · 已看 {{ percent(movie) }}%</template>
        </small>
        <IsleBadge v-if="mode === 'unmatched' && !movie.metadataSource" variant="warning" size="sm">
          {{ movie.scrapeState === "miss" ? "自动未命中 · 待手动匹配" : "待匹配资料" }}
        </IsleBadge>
        <button v-if="admin" type="button" @click="emit('open-rename', movie)" title="修改展示名称" aria-label="修改展示名称">
          <Pencil :size="14" />
        </button>
        <button v-if="(admin || movie.canWrite === true) && !choosingTrash" type="button" :disabled="deleting" @click="emit('trash-film', movie)" title="移入回收站" aria-label="移入回收站">
          <Trash2 :size="14" />
        </button>
      </div>
    </article>
  </div>

  <div v-if="view === 'films' && mode !== 'history'" class="cinema-more">
    <button v-if="next" :disabled="loading" @click="emit('load-more')">{{ loading ? "正在加载…" : "加载更多作品" }}</button>
    <span v-else-if="movies.length">已展示全部 {{ movies.length }} 部作品</span>
  </div>
</template>
