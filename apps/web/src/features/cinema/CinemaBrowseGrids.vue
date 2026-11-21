<script setup lang="ts">
import { inject, ref } from "vue";
import { Clapperboard, Download, Film, Pencil, Play, RotateCcw, Trash2, Tv } from "lucide-vue-next";
import { formatShortDate } from "../../utils/dateTimeFormat.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { duration, percent } from "./useCinemaMetadata.ts";
import { displayCinemaTitle, formatCinemaEpisodeCode } from "./cinemaSubtitles.ts";
import { CINEMA_BROWSE_CTX } from "../../contexts/cinemaContext.ts";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import type { SeriesInfo } from "./cinemaTypes.ts";

const ctx = inject(CINEMA_BROWSE_CTX);
if (!ctx) throw new Error("CinemaBrowseGrids requires CINEMA_BROWSE_CTX");

const {
  view, mode, query, admin, movies, next, loading, pageLoaded, loadError, actionError,
  scanActionError, scanStatusError, scanStatusLoaded, scanStatusLoading, scan,
  choosingTrash, trashIds, deleting, filteredView, emptyTitle, emptyMessage,
  featuredFilm, continueShelf, showRecentShelf, disambiguationMap, matchingSeries,
  seriesSearchLoading, seriesSearchError, seriesList, seriesLoading, seriesError,
  historyFilms, historyLoading, historyError, posterFailed, posterReady, posterUrl,
  seriesPosterUrl, playback, retrySeriesSearch, openSeries, continueSeries, reloadSeries,
  retryLoad, retryStatus, startScan, resetFilters, reloadHistory, clearHistory,
  openFilm, toggleTrashFilm, trashFilm, openRename, markRestart, loadMore, posterError,
} = ctx;

const seriesDirectFallback = ref<Record<number, boolean>>({});
const seriesFailed = ref<Record<number, boolean>>({});
function resolveSeriesSrc(item: SeriesInfo) {
  if (item.posterURL && seriesDirectFallback.value[item.id]) return item.posterURL;
  return seriesPosterUrl(item.id, item.posterURL);
}
function onSeriesPosterError(item: SeriesInfo) {
  if (item.posterURL && !seriesDirectFallback.value[item.id]) {
    seriesDirectFallback.value[item.id] = true;
    return;
  }
  seriesFailed.value[item.id] = true;
}
</script>

