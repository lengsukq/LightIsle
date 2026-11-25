<script setup lang="ts">
import { onMounted, ref, watch } from "vue";
import { BookmarkPlus, Download, FolderHeart, Plus, Search, Subtitles, Trash2 } from "lucide-vue-next";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import type { CinemaCollection, Movie, OnlineSubtitleCandidate } from "./cinemaTypes.ts";

const props = defineProps<{
  film: Movie;
  admin: boolean;
  api: <T = Record<string, unknown>>(url: string, method?: string, body?: object) => Promise<T>;
  apiPath: (path: string) => string;
}>();

const subOpen = ref(false);
const subQuery = ref("");
const subBusy = ref(false);
const subDownloadingUrl = ref("");
const subError = ref("");
const subNotice = ref("");
const subCandidates = ref<OnlineSubtitleCandidate[]>([]);

const colOpen = ref(false);
const collections = ref<CinemaCollection[]>([]);
const colLoading = ref(false);
const colBusy = ref(false);
const colError = ref("");
const colNotice = ref("");
const newColName = ref("");

watch(
  () => props.film.id,
  () => {
    subQuery.value = props.film.title || "";
    subCandidates.value = [];
    subError.value = "";
    subNotice.value = "";
    colError.value = "";
    colNotice.value = "";
  },
  { immediate: true },
);

async function searchSubtitles() {
  if (subBusy.value) return;
  subBusy.value = true;
  subError.value = "";
  subNotice.value = "";
  try {
    const res = await props.api<{ candidates?: OnlineSubtitleCandidate[] }>(
      props.apiPath(`/api/v2/cinema/${props.film.id}/subtitles/search`),
      "POST",
      { query: subQuery.value.trim() || props.film.title },
    );
    subCandidates.value = Array.isArray(res.candidates) ? res.candidates : [];
    if (!subCandidates.value.length) {
      subNotice.value = "未找到匹配的在线字幕，可尝试缩短或改用英文原名搜索。";
    }
  } catch (e) {
    subError.value = "搜索在线字幕失败：" + describeUserFacingError(e);
  } finally {
    subBusy.value = false;
  }
}

async function downloadSubtitle(item: OnlineSubtitleCandidate) {
  if (subDownloadingUrl.value) return;
  subDownloadingUrl.value = item.url;
  subError.value = "";
  subNotice.value = "";
  try {
    const res = await props.api<{ fileName?: string }>(
      props.apiPath(`/api/v2/cinema/${props.film.id}/subtitles/download`),
      "POST",
      { url: item.url, language: item.language, ext: item.ext },
    );
    subNotice.value = `已保存外挂字幕「${res.fileName || item.name}」至影片同目录，播放时自动加载。`;
  } catch (e) {
    subError.value = "下载并保存字幕失败：" + describeUserFacingError(e);
  } finally {
    subDownloadingUrl.value = "";
  }
}

async function loadCollections() {
  if (colLoading.value) return;
  colLoading.value = true;
  colError.value = "";
  try {
    const res = await props.api<{ collections?: CinemaCollection[] }>(
      props.apiPath("/api/v2/cinema-collections"),
    );
    collections.value = Array.isArray(res.collections) ? res.collections : [];
  } catch (e) {
    colError.value = "读取家庭影单失败：" + describeUserFacingError(e);
  } finally {
    colLoading.value = false;
  }
}

async function createCollection() {
  const name = newColName.value.trim();
  if (!name || colBusy.value) return;
  colBusy.value = true;
  colError.value = "";
  colNotice.value = "";
  try {
    const created = await props.api<CinemaCollection>(
      props.apiPath("/api/v2/cinema-collections"),
      "POST",
      { name },
    );
    newColName.value = "";
    await loadCollections();
    if (created?.id) {
      await addToCollection(created);
    }
  } catch (e) {
    colError.value = "创建影单失败：" + describeUserFacingError(e);
  } finally {
    colBusy.value = false;
  }
}

async function addToCollection(col: CinemaCollection) {
  colBusy.value = true;
  colError.value = "";
  colNotice.value = "";
  try {
    await props.api(
      props.apiPath(`/api/v2/cinema-collections/${col.id}/items`),
      "POST",
      { filmId: props.film.id },
    );
    colNotice.value = `已将「${props.film.title}」加入影单「${col.name}」。`;
    await loadCollections();
  } catch (e) {
    colError.value = "加入影单失败：" + describeUserFacingError(e);
  } finally {
    colBusy.value = false;
  }
}

async function deleteCollection(col: CinemaCollection) {
  colBusy.value = true;
  colError.value = "";
  colNotice.value = "";
  try {
    await props.api(props.apiPath(`/api/v2/cinema-collections/${col.id}`), "DELETE");
    colNotice.value = `已删除影单「${col.name}」（原影片文件不受影响）。`;
    await loadCollections();
  } catch (e) {
    colError.value = "删除影单失败：" + describeUserFacingError(e);
  } finally {
    colBusy.value = false;
  }
}

