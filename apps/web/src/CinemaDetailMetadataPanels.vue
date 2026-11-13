<script setup lang="ts">
import { Film, Play, Trash2 } from "lucide-vue-next";
import IsleBadge from "./IsleBadge.vue";
import { duration, metadataSourceName } from "./useCinemaMetadata.ts";
import { formatCinemaResumeLabel } from "./cinemaSubtitles.ts";
import type { BrowserPlayback, DoubanCandidate, Movie, TMDBCandidate } from "./cinemaTypes.ts";

defineProps<{
  selected: Movie;
  admin: boolean;
  canTrashSelected: boolean;
  deleting: boolean;
  leavingPlayer: boolean;
  posterFailed: Record<number, boolean>;
  posterReady: (movie: Movie) => boolean;
  posterUrl: (movie: Movie) => string;
  playbackMode: BrowserPlayback;
  playbackLabelText: string;
  sameDirectoryFilms: Movie[];
  playlistDirLabel: string;
  scrapeMessage: string;
  scraping: boolean;
  doubanQuery: string;
  doubanMatches: DoubanCandidate[];
  doubanBusy: boolean;
  doubanError: string;
  tmdbToken: string;
  tmdbQuery: string;
  tmdbMatches: TMDBCandidate[];
  tmdbBusy: boolean;
  tmdbError: string;
  candidatePosterFailed: Record<number, boolean>;
}>();

const emit = defineEmits<{
  (e: "play-selected"): void;
  (e: "poster-error", id: number): void;
  (e: "candidate-poster-error", id: number): void;
  (e: "switch-playlist-film", film: Movie): void;
  (e: "update:doubanQuery", value: string): void;
  (e: "update:tmdbToken", value: string): void;
  (e: "update:tmdbQuery", value: string): void;
  (e: "search-douban"): void;
  (e: "match-douban", candidate: DoubanCandidate): void;
  (e: "search-tmdb"): void;
  (e: "match-tmdb", candidate: TMDBCandidate): void;
  (e: "trash-selected"): void;
  (e: "download-selected"): void;
  (e: "toggle-watched"): void;
  (e: "clear-progress"): void;
  (e: "restart-from-beginning"): void;
  (e: "import-local-nfo"): void;
  (e: "open-mount-guide"): void;
}>();
</script>

