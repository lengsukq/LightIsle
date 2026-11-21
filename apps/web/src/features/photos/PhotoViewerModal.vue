<script setup lang="ts">
import { computed, inject, nextTick, ref, watch } from "vue";
import {
  ChevronDown, ChevronLeft, ChevronRight, Download, Eye, EyeOff,
  Film, FolderPlus, Heart, Info, Star, Trash2, X,
} from "lucide-vue-next";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import IsleVideoPlayer from "../../components/ui/IsleVideoPlayer.vue";
import PhotoLiveOverlay from "./PhotoLiveOverlay.vue";
import PhotoViewerInfoSidebar from "./PhotoViewerInfoSidebar.vue";
import { dateLabel, formatDuration } from "./photoPresentation.ts";
import { PHOTO_VIEWER_CTX } from "../../contexts/photosContext.ts";
import type { BatchAsset } from "./usePhotoBatchActions.ts";

const props = defineProps<{
  selected?: BatchAsset | null;
  active?: boolean;
  selectedIndex?: number;
  modalAssets?: BatchAsset[];
  admin?: boolean;
  viewerSrc?: string;
  viewerStage?: string;
  viewerPreviewLoading?: boolean;
  viewerPreviewError?: boolean;
  viewerOriginalLoading?: boolean;
  viewerOriginalError?: boolean;
  viewerScale?: number;
  viewerTransform?: string;
  viewerAnimate?: boolean;
  viewerPointersSize?: number;
  browserDecodable?: boolean;
  mediaPath?: (path: string) => string;
  originalUrl?: string;
  thumbFor?: (asset: BatchAsset) => string;
  fileBrowserMode?: boolean;
  setDialogRef?: (el: HTMLElement | null) => void;
  setCloseButtonRef?: (el: HTMLButtonElement | null) => void;
}>();

const emit = defineEmits<{
  close: [];
  download: [];
  "show-at": [index: number];
  "toggle-zoom": [];
  "request-original": [];
  "pointer-down": [event: PointerEvent];
  "pointer-move": [event: PointerEvent];
  "pointer-up": [event: PointerEvent];
  wheel: [event: WheelEvent];
}>();

const ctx = inject(PHOTO_VIEWER_CTX, null);
const fileBrowserMode = computed(() => Boolean(props.fileBrowserMode));

