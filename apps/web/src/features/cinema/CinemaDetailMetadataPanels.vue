<script setup lang="ts">
import { inject, ref } from "vue";
import { Download, Film, FileCode2, Play, RotateCcw, Trash2, Wand2, X } from "lucide-vue-next";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleHelpButton from "../../components/ui/IsleHelpButton.vue";
import IsleActionMenu from "../../components/ui/IsleActionMenu.vue";
import { duration, metadataSourceName } from "./useCinemaMetadata.ts";
import { formatCinemaResumeLabel } from "./cinemaSubtitles.ts";
import { resolveTmdbCandidatePosterUrl } from "./cinemaCatalogDisplay.ts";
import { CINEMA_DETAIL_CTX } from "../../contexts/cinemaContext.ts";
import type { TMDBCandidate } from "./cinemaTypes.ts";

const ctx = inject(CINEMA_DETAIL_CTX);
if (!ctx) throw new Error("CinemaDetailMetadataPanels requires CINEMA_DETAIL_CTX");

const {
  selected, admin, canTrashSelected, deleting, leavingPlayer, posterFailed, posterReady,
  posterUrl, mediaPath, playbackMode, playbackLabelText, sameDirectoryFilms, playlistDirLabel,
  scrapeMessage, scraping, doubanQuery, doubanMatches, doubanBusy, doubanError,
  tmdbToken, tmdbQuery, tmdbMatches, tmdbBusy, tmdbError, candidatePosterFailed,
  playSelected, posterError, candidatePosterError, switchPlaylistFilm,
  searchDouban, matchDouban, searchTmdb, matchTmdb, trashSelected, downloadSelected,
  toggleWatched, clearProgress, restartFromBeginning, importLocalNfo, openMountGuide,
} = ctx;

const matchPanelOpen = ref<"none" | "tmdb" | "douban">("none");
const candidateDirectFallback = ref<Record<number, boolean>>({});
function candidateSrc(c: TMDBCandidate) {
  return resolveTmdbCandidatePosterUrl(c.posterURL, mediaPath, Boolean(candidateDirectFallback.value[c.id]));
}
function onCandidateError(c: TMDBCandidate) {
  if (c.posterURL && !candidateDirectFallback.value[c.id]) {
    candidateDirectFallback.value[c.id] = true;
    return;
  }
  candidatePosterError(c.id);
}
</script>

