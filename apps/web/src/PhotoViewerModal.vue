<script setup lang="ts">
import { computed, nextTick, ref, watch } from "vue";
import {
  ChevronDown, ChevronLeft, ChevronRight, Eye, EyeOff,
  Film, FolderPlus, Heart, Info, Star, Trash2, X,
} from "lucide-vue-next";
import AppleSelect from "./AppleSelect.vue";
import IsleVideoPlayer from "./IsleVideoPlayer.vue";
import PhotoLiveOverlay from "./PhotoLiveOverlay.vue";
import PhotoViewerInfoSidebar from "./PhotoViewerInfoSidebar.vue";
import { dateLabel, formatDuration } from "./photoPresentation.ts";
import type { AssetAIDetail } from "./usePhotoAISearchAndPeople.ts";
import type { BatchAsset } from "./usePhotoBatchActions.ts";
import type { FolderAlbum } from "./usePhotoFilterAndSharing.ts";

type AlbumItem = { id: number; name: string; count: number };
type SelectOption<T extends string | number = string | number> = { value: T; label: string };

const props = defineProps<{
  selected: BatchAsset | null;
  active: boolean;
  selectedIndex: number;
  modalAssets: BatchAsset[];
  viewerInfo: boolean;
  albumOrganizerOpen: boolean;
  admin: boolean;
  canWrite: boolean;
  pendingFavorite: boolean;
  trashBusy: boolean;
  slideshow: boolean;
  viewerAIDetail: AssetAIDetail | null;
  viewerAILoading: boolean;
  viewerSrc: string;
  viewerStage: string;
  viewerPreviewLoading: boolean;
  viewerPreviewError: boolean;
  viewerOriginalLoading: boolean;
  viewerOriginalError: boolean;
  viewerScale: number;
  viewerTransform: string;
  viewerAnimate: boolean;
  viewerPointersSize: number;
  browserDecodable: boolean;
  mediaPath: (path: string) => string;
  originalUrl: string;
  thumbFor: (asset: BatchAsset) => string;
  folderAlbums: FolderAlbum[];
  folderAlbumOptions: SelectOption<string>[];
  folderTarget: string;
  albums: AlbumItem[];
  albumOptions: SelectOption<number>[];
  addAlbum: number;
  activeAlbum: number;
  sharedAlbumsError: string;
  sharedAlbumsLoading: boolean;
  privateAlbums: AlbumItem[];
  privateAlbumOptions: SelectOption<number>[];
  addPrivateAlbum: number;
  activePrivateAlbum: number;
  privateAlbumsError: string;
  privateAlbumsLoading: boolean;
  albumBusy: boolean;
  message: string;
  setDialogRef: (el: HTMLElement | null) => void;
  setCloseButtonRef: (el: HTMLButtonElement | null) => void;
}>();

const emit = defineEmits<{
  close: [];
  "show-at": [index: number];
  "toggle-favorite": [];
  "toggle-personal-favorite": [];
  "toggle-album-organizer": [];
  "toggle-slideshow": [];
  "toggle-info": [];
  "trash-selected": [];
  "toggle-zoom": [];
  "request-original": [];
  "pointer-down": [event: PointerEvent];
  "pointer-move": [event: PointerEvent];
  "pointer-up": [event: PointerEvent];
  wheel: [event: WheelEvent];
  "show-on-map": [lat: number, lon: number];
  "select-person": [person: { id: number; name: string }];
  "search-tag": [tag: string];
  "update:folderTarget": [val: string];
  "folder-action": [mode: "copy" | "move"];
  "update:addAlbum": [val: number];
  "add-shared": [];
  "remove-shared": [];
  "retry-shared": [];
  "update:addPrivateAlbum": [val: number];
  "add-private": [];
  "remove-private": [];
  "retry-private": [];
}>();

const viewerChromeVisible = ref(true);
const filmstripRef = ref<HTMLElement | null>(null);

const inAnyRemovableAlbum = computed(() =>
  Boolean((props.admin && props.activeAlbum) || props.activePrivateAlbum),
);

const filmstripWindow = computed(() => {
  const list = props.modalAssets;
  if (list.length <= 1) return [] as Array<{ asset: BatchAsset; index: number }>;
  const start = Math.max(0, props.selectedIndex - 18);
  const end = Math.min(list.length, props.selectedIndex + 19);
  const items: Array<{ asset: BatchAsset; index: number }> = [];
  for (let i = start; i < end; i += 1) {
    items.push({ asset: list[i], index: i });
  }
  return items;
});