const selected = computed(() => (ctx ? ctx.selected.value : (props.selected ?? null)));
const active = computed(() => (ctx ? ctx.active.value : Boolean(props.active)));
const selectedIndex = computed(() => (ctx ? ctx.selectedIndex.value : (props.selectedIndex ?? -1)));
const modalAssets = computed(() => (ctx ? ctx.modalAssets.value : (props.modalAssets ?? [])));
const viewerInfo = computed(() => (ctx ? ctx.viewerInfo.value : false));
const albumOrganizerOpen = computed(() => (ctx ? ctx.albumOrganizerOpen.value : false));
const admin = computed(() => (ctx ? ctx.admin.value : Boolean(props.admin)));
const canWrite = computed(() => (ctx ? ctx.canWrite.value : false));
const pendingFavorite = computed(() => (ctx ? ctx.pendingFavorite.value : false));
const trashBusy = computed(() => (ctx ? ctx.trashBusy.value : false));
const slideshow = computed(() => (ctx ? ctx.slideshow.value : false));
const viewerAIDetail = computed(() => (ctx ? ctx.viewerAIDetail.value : null));
const viewerAILoading = computed(() => (ctx ? ctx.viewerAILoading.value : false));
const viewerSrc = computed(() => (ctx ? ctx.viewerSrc.value : (props.viewerSrc ?? "")));
const viewerStage = computed(() => (ctx ? ctx.viewerStage.value : (props.viewerStage ?? "")));
const viewerPreviewLoading = computed(() => (ctx ? ctx.viewerPreviewLoading.value : Boolean(props.viewerPreviewLoading)));
const viewerPreviewError = computed(() => (ctx ? ctx.viewerPreviewError.value : Boolean(props.viewerPreviewError)));
const viewerOriginalLoading = computed(() => (ctx ? ctx.viewerOriginalLoading.value : Boolean(props.viewerOriginalLoading)));
const viewerOriginalError = computed(() => (ctx ? ctx.viewerOriginalError.value : Boolean(props.viewerOriginalError)));
const viewerScale = computed(() => (ctx ? ctx.viewerScale.value : (props.viewerScale ?? 1)));
const viewerTransform = computed(() => (ctx ? ctx.viewerTransform.value : (props.viewerTransform ?? "")));
const viewerAnimate = computed(() => (ctx ? ctx.viewerAnimate.value : Boolean(props.viewerAnimate)));
const viewerPointersSize = computed(() => (ctx ? ctx.viewerPointersSize.value : (props.viewerPointersSize ?? 0)));
const browserDecodable = computed(() => (ctx ? ctx.browserDecodable.value : Boolean(props.browserDecodable)));
const originalUrl = computed(() => (ctx ? ctx.originalUrl.value : (props.originalUrl ?? "")));
const folderAlbums = computed(() => (ctx ? ctx.folderAlbums.value : []));
const folderAlbumOptions = computed(() => (ctx ? ctx.folderAlbumOptions.value : []));
const folderTarget = computed({
  get: () => (ctx ? ctx.folderTarget.value : ""),
  set: (v: string) => { if (ctx) ctx.folderTarget.value = v; },
});
const albums = computed(() => (ctx ? ctx.albums.value : []));
const albumOptions = computed(() => (ctx ? ctx.albumOptions.value : []));
const addAlbum = computed({
  get: () => (ctx ? ctx.addAlbum.value : 0),
  set: (v: number) => { if (ctx) ctx.addAlbum.value = v; },
});
const activeAlbum = computed(() => (ctx ? ctx.activeAlbum.value : 0));
const sharedAlbumsError = computed(() => (ctx ? ctx.sharedAlbumsError.value : ""));
const sharedAlbumsLoading = computed(() => (ctx ? ctx.sharedAlbumsLoading.value : false));
const privateAlbums = computed(() => (ctx ? ctx.privateAlbums.value : []));
const privateAlbumOptions = computed(() => (ctx ? ctx.privateAlbumOptions.value : []));
const addPrivateAlbum = computed({
  get: () => (ctx ? ctx.addPrivateAlbum.value : 0),
  set: (v: number) => { if (ctx) ctx.addPrivateAlbum.value = v; },
});
const activePrivateAlbum = computed(() => (ctx ? ctx.activePrivateAlbum.value : 0));
const privateAlbumsError = computed(() => (ctx ? ctx.privateAlbumsError.value : ""));
const privateAlbumsLoading = computed(() => (ctx ? ctx.privateAlbumsLoading.value : false));
const albumBusy = computed(() => (ctx ? ctx.albumBusy.value : false));
const message = computed(() => (ctx ? ctx.message.value : ""));

function mediaPath(path: string) {
  return ctx ? ctx.mediaPath(path) : (props.mediaPath ? props.mediaPath(path) : path);
}
function thumbFor(asset: BatchAsset) {
  return ctx ? ctx.thumbFor(asset) : (props.thumbFor ? props.thumbFor(asset) : "");
}
function setDialogRef(el: HTMLElement | null) {
  if (ctx) ctx.setDialogRef(el);
  else props.setDialogRef?.(el);
}
function setCloseButtonRef(el: HTMLButtonElement | null) {
  if (ctx) ctx.setCloseButtonRef(el);
  else props.setCloseButtonRef?.(el);
}
function onClose() { if (ctx) ctx.close(); else emit("close"); }
function onShowAt(index: number) { if (ctx) ctx.showAt(index); else emit("show-at", index); }
function onToggleZoom() { if (ctx) ctx.toggleZoom(); else emit("toggle-zoom"); }
function onRequestOriginal() { if (ctx) ctx.requestOriginal(); else emit("request-original"); }
function onPointerDown(e: PointerEvent) { if (ctx) ctx.pointerDown(e); else emit("pointer-down", e); }
function onPointerMove(e: PointerEvent) { if (ctx) ctx.pointerMove(e); else emit("pointer-move", e); }
function onPointerUp(e: PointerEvent) { if (ctx) ctx.pointerUp(e); else emit("pointer-up", e); }
function onWheel(e: WheelEvent) { if (ctx) ctx.wheel(e); else emit("wheel", e); }