<template>
  <template v-if="selected">
    <div class="cinema-overview">
      <div class="cinema-overview-poster">
        <img
          v-if="(selected.posterURL || posterReady(selected)) && !posterFailed[selected.id]"
          :src="posterUrl(selected)"
          :alt="selected.title + '海报'"
          decoding="async"
          @error="posterError(selected.id)"
        />
        <Film v-else :size="56" />
      </div>
      <div class="cinema-overview-text">
        <h3>{{ selected.title }}</h3>
        <p v-if="selected.overview" class="cinema-synopsis">{{ selected.overview }}</p>
        <p v-else class="cinema-metadata-source">暂无影片简介。</p>
        <p v-if="selected.position > 5 && !selected.completed" class="resume-hint">
          上次播放到 {{ duration(selected.position) }}
        </p>
        <button
          type="button"
          class="dl-btn"
          :disabled="selected.probeStatus === 'pending' && playbackMode === 'download-only'"
          @click="playSelected()"
        >
          <Play :size="16" /> {{ selected.position > 5 && !selected.completed ? formatCinemaResumeLabel(selected) : "开始播放" }}
        </button>
        <p v-if="playbackMode === 'download-only'" class="cinema-metadata-source">
          {{ playbackLabelText }}：可尝试实时转码、下载原片，或
          <button type="button" class="account-action" @click="openMountGuide()">通过 WebDAV 连接外部播放器</button>。
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
          @click="switchPlaylistFilm(item)"
        >
          {{ item.title }}
          <IsleBadge v-if="item.id === selected.id" variant="accent" size="sm">当前选中</IsleBadge>
        </button>
      </div>
    </div>

    <p v-if="selected.titleSource || selected.yearSource || selected.metadataSource" class="cinema-metadata-source">
      片名：{{ metadataSourceName(selected.titleSource) }} · 年份：{{ metadataSourceName(selected.yearSource) }} ·
      资料：{{ selected.metadataSource ? metadataSourceName(selected.metadataSource) : "未关联" }}
      <span v-if="selected.rating"> · 评分 {{ selected.rating.toFixed(1) }} / 10</span>
    </p>
    <p v-if="scrapeMessage" class="cinema-alert" role="status">{{ scrapeMessage }}</p>

    <div v-if="admin && matchPanelOpen !== 'none'" class="cinema-match-drawer">
      <div class="cinema-match-drawer-head">
        <div class="cinema-match-tabs">
          <IsleButton :variant="matchPanelOpen === 'tmdb' ? 'tonal' : 'ghost'" size="sm" @click="matchPanelOpen = 'tmdb'">
            TMDB 匹配
          </IsleButton>
          <IsleButton :variant="matchPanelOpen === 'douban' ? 'tonal' : 'ghost'" size="sm" @click="matchPanelOpen = 'douban'">
            豆瓣候选
          </IsleButton>
          <IsleHelpButton
            title="影片资料匹配说明"
            :items="[
              { title: 'TMDB 在线匹配', body: '默认复用 Mac 端已配置的 TMDB Token，支持海报、简介与评分补全；仅在你点击选择后保存。' },
              { title: '豆瓣候选建议', body: '用于快速核对中文片名与年份（实验性，不含海报与评分）。' },
            ]"
          />
        </div>
        <IsleButton variant="ghost" size="sm" @click="matchPanelOpen = 'none'">收起</IsleButton>
      </div>

      <template v-if="matchPanelOpen === 'tmdb'">
        <form class="cinema-tmdb-form" @submit.prevent="searchTmdb()">
          <input
            v-model="tmdbToken"
            type="password"
            autocomplete="off"
            spellcheck="false"
            placeholder="TMDB Token（留空复用 Mac 已配置凭据）"
            aria-label="TMDB API Read Access Token"
            :disabled="tmdbBusy || scraping"
          />
          <input
            v-model="tmdbQuery"
            type="search"
            maxlength="120"
            placeholder="影视名称"
            aria-label="TMDB 搜索关键词"
            :disabled="tmdbBusy || scraping"
          />
          <button type="submit" :disabled="tmdbBusy || scraping">
            {{ tmdbBusy ? "查询中…" : scraping ? "正在导入…" : "搜索 TMDB" }}
          </button>
        </form>
        <p v-if="tmdbError" class="cinema-alert" role="alert">{{ tmdbError }}</p>
        <div v-for="candidate in tmdbMatches" :key="candidate.id" class="cinema-tmdb-match">
          <img
            v-if="candidate.posterURL && !candidatePosterFailed[candidate.id]"
            :src="candidateSrc(candidate)"
            :alt="candidate.title + '海报'"
            loading="lazy"
            decoding="async"
            @error="onCandidateError(candidate)"
          />
          <div v-else class="cinema-tmdb-poster-placeholder" aria-hidden="true"><Film :size="22" /></div>
          <div class="cinema-tmdb-match-text">
            <strong>{{ candidate.title }} {{ candidate.year ? "(" + candidate.year + ")" : "" }}</strong>
            <small>评分 {{ candidate.rating.toFixed(1) }} / 10</small>
            <p v-if="candidate.overview">{{ candidate.overview }}</p>
          </div>
          <button type="button" :disabled="tmdbBusy || scraping" @click="matchTmdb(candidate)">选择匹配</button>
        </div>
        <p class="cinema-metadata-source">
          This product uses the TMDB API but is not endorsed or certified by TMDB.
          <a href="https://www.themoviedb.org/" rel="noopener noreferrer" target="_blank">TMDB</a>
        </p>
      </template>

      <template v-else>
        <form class="cinema-tmdb-form" @submit.prevent="searchDouban()">
          <input
            v-model="doubanQuery"
            type="search"
            maxlength="60"
            aria-label="豆瓣影片搜索关键词"
            placeholder="输入电影或剧集名称"
            :disabled="doubanBusy || scraping || tmdbBusy"
          />
          <button type="submit" :disabled="doubanBusy || scraping || tmdbBusy">
            {{ doubanBusy ? "正在查询…" : "搜索豆瓣候选" }}
          </button>
        </form>
        <p v-if="doubanError" class="cinema-alert" role="alert">{{ doubanError }}</p>
        <div v-for="candidate in doubanMatches" :key="candidate.id" class="cinema-tmdb-match">
          <div class="cinema-tmdb-match-text">
            <strong>{{ candidate.title }} {{ candidate.year ? "(" + candidate.year + ")" : "" }}</strong>
            <small>{{ candidate.kind === "tv" ? "剧集" : "影片" }}</small>
          </div>
          <button type="button" :disabled="doubanBusy || tmdbBusy || scraping" @click="matchDouban(candidate)">
            确认匹配
          </button>
        </div>
      </template>
    </div>

    <footer class="cinema-detail-footer">
      <div class="cinema-detail-footer-left">
        <IsleButton variant="glass" size="sm" @click="downloadSelected()">
          <template #icon><Download :size="14" /></template>下载原片
        </IsleButton>
        <IsleButton variant="glass" size="sm" @click="toggleWatched()">
          {{ selected.completed ? "标记未看" : "标记已看" }}
        </IsleButton>
        <IsleButton v-if="admin" variant="tonal" size="sm" @click="matchPanelOpen = matchPanelOpen === 'none' ? 'tmdb' : 'none'">
          <template #icon><Wand2 :size="14" /></template>{{ matchPanelOpen === "none" ? "匹配海报资料" : "收起匹配" }}
        </IsleButton>
      </div>

      <div class="cinema-detail-footer-right">
        <IsleActionMenu
          v-if="canTrashSelected || admin || (selected.position > 5 && !selected.completed)"
          aria-label="更多影片操作"
        >
          <button v-if="selected.position > 5 && !selected.completed" type="button" role="menuitem" @click="restartFromBeginning()">
            <RotateCcw :size="14" /> 从头播放
          </button>
          <button v-if="selected.position > 5 && !selected.completed" type="button" role="menuitem" @click="clearProgress()">
            <X :size="14" /> 移出继续观看
          </button>
          <button v-if="admin" type="button" role="menuitem" :disabled="scraping || tmdbBusy" @click="importLocalNfo()">
            <FileCode2 :size="14" /> {{ scraping ? "读取中…" : "导入本地 NFO 资料" }}
          </button>
          <button v-if="canTrashSelected" type="button" role="menuitem" class="danger" :disabled="deleting" @click="trashSelected()">
            <Trash2 :size="14" /> 移入回收站
          </button>
        </IsleActionMenu>
      </div>
    </footer>
  </template>
</template>

<style scoped>
.cinema-match-drawer {
  padding: 12px 14px;
  border-radius: 14px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.cinema-match-drawer-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  flex-wrap: wrap;
}
.cinema-match-tabs {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
}
.cinema-detail-footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  flex-wrap: wrap;
  padding-top: 8px;
  border-top: 1px solid var(--fluid-divider, var(--fluid-card-border));
}
.cinema-detail-footer-left,
.cinema-detail-footer-right {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}
</style>