watch(
  () => props.selectedIndex,
  async (idx) => {
    if (idx < 0 || !viewerChromeVisible.value) return;
    await nextTick();
    const strip = filmstripRef.value;
    if (!strip) return;
    const activeThumb = strip.querySelector<HTMLElement>(`[data-film-index="${idx}"]`);
    const reduced = typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    activeThumb?.scrollIntoView({ inline: "center", block: "nearest", behavior: reduced ? "auto" : "smooth" });
  },
);

watch(
  () => props.selected,
  (val) => {
    if (!val) viewerChromeVisible.value = true;
  },
);
</script>

<template>
  <Teleport to="body">
    <Transition name="isle-overlay-fade">
      <div v-if="selected && active" class="dialog-backdrop" @click.self="emit('close')">
        <div
          :ref="(el) => setDialogRef(el as HTMLElement | null)"
          class="gallery-modal"
          :class="{ 'gallery-modal--info': viewerInfo, 'gallery-modal--bare': !viewerChromeVisible }"
          role="dialog"
          aria-modal="true"
          aria-label="照片详细信息"
          tabindex="-1"
        >
          <div v-if="viewerChromeVisible" class="gallery-modal-toolbar">
            <div>
              <strong>{{ selected.name }}</strong>
              <small>{{ dateLabel(selected.takenAt) }} · {{ selected.type === "video" ? "视频" : "照片" }} · {{ selectedIndex + 1 }} / {{ modalAssets.length }}</small>
            </div>
            <div class="gallery-modal-actions">
              <button v-if="canWrite" type="button" :disabled="pendingFavorite" title="收藏（F）" aria-label="收藏或取消收藏（快捷键 F）" @click="emit('toggle-favorite')">
                <Heart :size="19" :fill="selected.favorite ? 'currentColor' : 'none'" />
              </button>
              <span v-else class="gallery-readonly-favorite">共享收藏只读</span>
              <button type="button" :disabled="pendingFavorite" :title="selected.personalFavorite ? '从我的收藏移除（F）' : '加入我的收藏（F）'" @click="emit('toggle-personal-favorite')">
                <Star :size="19" :fill="selected.personalFavorite ? 'currentColor' : 'none'" />
              </button>
              <button type="button" :class="{ chosen: albumOrganizerOpen }" :aria-expanded="albumOrganizerOpen" title="整理到相册" aria-label="整理到相册" @click="emit('toggle-album-organizer')">
                <FolderPlus :size="19" />
              </button>
              <button
                v-if="inAnyRemovableAlbum"
                type="button"
                class="album-remove-pill"
                :disabled="albumBusy"
                title="仅从当前相册视图移出，原始照片/视频文件不会删除"
                @click="activePrivateAlbum ? emit('remove-private') : emit('remove-shared')"
              >
                从相册移出（保留原片）
              </button>
              <button v-if="selected.type === 'photo' && modalAssets.length > 1" type="button" class="viewer-pill-btn" :title="slideshow ? '暂停幻灯片' : '开始幻灯片，每4秒一张'" @click="emit('toggle-slideshow')">
                {{ slideshow ? "暂停轮播" : "幻灯片" }}
              </button>
              <button type="button" :class="{ chosen: viewerInfo }" :aria-expanded="viewerInfo" aria-controls="photo-viewer-info" aria-label="拍摄信息与相册（I）" title="拍摄信息（快捷键 I）" @click="emit('toggle-info')">
                <Info :size="19" />
              </button>
              <button type="button" title="隐藏底栏胶片带与工具栏" aria-label="隐藏底栏胶片带与工具栏" @click="viewerChromeVisible = false">
                <EyeOff :size="18" />
              </button>
              <button v-if="canWrite" type="button" :disabled="trashBusy" title="移入回收站（删除照片原片）" aria-label="移入回收站（删除照片）" @click="emit('trash-selected')">
                <Trash2 :size="19" />
              </button>
              <button :ref="(el) => setCloseButtonRef(el as HTMLButtonElement | null)" type="button" title="关闭（Esc）" aria-label="关闭查看器" @click="emit('close')">
                <X :size="19" />
              </button>
            </div>
          </div>
          <div v-else class="viewer-floating-restore">
            <button type="button" title="显示工具栏与胶片缩略图栏" aria-label="显示工具栏与胶片栏" @click="viewerChromeVisible = true"><Eye :size="17" /></button>
            <button type="button" title="关闭（Esc）" aria-label="关闭查看器" @click="emit('close')"><X :size="17" /></button>
          </div>

          <div class="gallery-media-layout">
            <PhotoViewerInfoSidebar
              v-if="viewerInfo"
              :asset="selected"
              :ai-detail="viewerAIDetail"
              :ai-loading="viewerAILoading"
              :media-path="mediaPath"
              @close="emit('toggle-info')"
              @show-on-map="(lat, lon) => emit('show-on-map', lat, lon)"
              @select-person="emit('select-person', $event)"
              @search-tag="emit('search-tag', $event)"
            />
            <div class="gallery-stage">
              <button v-if="selected.type !== 'video' && selectedIndex > 0" type="button" class="viewer-nav prev" title="上一张（←）" aria-label="上一张" @click="emit('show-at', selectedIndex - 1)">
                <ChevronLeft :size="26" />
              </button>
              <div
                v-if="selected.type === 'photo'"
                class="gallery-viewer"
                :class="{ gesturing: !viewerAnimate }"
                @dblclick="viewerPointersSize === 0 && emit('toggle-zoom')"
                @pointerdown="emit('pointer-down', $event)"
                @pointermove="emit('pointer-move', $event)"
                @pointerup="emit('pointer-up', $event)"
                @pointercancel="emit('pointer-up', $event)"
                @wheel="emit('wheel', $event)"
              >
                <img
                  :src="viewerSrc"
                  :alt="selected.name"
                  class="gallery-modal-image"
                  draggable="false"
                  :style="{ transform: viewerTransform, cursor: viewerScale > 1 ? 'grab' : 'zoom-in' }"
                />
                <PhotoLiveOverlay
                  v-if="(selected.liveVideoAssetId ?? 0) > 0"
                  :key="selected.id"
                  :live-video-src="mediaPath('/api/v2/photos/' + selected.id + '/live-video')"
                />
                <button
                  v-if="browserDecodable && viewerStage !== 'original'"
                  type="button"
                  class="gallery-original-quality"
                  :disabled="viewerOriginalLoading"
                  @dblclick.stop
                  @pointerdown.stop
                  @click.stop="emit('request-original')"
                >
                  {{ viewerOriginalLoading ? "正在加载原图…" : viewerOriginalError ? "重试原始画质" : "原始画质" }}
                </button>
                <span class="gallery-viewer-hint">
                  {{ viewerScale > 1 ? "拖拽平移 · Esc 复原 1x · 滚轮/双指缩放" : "双击/滚轮缩放 · ←/→ 翻页 · I 参数 · F 收藏" }}
                  {{ viewerPreviewLoading ? " · 正在加载高清版本…" : viewerPreviewError && viewerStage !== "original" ? " · 预览加载失败，可尝试原始画质或下载原件" : "" }}
                </span>
              </div>
              <IsleVideoPlayer
                v-else
                :key="selected.id"
                :src="originalUrl"
                :title="selected.name"
                :has-prev="selectedIndex > 0"
                :has-next="selectedIndex + 1 < modalAssets.length"
                @prev="emit('show-at', selectedIndex - 1)"
                @next="emit('show-at', selectedIndex + 1)"
                @ended="slideshow && emit('show-at', selectedIndex + 1)"
              />
              <button v-if="selected.type !== 'video' && selectedIndex + 1 < modalAssets.length" type="button" class="viewer-nav next" title="下一张（→）" aria-label="下一张" @click="emit('show-at', selectedIndex + 1)">
                <ChevronRight :size="26" />
              </button>
            </div>
          </div>

          <nav v-if="viewerChromeVisible && filmstripWindow.length && selected.type !== 'video'" ref="filmstripRef" class="viewer-filmstrip" aria-label="相邻照片胶片缩略图导航">
            <button
              v-for="item in filmstripWindow"
              :key="item.asset.id"
              type="button"
              class="viewer-filmstrip-thumb"
              :class="{ active: item.index === selectedIndex }"
              :data-film-index="item.index"
              :aria-current="item.index === selectedIndex ? 'true' : undefined"
              :title="item.asset.name"
              @click="emit('show-at', item.index)"
            >
              <img :src="thumbFor(item.asset)" :alt="item.asset.name" loading="lazy" decoding="async" />
              <span v-if="item.asset.type === 'video'" class="viewer-filmstrip-badge">
                <Film :size="9" />
                <template v-if="(item.asset.durationSeconds ?? 0) > 0">{{ formatDuration(item.asset.durationSeconds!) }}</template>
              </span>
              <span v-else-if="(item.asset.liveVideoAssetId ?? 0) > 0" class="viewer-filmstrip-badge">实况</span>
            </button>
          </nav>

          <div v-if="viewerChromeVisible && (albumOrganizerOpen || sharedAlbumsError || privateAlbumsError)" class="gallery-modal-footer">
            <div v-if="folderAlbums.length" class="private-album-picker">
              <span>文件夹相册</span>
              <AppleSelect :model-value="folderTarget" :options="folderAlbumOptions" size="sm" aria-label="选择文件夹相册" @update:model-value="emit('update:folderTarget', $event)" />
              <button type="button" :disabled="!folderTarget || albumBusy" @click="emit('folder-action', 'copy')">复制到相册</button>
              <button type="button" :disabled="!folderTarget || albumBusy || !canWrite" @click="emit('folder-action', 'move')">移动到相册</button>
            </div>
            <span v-else class="private-album-hint">可在相册页新建「文件夹相册」，以真实目录整理照片。</span>
            <div v-if="admin && albums.length" class="private-album-picker">
              <span>旧版共享相册</span>
              <AppleSelect :model-value="addAlbum" :options="albumOptions" size="sm" aria-label="选择相册" @update:model-value="emit('update:addAlbum', $event)" />
              <button type="button" :disabled="!addAlbum || albumBusy" @click="emit('add-shared')">加入 <ChevronDown :size="14" /></button>
              <button v-if="activeAlbum" type="button" class="album-remove-photo" :disabled="albumBusy" @click="emit('remove-shared')">从相册移出（保留原片）</button>
            </div>
            <div v-if="sharedAlbumsError && selected" class="gallery-modal-feedback" role="alert">
              共享相册读取失败：{{ sharedAlbumsError }}
              <button type="button" class="refresh" :disabled="sharedAlbumsLoading" @click="emit('retry-shared')">{{ sharedAlbumsLoading ? "正在重试…" : "重试" }}</button>
            </div>
            <div v-if="privateAlbums.length" class="private-album-picker">
              <span>旧版私人相册</span>
              <AppleSelect :model-value="addPrivateAlbum" :options="privateAlbumOptions" size="sm" aria-label="选择我的私人相册" @update:model-value="emit('update:addPrivateAlbum', $event)" />
              <button type="button" :disabled="!addPrivateAlbum || albumBusy" @click="emit('add-private')">加入 <ChevronDown :size="14" /></button>
            </div>
            <span v-else-if="privateAlbumsError && selected" class="private-album-hint" role="alert">
              私人相册读取失败：{{ privateAlbumsError }}
              <button type="button" class="refresh" :disabled="privateAlbumsLoading" @click="emit('retry-private')">{{ privateAlbumsLoading ? "正在重试…" : "重试" }}</button>
            </span>
            <button v-if="activePrivateAlbum" type="button" class="album-remove-photo" :disabled="albumBusy" @click="emit('remove-private')">从相册移出（保留原片）</button>
          </div>
          <p v-if="message" class="gallery-modal-feedback" role="status">{{ message }}</p>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.gallery-modal--bare {
  position: relative;
}
.viewer-floating-restore {
  position: absolute;
  top: 14px;
  right: 14px;
  z-index: 20;
  display: inline-flex;
  gap: 6px;
}
.viewer-floating-restore button {
  display: grid;
  place-items: center;
  width: 34px;
  height: 34px;
  border-radius: 999px;
  border: 1px solid rgba(255, 255, 255, 0.2);
  background: rgba(9, 12, 18, 0.72);
  color: #fff;
  cursor: pointer;
}
.gallery-media-layout {
  display: grid;
  grid-template-areas: "stage";
  grid-template-columns: minmax(0, 1fr);
  flex: 1;
  min-height: 0;
  gap: 14px;
}
.gallery-media-layout:has(:deep(.viewer-info)) {
  grid-template-areas: "stage info";
  grid-template-columns: minmax(0, 1fr) clamp(240px, 26vw, 320px);
}
.gallery-stage {
  position: relative;
  grid-area: stage;
  display: grid;
  min-width: 0;
  min-height: 0;
}
.gallery-stage .gallery-viewer {
  width: 100%;
  height: 100%;
  min-height: 0;
}
.gallery-viewer {
  position: relative;
  display: grid;
  place-items: center;
  min-height: 200px;
  overflow: hidden;
  border-radius: 12px;
  background: #05070a;
  touch-action: none;
}
.gallery-viewer .gallery-modal-image {
  max-height: 70vh;
  will-change: transform;
  transition: transform 0.18s ease;
  user-select: none;
}
.gallery-viewer.gesturing .gallery-modal-image {
  transition: none;
}
.gallery-viewer-hint {
  position: absolute;
  left: 12px;
  bottom: 10px;
  font-size: 11px;
  color: #93a0b4;
  pointer-events: none;
}
.viewer-nav {
  position: absolute;
  top: 50%;
  transform: translateY(-50%);
  z-index: 2;
  display: grid;
  place-items: center;
  width: 40px;
  height: 40px;
  border: none;
  border-radius: 99px;
  background: rgba(9, 12, 18, 0.55);
  color: #e8edf5;
  backdrop-filter: blur(6px);
  cursor: pointer;
}
.viewer-nav:hover {
  background: rgba(9, 12, 18, 0.8);
}
.viewer-nav.prev {
  left: 10px;
}
.viewer-nav.next {
  right: 10px;
}
.album-remove-pill {
  padding: 5px 10px !important;
  border-radius: 999px !important;
  border: 1px solid var(--fluid-card-border) !important;
  background: var(--fluid-card-fill) !important;
  color: var(--text-primary) !important;
  font-size: 12px !important;
  font-weight: 600;
  white-space: nowrap;
}
.gallery-readonly-favorite {
  display: flex;
  align-items: center;
  color: var(--text-secondary);
  font-size: 11px;
  white-space: nowrap;
}
.viewer-filmstrip {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 8px 18px 2px;
  overflow-x: auto;
  scrollbar-width: none;
  flex-shrink: 0;
}
.viewer-filmstrip::-webkit-scrollbar {
  display: none;
}
.viewer-filmstrip-thumb {
  position: relative;
  flex: 0 0 auto;
  width: 48px;
  height: 48px;
  padding: 0;
  border-radius: 9px;
  overflow: hidden;
  border: 2px solid transparent;
  background: rgba(0, 0, 0, 0.35);
  opacity: 0.66;
  cursor: pointer;
  transition: transform 0.16s ease, opacity 0.16s ease, border-color 0.16s ease;
}
.viewer-filmstrip-thumb:hover {
  opacity: 0.94;
}
.viewer-filmstrip-thumb.active {
  opacity: 1;
  border-color: var(--accent-primary);
  transform: scale(1.06);
}
.viewer-filmstrip-thumb img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}
.viewer-filmstrip-badge {
  position: absolute;
  right: 2px;
  bottom: 2px;
  display: inline-flex;
  align-items: center;
  gap: 2px;
  padding: 1px 4px;
  border-radius: 4px;
  background: rgba(0, 0, 0, 0.72);
  color: #fff;
  font-size: 9px;
  font-weight: 650;
  line-height: 1.2;
}
.gallery-modal-footer {
  align-items: center;
  flex-wrap: wrap;
}
.gallery-modal-footer .album-remove-photo {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  border: 1px solid var(--fluid-card-border);
  border-radius: var(--radius-sm);
  background: var(--fluid-card-fill);
  color: var(--text-secondary);
  padding: 8px 11px;
  font-size: 12px;
  font-weight: 600;
}
.private-album-picker {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
  color: var(--text-secondary);
  font-size: 12px;
}
.private-album-picker > span {
  font-weight: 650;
}
.private-album-picker button:disabled,
.gallery-modal-actions button:disabled,
.gallery-modal-footer button:disabled {
  opacity: 0.55;
  cursor: wait;
}
.private-album-hint {
  color: var(--text-secondary);
  font-size: 12px;
  line-height: 1.5;
}
.gallery-modal-feedback {
  margin: 0;
  padding: 0 20px 16px;
  color: var(--text-primary);
  font-size: 13px;
  line-height: 1.5;
}
@media (max-width: 780px) {
  .gallery-media-layout:has(:deep(.viewer-info)) {
    grid-template-areas: "stage" "info";
    grid-template-columns: minmax(0, 1fr);
    grid-template-rows: minmax(140px, 1fr) minmax(110px, auto);
  }
  .gallery-media-layout:has(:deep(.viewer-info)) :deep(.viewer-info) {
    max-height: 33vh;
    overflow: auto;
  }
  .gallery-media-layout:has(:deep(.viewer-info)) .gallery-stage {
    min-height: 140px;
  }
  .gallery-modal-footer {
    max-height: min(25vh, 210px);
    overflow: auto;
  }
}
@media (prefers-reduced-motion: reduce) {
  .gallery-viewer .gallery-modal-image,
  .viewer-filmstrip-thumb {
    transition: none;
  }
}
</style>