const viewerChromeVisible = ref(true);
const filmstripRef = ref<HTMLElement | null>(null);

const inAnyRemovableAlbum = computed(() =>
  Boolean((admin.value && activeAlbum.value) || activePrivateAlbum.value),
);

const filmstripWindow = computed(() => {
  const list = modalAssets.value;
  if (list.length <= 1) return [] as Array<{ asset: BatchAsset; index: number }>;
  const start = Math.max(0, selectedIndex.value - 18);
  const end = Math.min(list.length, selectedIndex.value + 19);
  const items: Array<{ asset: BatchAsset; index: number }> = [];
  for (let i = start; i < end; i += 1) {
    items.push({ asset: list[i], index: i });
  }
  return items;
});

watch(
  selectedIndex,
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
  selected,
  (val) => {
    if (!val) viewerChromeVisible.value = true;
  },
);
</script>

<template>
  <Teleport to="body">
    <Transition name="isle-overlay-fade">
      <div v-if="selected && active" class="dialog-backdrop" @click.self="onClose()">
        <div
          :ref="(el) => setDialogRef(el as HTMLElement | null)"
          class="gallery-modal"
          :class="{ 'gallery-modal--info': viewerInfo, 'gallery-modal--bare': !viewerChromeVisible }"
          role="dialog"
          aria-modal="true"
          aria-label="照片详细信息"
          tabindex="-1"
        >
          <Transition name="viewer-chrome-top">
            <div v-if="viewerChromeVisible" class="gallery-modal-toolbar">
              <div>
                <strong>{{ selected.name }}</strong>
                <small>{{ fileBrowserMode ? "文件预览" : dateLabel(selected.takenAt) }} · {{ selected.type === "video" ? "视频" : "照片" }} · {{ selectedIndex + 1 }} / {{ modalAssets.length }}</small>
              </div>
              <div class="gallery-modal-actions">
                <template v-if="!fileBrowserMode">
                  <button v-if="canWrite" type="button" :disabled="pendingFavorite" title="收藏（F）" aria-label="收藏或取消收藏（快捷键 F）" @click="ctx?.toggleFavorite()">
                    <Heart :size="17" :fill="selected.favorite ? 'currentColor' : 'none'" />
                  </button>
                  <span v-else class="gallery-readonly-favorite">共享收藏只读</span>
                  <button type="button" :disabled="pendingFavorite" :title="selected.personalFavorite ? '从我的收藏移除（F）' : '加入我的收藏（F）'" @click="ctx?.togglePersonalFavorite()">
                    <Star :size="17" :fill="selected.personalFavorite ? 'currentColor' : 'none'" />
                  </button>
                  <button type="button" :class="{ chosen: albumOrganizerOpen }" :aria-expanded="albumOrganizerOpen" title="整理到相册" aria-label="整理到相册" @click="ctx?.toggleAlbumOrganizer()">
                    <FolderPlus :size="17" />
                  </button>
                  <button
                    v-if="inAnyRemovableAlbum"
                    type="button"
                    class="album-remove-pill"
                    :disabled="albumBusy"
                    title="仅从当前相册视图移出，原始照片/视频文件不会删除"
                    @click="activePrivateAlbum ? ctx?.removePrivate() : ctx?.removeShared()"
                  >
                    从相册移出（保留原片）
                  </button>
                  <button v-if="selected.type === 'photo' && modalAssets.length > 1" type="button" class="viewer-pill-btn" :title="slideshow ? '暂停幻灯片' : '开始幻灯片，每4秒一张'" @click="ctx?.toggleSlideshow()">
                    {{ slideshow ? "暂停轮播" : "幻灯片" }}
                  </button>
                  <button type="button" :class="{ chosen: viewerInfo }" :aria-expanded="viewerInfo" aria-controls="photo-viewer-info" aria-label="拍摄信息与相册（I）" title="拍摄信息（快捷键 I）" @click="ctx?.toggleInfo()">
                    <Info :size="17" />
                  </button>
                </template>
                <button v-else type="button" title="下载原文件" aria-label="下载原文件" @click="emit('download')">
                  <Download :size="17" />
                </button>
                <button type="button" title="隐藏底栏胶片带与工具栏" aria-label="隐藏底栏胶片带与工具栏" @click="viewerChromeVisible = false">
                  <EyeOff :size="16" />
                </button>
                <button v-if="!fileBrowserMode && canWrite" type="button" :disabled="trashBusy" title="移入回收站（删除照片原片）" aria-label="移入回收站（删除照片）" @click="ctx?.trashSelected()">
                  <Trash2 :size="17" />
                </button>
                <button :ref="(el) => setCloseButtonRef(el as HTMLButtonElement | null)" type="button" title="关闭（Esc）" aria-label="关闭查看器" @click="onClose()">
                  <X :size="17" />
                </button>
              </div>
            </div>
          </Transition>
          <Transition name="viewer-chrome-top">
            <div v-if="!viewerChromeVisible" class="viewer-floating-restore">
              <button type="button" title="显示工具栏与胶片缩略图栏" aria-label="显示工具栏与胶片栏" @click="viewerChromeVisible = true"><Eye :size="16" /></button>
              <button type="button" title="关闭（Esc）" aria-label="关闭查看器" @click="onClose()"><X :size="16" /></button>
            </div>
          </Transition>

          <div class="gallery-media-layout">
            <PhotoViewerInfoSidebar
              v-if="!fileBrowserMode && viewerInfo"
              :asset="selected"
              :ai-detail="viewerAIDetail"
              :ai-loading="viewerAILoading"
              :media-path="mediaPath"
              @close="ctx?.toggleInfo()"
              @show-on-map="(lat, lon) => ctx?.showOnMap(lat, lon)"
              @select-person="ctx?.selectPerson($event)"
              @search-tag="ctx?.searchTag($event)"
            />
            <div class="gallery-stage">
              <button v-if="selected.type !== 'video' && selectedIndex > 0" type="button" class="viewer-nav prev" title="上一张（←）" aria-label="上一张" @click="onShowAt(selectedIndex - 1)">
                <ChevronLeft :size="22" />
              </button>
              <div
                v-if="selected.type === 'photo'"
                class="gallery-viewer"
                :class="{ gesturing: !viewerAnimate }"
                @dblclick="viewerPointersSize === 0 && onToggleZoom()"
                @pointerdown="onPointerDown($event)"
                @pointermove="onPointerMove($event)"
                @pointerup="onPointerUp($event)"
                @pointercancel="onPointerUp($event)"
                @wheel="onWheel($event)"
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
                  @click.stop="onRequestOriginal()"
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
                @prev="onShowAt(selectedIndex - 1)"
                @next="onShowAt(selectedIndex + 1)"
                @ended="slideshow && onShowAt(selectedIndex + 1)"
              />
              <button v-if="selected.type !== 'video' && selectedIndex + 1 < modalAssets.length" type="button" class="viewer-nav next" title="下一张（→）" aria-label="下一张" @click="onShowAt(selectedIndex + 1)">
                <ChevronRight :size="22" />
              </button>
            </div>
          </div>

          <Transition name="viewer-chrome-bottom">
            <nav v-if="viewerChromeVisible && filmstripWindow.length && (fileBrowserMode || selected.type !== 'video')" ref="filmstripRef" class="viewer-filmstrip" aria-label="相邻照片胶片缩略图导航">
              <button
                v-for="item in filmstripWindow"
                :key="item.asset.id"
                type="button"
                class="viewer-filmstrip-thumb"
                :class="{ active: item.index === selectedIndex }"
                :data-film-index="item.index"
                :aria-current="item.index === selectedIndex ? 'true' : undefined"
                :title="item.asset.name"
                @click="onShowAt(item.index)"
              >
                <img :src="thumbFor(item.asset)" :alt="item.asset.name" loading="lazy" decoding="async" />
                <span v-if="item.asset.type === 'video'" class="viewer-filmstrip-badge">
                  <Film :size="9" />
                  <template v-if="(item.asset.durationSeconds ?? 0) > 0">{{ formatDuration(item.asset.durationSeconds!) }}</template>
                </span>
                <span v-else-if="(item.asset.liveVideoAssetId ?? 0) > 0" class="viewer-filmstrip-badge">实况</span>
              </button>
            </nav>
          </Transition>

          <Transition name="viewer-chrome-bottom">
            <div v-if="!fileBrowserMode && viewerChromeVisible && (albumOrganizerOpen || sharedAlbumsError || privateAlbumsError)" class="gallery-modal-footer">
              <div v-if="folderAlbums.length" class="private-album-picker">
                <span>文件夹相册</span>
                <AppleSelect v-model="folderTarget" :options="folderAlbumOptions" size="sm" aria-label="选择文件夹相册" />
                <button type="button" :disabled="!folderTarget || albumBusy" @click="ctx?.folderAction('copy')">复制到相册</button>
                <button type="button" :disabled="!folderTarget || albumBusy || !canWrite" @click="ctx?.folderAction('move')">移动到相册</button>
              </div>
              <span v-else class="private-album-hint">可在相册页新建「文件夹相册」，以真实目录整理照片。</span>
              <div v-if="admin && albums.length" class="private-album-picker">
                <span>旧版共享相册</span>
                <AppleSelect v-model="addAlbum" :options="albumOptions" size="sm" aria-label="选择相册" />
                <button type="button" :disabled="!addAlbum || albumBusy" @click="ctx?.addShared()">加入 <ChevronDown :size="13" /></button>
                <button v-if="activeAlbum" type="button" class="album-remove-photo" :disabled="albumBusy" @click="ctx?.removeShared()">从相册移出（保留原片）</button>
              </div>
              <div v-if="sharedAlbumsError && selected" class="gallery-modal-feedback" role="alert">
                共享相册读取失败：{{ sharedAlbumsError }}
                <button type="button" class="refresh" :disabled="sharedAlbumsLoading" @click="ctx?.retryShared()">{{ sharedAlbumsLoading ? "正在重试…" : "重试" }}</button>
              </div>
              <div v-if="privateAlbums.length" class="private-album-picker">
                <span>旧版私人相册</span>
                <AppleSelect v-model="addPrivateAlbum" :options="privateAlbumOptions" size="sm" aria-label="选择我的私人相册" />
                <button type="button" :disabled="!addPrivateAlbum || albumBusy" @click="ctx?.addPrivate()">加入 <ChevronDown :size="13" /></button>
              </div>
              <span v-else-if="privateAlbumsError && selected" class="private-album-hint" role="alert">
                私人相册读取失败：{{ privateAlbumsError }}
                <button type="button" class="refresh" :disabled="privateAlbumsLoading" @click="ctx?.retryPrivate()">{{ privateAlbumsLoading ? "正在重试…" : "重试" }}</button>
              </span>
              <button v-if="activePrivateAlbum" type="button" class="album-remove-photo" :disabled="albumBusy" @click="ctx?.removePrivate()">从相册移出（保留原片）</button>
            </div>
          </Transition>
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
  top: 12px;
  right: 12px;
  z-index: 20;
  display: inline-flex;
  gap: 6px;
}
.viewer-floating-restore button {
  display: grid;
  place-items: center;
  width: 32px;
  height: 32px;
  border-radius: 999px;
  border: 1px solid rgba(255, 255, 255, 0.2);
  background: rgba(16, 15, 14, 0.74);
  color: #fff;
  cursor: pointer;
}
.gallery-media-layout {
  display: grid;
  grid-template-areas: "stage";
  grid-template-columns: minmax(0, 1fr);
  flex: 1;
  min-height: 0;
  gap: 10px;
}
.gallery-media-layout:has(:deep(.viewer-info)) {
  grid-template-areas: "stage info";
  grid-template-columns: minmax(0, 1fr) clamp(236px, 25vw, 304px);
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
  border-radius: 14px;
  background: #0c0c0b;
  touch-action: none;
}
.gallery-viewer .gallery-modal-image {
  max-height: 70vh;
  will-change: transform;
  transition: transform 0.2s cubic-bezier(0.22, 1, 0.36, 1);
  user-select: none;
}
.gallery-viewer.gesturing .gallery-modal-image {
  transition: none;
}
.gallery-viewer-hint {
  position: absolute;
  left: 10px;
  bottom: 8px;
  font-size: 11px;
  color: rgba(244, 241, 234, 0.68);
  pointer-events: none;
}
.viewer-nav {
  position: absolute;
  top: 50%;
  transform: translateY(-50%);
  z-index: 2;
  display: grid;
  place-items: center;
  width: 36px;
  height: 36px;
  border: 1px solid rgba(255, 255, 255, 0.16);
  border-radius: 99px;
  background: rgba(18, 17, 15, 0.58);
  color: #f4f1ea;
  backdrop-filter: blur(6px);
  cursor: pointer;
}
.viewer-nav:hover {
  background: rgba(18, 17, 15, 0.84);
}
.viewer-nav.prev {
  left: 8px;
}
.viewer-nav.next {
  right: 8px;
}
.album-remove-pill {
  padding: 4px 10px !important;
  border-radius: 999px !important;
  border: 1px solid var(--fluid-card-border) !important;
  background: var(--fluid-card-fill) !important;
  color: var(--text-primary) !important;
  font-size: 11.5px !important;
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
  gap: 5px;
  padding: 4px 10px 2px;
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
  width: 44px;
  height: 44px;
  padding: 0;
  border-radius: 7px;
  overflow: hidden;
  border: 2px solid transparent;
  background: rgba(0, 0, 0, 0.35);
  opacity: 0.68;
  cursor: pointer;
  transition:
    transform 0.2s cubic-bezier(0.22, 1, 0.36, 1),
    opacity 0.16s ease,
    border-color 0.16s ease;
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
  gap: 5px;
  border: 1px solid var(--fluid-card-border);
  border-radius: 8px;
  background: var(--fluid-card-fill);
  color: var(--text-secondary);
  padding: 6px 10px;
  font-size: 11.5px;
  font-weight: 600;
}
.private-album-picker {
  display: flex;
  align-items: center;
  gap: 6px;
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
  padding: 0 12px 10px;
  color: var(--text-primary);
  font-size: 12px;
  line-height: 1.5;
}
.viewer-chrome-top-enter-active,
.viewer-chrome-bottom-enter-active {
  transition:
    opacity 0.22s cubic-bezier(0.22, 1, 0.36, 1),
    transform 0.22s cubic-bezier(0.22, 1, 0.36, 1);
}
.viewer-chrome-top-leave-active,
.viewer-chrome-bottom-leave-active {
  transition:
    opacity 0.14s cubic-bezier(0.32, 0, 0.67, 0),
    transform 0.14s cubic-bezier(0.32, 0, 0.67, 0);
}
.viewer-chrome-top-enter-from,
.viewer-chrome-top-leave-to {
  opacity: 0;
  transform: translate3d(0, -8px, 0);
}
.viewer-chrome-bottom-enter-from,
.viewer-chrome-bottom-leave-to {
  opacity: 0;
  transform: translate3d(0, 8px, 0);
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
    max-height: min(25vh, 200px);
    overflow: auto;
  }
}
@media (prefers-reduced-motion: reduce) {
  .gallery-viewer .gallery-modal-image,
  .viewer-filmstrip-thumb,
  .viewer-chrome-top-enter-active,
  .viewer-chrome-top-leave-active,
  .viewer-chrome-bottom-enter-active,
  .viewer-chrome-bottom-leave-active {
    transition: none;
  }
}
</style>