onMounted(() => {
  if (props.admin) void loadCollections();
});
</script>

<template>
  <div v-if="admin" class="cinema-extra-tools">
    <div class="cinema-extra-bar">
      <IsleButton :variant="subOpen ? 'tonal' : 'glass'" size="sm" @click="subOpen = !subOpen">
        <template #icon><Subtitles :size="14" /></template>
        {{ subOpen ? "收起在线字幕" : "在线搜刮字幕" }}
      </IsleButton>
      <IsleButton :variant="colOpen ? 'tonal' : 'glass'" size="sm" @click="colOpen = !colOpen; if (colOpen && !collections.length) loadCollections()">
        <template #icon><FolderHeart :size="14" /></template>
        {{ colOpen ? "收起家庭影单" : `家庭影单 (${collections.length})` }}
      </IsleButton>
    </div>

    <div v-if="subOpen" class="cinema-extra-drawer">
      <form class="cinema-tmdb-form" @submit.prevent="searchSubtitles">
        <input v-model="subQuery" type="search" maxlength="160" placeholder="输入中文或英文片名搜刮字幕" aria-label="在线字幕搜索关键词" :disabled="subBusy" />
        <button type="submit" :disabled="subBusy">
          <Search :size="13" /> {{ subBusy ? "搜索中…" : "搜刮字幕" }}
        </button>
      </form>
      <p v-if="subError" class="cinema-alert" role="alert">{{ subError }}</p>
      <p v-if="subNotice" class="cinema-metadata-source" role="status">{{ subNotice }}</p>
      <div v-if="subCandidates.length" class="cinema-sub-results">
        <div v-for="item in subCandidates" :key="item.id" class="cinema-sub-row">
          <div class="cinema-sub-info">
            <strong>{{ item.name || "未命名字幕" }}</strong>
            <div class="cinema-sub-badges">
              <IsleBadge variant="accent" size="sm">.{{ item.ext }}</IsleBadge>
              <IsleBadge variant="neutral" size="sm">{{ item.language }}</IsleBadge>
            </div>
          </div>
          <IsleButton variant="primary" size="sm" :disabled="!!subDownloadingUrl" @click="downloadSubtitle(item)">
            <template #icon><Download :size="13" /></template>
            {{ subDownloadingUrl === item.url ? "保存中…" : "下载挂载" }}
          </IsleButton>
        </div>
      </div>
    </div>

    <div v-if="colOpen" class="cinema-extra-drawer">
      <form class="cinema-tmdb-form" @submit.prevent="createCollection">
        <input v-model="newColName" maxlength="60" placeholder="新建家庭影单（如：宫崎骏全集 / 给孩子看的动画）" aria-label="新建家庭影单名称" :disabled="colBusy" />
        <button type="submit" :disabled="colBusy || !newColName.trim()">
          <Plus :size="13" /> 新建并加入
        </button>
      </form>
      <p v-if="colError" class="cinema-alert" role="alert">{{ colError }}</p>
      <p v-if="colNotice" class="cinema-metadata-source" role="status">{{ colNotice }}</p>
      <div v-if="collections.length" class="cinema-col-list">
        <div v-for="col in collections" :key="col.id" class="cinema-sub-row">
          <div class="cinema-sub-info">
            <strong>{{ col.name }}</strong>
            <small class="cinema-metadata-source">{{ col.count }} 部影片</small>
          </div>
          <div class="cinema-col-actions">
            <IsleButton variant="glass" size="sm" :disabled="colBusy" @click="addToCollection(col)">
              <template #icon><BookmarkPlus :size="13" /></template>加入此影单
            </IsleButton>
            <IsleButton variant="ghost" size="sm" :disabled="colBusy" title="删除影单" @click="deleteCollection(col)">
              <Trash2 :size="13" />
            </IsleButton>
          </div>
        </div>
      </div>
      <p v-else-if="!colLoading" class="cinema-metadata-source">暂无家庭影单，可在上方创建一个主题影单。</p>
    </div>
  </div>
</template>

<style scoped>
.cinema-extra-tools {
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.cinema-extra-bar {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}
.cinema-extra-drawer {
  padding: 12px 14px;
  border-radius: 14px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.cinema-sub-results,
.cinema-col-list {
  display: grid;
  gap: 6px;
  max-height: 220px;
  overflow-y: auto;
}
.cinema-sub-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 10px;
  padding: 8px 10px;
  border-radius: 10px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-fill);
}
.cinema-sub-info {
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 3px;
}
.cinema-sub-info strong {
  font-size: 12.5px;
  color: var(--text-primary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.cinema-sub-badges,
.cinema-col-actions {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  flex-shrink: 0;
}
</style>