<template>
  <div class="cinema-overview">
    <div class="cinema-overview-poster">
      <img
        v-if="(selected.posterURL || posterReady(selected)) && !posterFailed[selected.id]"
        :src="posterUrl(selected)"
        :alt="selected.title + '海报'"
        decoding="async"
        @error="emit('poster-error', selected.id)"
      />
      <Film v-else :size="56" />
    </div>
    <div class="cinema-overview-text">
      <h3>{{ selected.title }}</h3>
      <p v-if="selected.overview" class="cinema-synopsis">{{ selected.overview }}</p>
      <p v-else class="cinema-metadata-source">暂无影片简介，仍可播放或保存原文件。</p>
      <p v-if="selected.position > 5 && !selected.completed" class="resume-hint">
        上次播放到 {{ duration(selected.position) }}
      </p>
      <button
        type="button"
        class="dl-btn"
        :disabled="selected.probeStatus === 'pending' && playbackMode === 'download-only'"
        @click="emit('play-selected')"
      >
        <Play :size="16" /> {{ selected.position > 5 && !selected.completed ? formatCinemaResumeLabel(selected) : "开始播放" }}
      </button>
      <p v-if="playbackMode === 'download-only'" class="cinema-metadata-source">
        {{ playbackLabelText }}：可尝试实时转码、下载原片用 IINA / Infuse / VLC 打开，或
        <button type="button" class="account-action" @click="emit('open-mount-guide')">通过 WebDAV 直连外部播放器</button>。
      </p>
    </div>
  </div>

  <div v-if="sameDirectoryFilms.length > 1" class="cinema-overview-playlist" role="region" aria-label="同目录播放列表">
    <div class="cinema-overview-playlist-head">
      <strong>同目录播放列表（{{ sameDirectoryFilms.length }}）</strong>
      <small>{{ playlistDirLabel }}</small>
    </div>
    <div class="cinema-overview-playlist-items">
      <button
        v-for="item in sameDirectoryFilms"
        :key="item.id"
        type="button"
        class="cinema-episode"
        :class="{ active: item.id === selected.id }"
        :disabled="leavingPlayer"
        @click="emit('switch-playlist-film', item)"
      >
        {{ item.title }}
        <IsleBadge v-if="item.id === selected.id" variant="accent" size="sm">当前选中</IsleBadge>
      </button>
    </div>
  </div>

  <p v-if="selected.titleSource || selected.yearSource || selected.metadataSource" class="cinema-metadata-source">
    片名：{{ metadataSourceName(selected.titleSource) }} · 年份：{{ metadataSourceName(selected.yearSource) }} ·
    简介/评分：{{ selected.metadataSource ? metadataSourceName(selected.metadataSource) : "无已确认来源" }}
    <span v-if="selected.rating"> · 评分 {{ selected.rating.toFixed(1) }} / 10</span>
  </p>
  <p v-if="scrapeMessage" class="cinema-alert" role="status">{{ scrapeMessage }}</p>

  <details v-if="admin" class="cinema-tmdb-panel">
    <summary>豆瓣搜索建议 · 备用匹配（实验性）</summary>
    <p>仅按需查询片名与年份建议（非官方入口，不含海报与评分）。</p>
    <form class="cinema-tmdb-form" @submit.prevent="emit('search-douban')">
      <input
        :value="doubanQuery"
        type="search"
        maxlength="60"
        aria-label="豆瓣影片搜索关键词"
        placeholder="输入电影或剧集名称"
        :disabled="doubanBusy || scraping || tmdbBusy"
        @input="emit('update:doubanQuery', ($event.target as HTMLInputElement).value)"
      />
      <button type="submit" :disabled="doubanBusy || scraping || tmdbBusy">
        {{ doubanBusy ? "正在查询…" : "搜索豆瓣候选" }}
      </button>
    </form>
    <p v-if="doubanError" class="cinema-alert" role="alert">{{ doubanError }}</p>
    <div v-for="candidate in doubanMatches" :key="candidate.id" class="cinema-tmdb-match">
      <div class="cinema-tmdb-match-text">
        <strong>{{ candidate.title }} {{ candidate.year ? "(" + candidate.year + ")" : "" }}</strong>
        <small>网页搜索建议 · {{ candidate.kind === "tv" ? "剧集" : "影片" }} · 不含评分和海报</small>
      </div>
      <button type="button" :disabled="doubanBusy || tmdbBusy || scraping" @click="emit('match-douban', candidate)">
        确认匹配
      </button>
    </div>
  </details>

  <details v-if="admin" class="cinema-tmdb-panel">
    <summary>TMDB 在线匹配</summary>
    <p>优先使用 Mac 端已配置的 TMDB Token，也可临时填入令牌；选中候选后才保存资料。</p>
    <form class="cinema-tmdb-form" @submit.prevent="emit('search-tmdb')">
      <input
        :value="tmdbToken"
        type="password"
        autocomplete="off"
        spellcheck="false"
        placeholder="TMDB API Read Access Token（可选，留空使用 Mac 已配置 Token）"
        aria-label="TMDB API Read Access Token"
        :disabled="tmdbBusy || scraping"
        @input="emit('update:tmdbToken', ($event.target as HTMLInputElement).value)"
      />
      <input
        :value="tmdbQuery"
        type="search"
        maxlength="120"
        placeholder="影视名称"
        aria-label="TMDB 搜索关键词"
        :disabled="tmdbBusy || scraping"
        @input="emit('update:tmdbQuery', ($event.target as HTMLInputElement).value)"
      />
      <button type="submit" :disabled="tmdbBusy || scraping">
        {{ tmdbBusy ? "查询中…" : scraping ? "正在导入…" : "搜索 TMDB" }}
      </button>
    </form>
    <p v-if="tmdbError" class="cinema-alert" role="alert">{{ tmdbError }}</p>
    <div v-for="candidate in tmdbMatches" :key="candidate.id" class="cinema-tmdb-match">
      <img
        v-if="candidate.posterURL && !candidatePosterFailed[candidate.id]"
        :src="candidate.posterURL"
        :alt="candidate.title + '海报'"
        loading="lazy"
        decoding="async"
        @error="emit('candidate-poster-error', candidate.id)"
      />
      <div v-else class="cinema-tmdb-poster-placeholder" aria-hidden="true"><Film :size="22" /></div>
      <div class="cinema-tmdb-match-text">
        <strong>{{ candidate.title }} {{ candidate.year ? "(" + candidate.year + ")" : "" }}</strong>
        <small>评分 {{ candidate.rating.toFixed(1) }} / 10</small>
        <p v-if="candidate.overview">{{ candidate.overview }}</p>
      </div>
      <button type="button" :disabled="tmdbBusy || scraping" @click="emit('match-tmdb', candidate)">选择匹配</button>
    </div>
    <p class="cinema-metadata-source">
      This product uses the TMDB API but is not endorsed or certified by TMDB.
      <a href="https://www.themoviedb.org/" rel="noopener noreferrer" target="_blank">TMDB</a>
    </p>
  </details>

  <footer>
    <button
      v-if="canTrashSelected"
      type="button"
      class="dl-btn"
      :disabled="deleting"
      @click="emit('trash-selected')"
    >
      <Trash2 :size="14" /> 移入回收站
    </button>
    <span v-if="selected.position > 5 && !selected.completed" class="resume-hint">
      上次播至 {{ duration(selected.position) }}
    </span>
    <button class="dl-btn" @click="emit('download-selected')">下载原片文件</button>
    <button class="dl-btn" @click="emit('toggle-watched')">{{ selected.completed ? "标记未看" : "标记已看" }}</button>
    <button v-if="selected.position > 5 && !selected.completed" class="dl-btn" @click="emit('clear-progress')">
      移出继续观看
    </button>
    <button v-if="selected.position > 5 && !selected.completed" class="dl-btn" @click="emit('restart-from-beginning')">
      从头播放
    </button>
    <button v-if="admin" class="dl-btn" :disabled="scraping || tmdbBusy" @click="emit('import-local-nfo')">
      {{ scraping ? "读取中…" : tmdbBusy ? "正在处理资料…" : "导入本地 NFO 资料" }}
    </button>
  </footer>
</template>