<template>
  <section v-if="query.trim()" class="cinema-home-section" aria-label="影视搜索结果">
    <div class="cinema-home-heading">
      <h3>剧集匹配</h3>
      <small v-if="seriesSearchLoading" role="status">正在搜索剧集…</small>
    </div>
    <p v-if="seriesSearchError" class="cinema-alert" role="alert">
      搜索剧集失败：{{ seriesSearchError }}
      <button type="button" class="account-action" @click="retrySeriesSearch()">重试</button>
    </p>
    <div v-if="matchingSeries.length" class="cinema-home-rail" role="group" aria-label="匹配的完整剧集">
      <button
        v-for="item in matchingSeries"
        :key="item.id"
        type="button"
        class="cinema-home-card"
        :aria-label="'查看剧集 ' + item.name"
        @click="openSeries(item)"
      >
        <span class="cinema-home-cover">
          <img v-if="!seriesFailed[item.id] && resolveSeriesSrc(item)" :src="resolveSeriesSrc(item)" :alt="item.name + '海报'" loading="lazy" decoding="async" @error="onSeriesPosterError(item)" />
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
      <button type="button" class="account-action" @click="reloadSeries()">重试</button>
    </span>
    <span v-else-if="!seriesList.length" class="cinema-hint">
      暂无可聚合剧集；放入含剧集编号的视频并扫描后自动聚合。
    </span>
    <span v-else class="cinema-hint">共 {{ seriesList.length }} 部剧集</span>
  </div>

  <div v-if="view === 'series' && seriesList.length" class="cinema-grid isle-subview-pane">
    <article v-for="item in seriesList" :key="item.id" class="cinema-tile">
      <button class="cinema-poster" :aria-label="'查看剧集 ' + item.name" @click="openSeries(item)">
        <img
          v-if="!seriesFailed[item.id] && resolveSeriesSrc(item)"
          :src="resolveSeriesSrc(item)"
          :alt="item.name + '海报'"
          loading="lazy"
          decoding="async"
          class="cinema-poster-image"
          @error="onSeriesPosterError(item)"
        />
        <template v-else><Tv :size="44" /></template>
        <span class="cinema-play"><Play v-if="item.nextFilmId" :size="18" fill="currentColor" /><Tv v-else :size="18" /></span>
        <span class="cinema-label">{{ item.year || "剧集" }}</span>
      </button>
      <div class="cinema-details">
        <strong :title="item.name">{{ item.name }}</strong>
        <small>已看 {{ item.watchedCount }}/{{ item.episodeCount }} 集</small>
        <p v-if="item.overview" class="cinema-card-overview" :title="item.overview">{{ item.overview }}</p>
        <IsleBadge v-if="item.inProgress && item.nextTitle" variant="accent" size="sm">继续：{{ item.nextTitle }}</IsleBadge>
        <IsleBadge v-else-if="item.watchedCount >= item.episodeCount && item.episodeCount" variant="online" size="sm">已看完</IsleBadge>
        <button v-if="item.nextFilmId" type="button" @click="continueSeries(item)" title="继续观看" aria-label="继续观看">
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
      <IsleButton v-if="loadError" variant="tonal" size="sm" :disabled="loading" @click="retryLoad()">重试读取影视库</IsleButton>
      <IsleButton v-if="scanStatusError" variant="tonal" size="sm" :disabled="scanStatusLoading" @click="retryStatus()">重试读取扫描状态</IsleButton>
      <IsleButton v-if="admin && (!loadError || scanActionError || scan.lastError)" variant="tonal" size="sm" :disabled="scan.running && !scanStatusError" @click="startScan()">重新扫描</IsleButton>
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
      <IsleButton variant="tonal" size="sm" @click="resetFilters()">查看全部影片</IsleButton>
    </template>
  </IsleEmpty>

  <div v-if="view === 'films' && mode === 'history'" class="cinema-tools">
    <span v-if="historyLoading" class="cinema-hint" role="status">正在读取历史记录…</span>
    <span v-else-if="historyError" class="cinema-alert" role="alert">
      历史读取失败：{{ historyError }}
      <button type="button" class="account-action" @click="reloadHistory()">重试</button>
    </span>
    <span v-else-if="!historyFilms.length" class="cinema-hint">还没有观看记录；播放过的影片和剧集会按时间出现在这里。</span>
    <span v-else class="cinema-hint">
      共 {{ historyFilms.length }} 条记录（仅当前账号可见）
      <button type="button" class="account-action" @click="clearHistory()">清空历史</button>
    </span>
  </div>

  <div v-if="view === 'films' && mode === 'history'" class="cinema-grid isle-subview-pane">
    <article v-for="movie in historyFilms" :key="movie.id" class="cinema-tile">
      <button
        class="cinema-poster"
        :aria-label="'继续观看 ' + displayCinemaTitle(movie) + (movie.kind === 'series' && formatCinemaEpisodeCode(movie.season, movie.episode) ? ' ' + formatCinemaEpisodeCode(movie.season, movie.episode) : '')"
        @click="openFilm(movie, true)"
      >
        <img
          v-if="(movie.posterURL || posterReady(movie)) && !posterFailed[movie.id]"
          :src="posterUrl(movie)"
          :alt="displayCinemaTitle(movie) + '海报'"
          loading="lazy"
          decoding="async"
          class="cinema-poster-image"
          @error="posterError(movie.id)"
        />
        <template v-else><Tv v-if="movie.kind === 'series'" :size="44" /><Film v-else :size="44" /></template>
        <span class="cinema-play"><Play :size="18" fill="currentColor" /></span>
        <span class="cinema-label">{{ formatShortDate(movie.updatedAt) }}</span>
        <span class="cinema-watchbar" :style="{ width: percent(movie) + '%' }"></span>
      </button>
      <div class="cinema-details">
        <strong :title="displayCinemaTitle(movie)">{{ displayCinemaTitle(movie) }}</strong>
        <small>
          <template v-if="movie.kind === 'series'">{{ formatCinemaEpisodeCode(movie.season, movie.episode) || "剧集" }} · </template>{{ movie.completed ? "已看完" : "看到 " + percent(movie) + "%" }} · {{ duration(movie.durationSeconds || movie.duration) }}
        </small>
        <p v-if="movie.overview" class="cinema-card-overview" :title="movie.overview">{{ movie.overview }}</p>
        <button v-if="movie.position > 5 && !movie.completed" type="button" @click="markRestart(movie)" title="从头播放" aria-label="从头播放">
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
        :aria-label="(choosingTrash ? '选择 ' : '查看影片 ') + displayCinemaTitle(movie) + (movie.kind === 'series' && formatCinemaEpisodeCode(movie.season, movie.episode) ? ' ' + formatCinemaEpisodeCode(movie.season, movie.episode) : '')"
        :aria-pressed="choosingTrash ? trashIds.has(movie.id) : undefined"
        :class="{ 'cinema-poster--selected': choosingTrash && trashIds.has(movie.id) }"
        @click="choosingTrash ? toggleTrashFilm(movie.id) : openFilm(movie)"
      >
        <img
          v-if="(movie.posterURL || posterReady(movie)) && !posterFailed[movie.id]"
          :src="posterUrl(movie)"
          :alt="displayCinemaTitle(movie) + '海报'"
          loading="lazy"
          decoding="async"
          class="cinema-poster-image"
          @error="posterError(movie.id)"
        />
        <template v-else><Tv v-if="movie.kind === 'series'" :size="44" /><Film v-else :size="44" /></template>
        <span class="cinema-play">
          <Download v-if="playback(movie) === 'download-only'" :size="18" />
          <Play v-else :size="18" fill="currentColor" />
        </span>
        <span v-if="disambiguationMap.get(movie.id)" class="cinema-scope-label">{{ disambiguationMap.get(movie.id) }}</span>
        <span class="cinema-label">{{ movie.kind === "series" ? "S" + movie.season + "E" + movie.episode : (movie.year || (movie.isStrm ? "STRM 直链" : "电影")) }}</span>
        <span v-if="choosingTrash" class="cinema-label cinema-label--right">{{ trashIds.has(movie.id) ? "✓" : "○" }}</span>
        <span class="cinema-watchbar" :style="{ width: percent(movie) + '%' }"></span>
      </button>
      <div class="cinema-details">
        <strong :title="displayCinemaTitle(movie)">{{ displayCinemaTitle(movie) }}</strong>
        <small>
          {{ movie.kind === "series" ? (formatCinemaEpisodeCode(movie.season, movie.episode) || "剧集") : "电影" }}<template v-if="movie.isStrm"> · STRM 直链</template> · {{ duration(movie.durationSeconds || movie.duration) }}<template v-if="disambiguationMap.get(movie.id)"> · {{ disambiguationMap.get(movie.id) }}</template><template v-if="movie.completed"> · 已看完</template><template v-else-if="movie.position > 5"> · 已看 {{ percent(movie) }}%</template>
        </small>
        <p v-if="movie.overview" class="cinema-card-overview" :title="movie.overview">{{ movie.overview }}</p>
        <IsleBadge v-if="mode === 'unmatched' && !movie.metadataSource" variant="warning" size="sm">
          {{ movie.scrapeState === "miss" ? "自动未命中 · 待手动匹配" : "待匹配资料" }}
        </IsleBadge>
        <button v-if="admin" type="button" @click="openRename(movie)" title="修改展示名称" aria-label="修改展示名称">
          <Pencil :size="14" />
        </button>
        <button v-if="(admin || movie.canWrite === true) && !choosingTrash" type="button" :disabled="deleting" @click="trashFilm(movie)" title="移入回收站" aria-label="移入回收站">
          <Trash2 :size="14" />
        </button>
      </div>
    </article>
  </div>

  <div v-if="view === 'films' && mode !== 'history'" class="cinema-more">
    <button v-if="next" :disabled="loading" @click="loadMore()">{{ loading ? "正在加载…" : "加载更多作品" }}</button>
    <span v-else-if="movies.length">已展示全部 {{ movies.length }} 部作品</span>
  </div>
</template>

<style scoped>
.cinema-poster--selected {
  outline: 3px solid var(--accent-primary);
}
.cinema-label--right {
  left: auto;
  right: 8px;
}
</style>
