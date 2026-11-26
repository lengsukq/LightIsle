<script setup lang="ts">
import { computed, inject, ref, watch } from "vue";
import {
  ChevronLeft, ChevronRight, Download, Eye, EyeOff,
  FolderPlus, Heart, Info, Star, Trash2, X,
} from "lucide-vue-next";
import IsleVideoPlayer from "../../components/ui/IsleVideoPlayer.vue";
import PhotoLiveOverlay from "./PhotoLiveOverlay.vue";
import PhotoViewerInfoSidebar from "./PhotoViewerInfoSidebar.vue";
import PhotoViewerAlbumDrawer from "./PhotoViewerAlbumDrawer.vue";
import PhotoViewerFilmstrip from "./PhotoViewerFilmstrip.vue";
import { dateLabel } from "./photoPresentation.ts";
import { PHOTO_VIEWER_CTX } from "../../contexts/photosContext.ts";
import { PHOTO_STAGE_EXT_CTX } from "./photoStageContext.ts";
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
const stageExt = inject(PHOTO_STAGE_EXT_CTX, null);
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
const activeAlbum = computed(() => (ctx ? ctx.activeAlbum.value : 0));
const sharedAlbumsError = computed(() => (ctx ? ctx.sharedAlbumsError.value : ""));
const activePrivateAlbum = computed(() => (ctx ? ctx.activePrivateAlbum.value : 0));
const privateAlbumsError = computed(() => (ctx ? ctx.privateAlbumsError.value : ""));
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
function onToggleZoom(event?: MouseEvent) {
  if (ctx) {
    if (stageExt?.toggleZoomAtPointer) stageExt.toggleZoomAtPointer(event);
    else ctx.toggleZoom();
  } else {
    emit("toggle-zoom");
  }
}
function onRequestOriginal() { if (ctx) ctx.requestOriginal(); else emit("request-original"); }
function onPointerDown(e: PointerEvent) { if (ctx) ctx.pointerDown(e); else emit("pointer-down", e); }
function onPointerMove(e: PointerEvent) { if (ctx) ctx.pointerMove(e); else emit("pointer-move", e); }
function onPointerUp(e: PointerEvent) { if (ctx) ctx.pointerUp(e); else emit("pointer-up", e); }
function onWheel(e: WheelEvent) { if (ctx) ctx.wheel(e); else emit("wheel", e); }
function onDownload() {
  if (fileBrowserMode.value) {
    emit("download");
    return;
  }
  const asset = selected.value;
  if (!asset) return;
  if (stageExt?.downloadAsset) {
    stageExt.downloadAsset(asset);
    return;
  }
  const link = document.createElement("a");
  link.href = mediaPath("/api/v2/files/content?path=" + encodeURIComponent(asset.path));
  link.download = asset.name;
  link.rel = "noopener";
  document.body.appendChild(link);
  link.click();
  link.remove();
}

const viewerChromeVisible = ref(true);

const inAnyRemovableAlbum = computed(() =>
  Boolean((admin.value && activeAlbum.value) || activePrivateAlbum.value),
);

const showFilmstrip = computed(() =>
  Boolean(
    viewerChromeVisible.value &&
    modalAssets.value.length > 1 &&
    (fileBrowserMode.value || selected.value?.type !== "video"),
  ),
);

const showBottomChrome = computed(() =>
  Boolean(
    viewerChromeVisible.value &&
    (
      showFilmstrip.value ||
      (!fileBrowserMode.value && (albumOrganizerOpen.value || sharedAlbumsError.value || privateAlbumsError.value)) ||
      message.value
    ),
  ),
);

watch(
  selected,
  (val) => {
    if (!val) {
      viewerChromeVisible.value = true;
    }
  },
);
</script>

<template>
  <Teleport to="body">
    <Transition name="isle-overlay-fade">
      <div v-if="selected && active" class="dialog-backdrop viewer-obsidian-backdrop" @click.self="onClose()">
        <div
          :ref="(el) => setDialogRef(el as HTMLElement | null)"
          class="gallery-modal viewer-obsidian-stage"
          :class="{ 'gallery-modal--info': viewerInfo, 'gallery-modal--bare': !viewerChromeVisible }"
          role="dialog"
          aria-modal="true"
          aria-label="照片详细信息"
          tabindex="-1"
        >
          <Transition name="viewer-chrome-top">
            <div v-if="viewerChromeVisible" class="gallery-modal-toolbar viewer-obsidian-topbar">
              <div>
                <strong>{{ selected.name }}</strong>
                <small class="viewer-topbar-meta">{{ fileBrowserMode ? "文件预览" : dateLabel(selected.takenAt) }} · {{ selected.type === "video" ? "视频" : "照片" }} · {{ selectedIndex + 1 }} / {{ modalAssets.length }}</small>
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
                    从相册移出<span class="viewer-pill-detail">（保留原片）</span>
                  </button>
                  <button v-if="selected.type === 'photo' && modalAssets.length > 1" type="button" class="viewer-pill-btn" :class="{ chosen: slideshow }" :title="slideshow ? '暂停幻灯片' : '开始幻灯片，每4秒一张'" @click="ctx?.toggleSlideshow()">
                    {{ slideshow ? "暂停轮播" : "幻灯片" }}
                  </button>
                  <button v-if="selected.type === 'photo'" type="button" class="viewer-pill-btn" title="全屏电子相框轮播" @click="ctx?.openPhotoFrame()">
                    电子相框
                  </button>
                  <button type="button" :class="{ chosen: viewerInfo }" :aria-expanded="viewerInfo" aria-controls="photo-viewer-info" aria-label="拍摄信息与相册（I）" title="拍摄信息（快捷键 I）" @click="ctx?.toggleInfo()">
                    <Info :size="17" />
                  </button>
                </template>
                <button type="button" title="下载原文件" aria-label="下载原文件" @click="onDownload()">
                  <Download :size="17" />
                </button>
                <button type="button" title="隐藏底栏胶片带与工具栏" aria-label="隐藏底栏胶片带与工具栏" @click="viewerChromeVisible = false">
                  <EyeOff :size="16" />
                </button>
                <button v-if="!fileBrowserMode && canWrite" type="button" :disabled="trashBusy" title="移入回收站（删除照片原片）" aria-label="移入回收站（删除照片）" @click="ctx?.trashSelected()">
                  <Trash2 :size="17" />
                </button>
                <button :ref="(el) => setCloseButtonRef(el as HTMLButtonElement | null)" type="button" class="viewer-close-btn" title="关闭（Esc）" aria-label="关闭查看器" @click="onClose()">
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
            <div class="gallery-stage">
              <button v-if="selected.type !== 'video' && selectedIndex > 0" type="button" class="viewer-nav prev" title="上一张（←）" aria-label="上一张" @click="onShowAt(selectedIndex - 1)">
                <ChevronLeft :size="22" />
              </button>
              <div
                v-if="selected.type === 'photo'"
                class="gallery-viewer"
                :class="{ gesturing: !viewerAnimate }"
                @dblclick="viewerPointersSize === 0 && onToggleZoom($event)"
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
                <span v-if="viewerChromeVisible" class="gallery-viewer-hint">
                  <template v-if="viewerScale > 1">
                    拖拽平移<span class="hint-desktop-only"> · Esc 复原 1x · 滚轮/双指缩放</span><span class="hint-touch-only"> · 双指缩放</span>
                  </template>
                  <template v-else>
                    <span class="hint-desktop-only">{{ fileBrowserMode ? "双击/滚轮缩放 · ←/→ 翻页" : "双击/滚轮缩放 · ←/→ 翻页 · I 参数 · F 收藏" }}</span>
                    <span class="hint-touch-only">双击/双指缩放 · 左右滑动翻页</span>
                  </template>
                  <template v-if="viewerPreviewLoading"> · 正在加载高清版本…</template>
                  <template v-else-if="viewerPreviewError && viewerStage !== 'original'"> · 预览加载失败，可尝试原始画质或下载原件</template>
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

            <Transition name="viewer-info-drawer">
              <div v-if="!fileBrowserMode && viewerInfo" class="viewer-info-drawer-wrap">
                <PhotoViewerInfoSidebar
                  :asset="selected"
                  :ai-detail="viewerAIDetail"
                  :ai-loading="viewerAILoading"
                  :can-write="canWrite"
                  :media-path="mediaPath"
                  @close="ctx?.toggleInfo()"
                  @show-on-map="(lat, lon) => ctx?.showOnMap(lat, lon)"
                  @select-person="ctx?.selectPerson($event)"
                  @search-tag="ctx?.searchTag($event)"
                  @edit-metadata="ctx?.editMetadata()"
                />
              </div>
            </Transition>
          </div>

          <Transition name="viewer-chrome-bottom">
            <div v-if="showBottomChrome" class="viewer-obsidian-bottom">
              <PhotoViewerFilmstrip
                v-if="showFilmstrip"
                :assets="modalAssets"
                :selected-index="selectedIndex"
                :visible="showFilmstrip"
                :thumb-for="thumbFor"
                @select="onShowAt($event)"
              />
              <PhotoViewerAlbumDrawer v-if="!fileBrowserMode && (albumOrganizerOpen || sharedAlbumsError || privateAlbumsError)" />
              <p v-if="message" class="gallery-modal-feedback" role="status">{{ message }}</p>
            </div>
          </Transition>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.dialog-backdrop.viewer-obsidian-backdrop {
  position: fixed;
  inset: 0;
  padding: 0;
  background: #050507;
  -webkit-backdrop-filter: none;
  backdrop-filter: none;
  animation: none;
}
.dialog-backdrop .gallery-modal.viewer-obsidian-stage {
  position: relative;
  width: 100vw;
  height: 100dvh;
  max-width: 100vw;
  max-height: 100dvh;
  padding: 0;
  gap: 0;
  border: 0;
  border-radius: 0;
  box-shadow: none;
  background: #050507;
  color: #f5f5f7;
  animation: none;
  overflow: hidden;
  display: block;
}
.gallery-modal-toolbar.viewer-obsidian-topbar {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  z-index: 20;
  box-sizing: border-box;
  width: 100%;
  min-width: 0;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: max(12px, env(safe-area-inset-top)) max(18px, env(safe-area-inset-right)) 12px max(18px, env(safe-area-inset-left));
  background: linear-gradient(to bottom, rgba(10, 10, 12, 0.86) 0%, rgba(10, 10, 12, 0.54) 100%);
  -webkit-backdrop-filter: blur(22px) saturate(160%);
  backdrop-filter: blur(22px) saturate(160%);
  border-bottom: 1px solid rgba(255, 255, 255, 0.08);
  color: #f5f5f7;
}
.viewer-obsidian-topbar > div:first-child {
  min-width: 0;
  flex: 1 1 160px;
}
.viewer-obsidian-topbar strong {
  display: block;
  font-size: 13.5px;
  font-weight: 650;
  color: #f5f5f7;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.viewer-topbar-meta {
  display: block;
  margin-top: 2px;
  font-size: 11px;
  font-variant-numeric: tabular-nums;
  color: rgba(245, 245, 247, 0.68);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.gallery-modal-actions {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
  min-width: 0;
  max-width: 100%;
}
.viewer-obsidian-stage .gallery-modal-actions button {
  width: 34px;
  height: 34px;
  border-radius: 10px;
  border: 1px solid rgba(255, 255, 255, 0.14);
  background: rgba(255, 255, 255, 0.1);
  color: rgba(255, 255, 255, 0.92);
  display: grid;
  place-items: center;
  cursor: pointer;
}
.viewer-obsidian-stage .gallery-modal-actions button:hover:not(:disabled) {
  background: rgba(255, 255, 255, 0.2);
  color: #fff;
}
.viewer-obsidian-stage .gallery-modal-actions button.chosen {
  background: var(--accent-primary-solid, var(--accent-primary));
  color: #fff;
  border-color: transparent;
}
.viewer-obsidian-stage .gallery-modal-actions button.album-remove-pill,
.viewer-obsidian-stage .gallery-modal-actions button.viewer-pill-btn {
  width: auto;
  padding: 0 11px;
  white-space: nowrap;
  display: inline-flex;
  align-items: center;
  gap: 5px;
  font-size: 12px;
  font-weight: 600;
}
.viewer-obsidian-stage .gallery-modal-actions button:disabled {
  opacity: 0.45;
  cursor: wait;
}
.gallery-readonly-favorite {
  display: flex;
  align-items: center;
  color: rgba(245, 245, 247, 0.68);
  font-size: 11px;
  white-space: nowrap;
}
.viewer-floating-restore {
  position: absolute;
  top: max(12px, env(safe-area-inset-top));
  right: max(14px, env(safe-area-inset-right));
  z-index: 22;
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
  background: rgba(16, 16, 20, 0.76);
  -webkit-backdrop-filter: blur(16px);
  backdrop-filter: blur(16px);
  color: #fff;
  cursor: pointer;
}
.gallery-media-layout {
  position: relative;
  width: 100%;
  height: 100%;
  min-height: 0;
}
.gallery-stage {
  position: relative;
  width: 100%;
  height: 100%;
  display: grid;
  min-width: 0;
  min-height: 0;
}
.gallery-stage :deep(.isle-video-player) {
  height: 100%;
  max-height: 100dvh;
  border-radius: 0;
  box-sizing: border-box;
  padding-top: 58px;
}
.gallery-modal--bare .gallery-stage :deep(.isle-video-player) {
  padding-top: 0;
}
.gallery-stage :deep(.video-element) {
  max-height: 100%;
}
.gallery-viewer {
  --viewer-live-top: 72px;
  position: relative;
  display: grid;
  place-items: center;
  width: 100%;
  height: 100%;
  min-height: 0;
  overflow: hidden;
  border-radius: 0;
  background: #050507;
  touch-action: none;
}
.gallery-modal--bare .gallery-viewer {
  --viewer-live-top: 16px;
}
.gallery-viewer .gallery-modal-image {
  max-width: 100%;
  max-height: 100%;
  width: auto;
  height: auto;
  object-fit: contain;
  border-radius: 0;
  background: transparent;
  will-change: transform;
  transition: transform 0.22s cubic-bezier(0.22, 1, 0.36, 1);
  user-select: none;
}
.gallery-viewer.gesturing .gallery-modal-image {
  transition: none;
}
.gallery-original-quality {
  position: absolute;
  top: 72px;
  right: max(16px, env(safe-area-inset-right));
  z-index: 8;
  padding: 5px 11px;
  border-radius: 999px;
  border: 1px solid rgba(255, 255, 255, 0.2);
  background: rgba(16, 17, 22, 0.72);
  -webkit-backdrop-filter: blur(14px);
  backdrop-filter: blur(14px);
  color: rgba(255, 255, 255, 0.92);
  font-size: 11.5px;
  font-weight: 600;
  cursor: pointer;
}
.gallery-modal--bare .gallery-original-quality {
  top: 56px;
}
.gallery-viewer-hint {
  position: absolute;
  left: max(16px, env(safe-area-inset-left));
  bottom: 76px;
  max-width: calc(100% - 32px);
  padding: 4px 10px;
  border-radius: 999px;
  background: rgba(12, 13, 18, 0.66);
  color: rgba(255, 255, 255, 0.84);
  font-size: 11px;
  line-height: 1.35;
  pointer-events: none;
}
.hint-touch-only { display: none; }
@media (hover: none) {
  .hint-desktop-only { display: none; }
  .hint-touch-only { display: inline; }
}
.viewer-nav {
  position: absolute;
  top: 50%;
  transform: translateY(-50%);
  z-index: 8;
  display: grid;
  place-items: center;
  width: 40px;
  height: 40px;
  border: 1px solid rgba(255, 255, 255, 0.16);
  border-radius: 999px;
  background: rgba(18, 18, 22, 0.62);
  color: #f4f1ea;
  -webkit-backdrop-filter: blur(12px);
  backdrop-filter: blur(12px);
  cursor: pointer;
}
.viewer-nav:hover {
  background: rgba(34, 34, 42, 0.88);
}
.viewer-nav.prev { left: max(12px, env(safe-area-inset-left)); }
.viewer-nav.next { right: max(12px, env(safe-area-inset-right)); }
.viewer-info-drawer-wrap {
  position: absolute;
  top: 0;
  right: 0;
  bottom: 0;
  width: min(340px, 90vw);
  z-index: 26;
}
.viewer-obsidian-bottom {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 0;
  z-index: 20;
  display: flex;
  flex-direction: column;
  background: linear-gradient(to top, rgba(10, 10, 12, 0.9) 0%, rgba(10, 10, 12, 0.62) 100%);
  -webkit-backdrop-filter: blur(22px) saturate(160%);
  backdrop-filter: blur(22px) saturate(160%);
  border-top: 1px solid rgba(255, 255, 255, 0.08);
  padding-bottom: max(8px, env(safe-area-inset-bottom));
}
.gallery-modal-feedback {
  margin: 0;
  padding: 4px 18px 6px;
  color: rgba(245, 245, 247, 0.9);
  font-size: 12px;
  line-height: 1.45;
}
.viewer-chrome-top-enter-active,
.viewer-chrome-bottom-enter-active,
.viewer-info-drawer-enter-active {
  transition: opacity 0.24s cubic-bezier(0.22, 1, 0.36, 1), transform 0.24s cubic-bezier(0.22, 1, 0.36, 1);
}
.viewer-chrome-top-leave-active,
.viewer-chrome-bottom-leave-active,
.viewer-info-drawer-leave-active {
  transition: opacity 0.16s cubic-bezier(0.32, 0, 0.67, 0), transform 0.16s cubic-bezier(0.32, 0, 0.67, 0);
}
.viewer-chrome-top-enter-from,
.viewer-chrome-top-leave-to {
  opacity: 0;
  transform: translate3d(0, -10px, 0);
}
.viewer-chrome-bottom-enter-from,
.viewer-chrome-bottom-leave-to {
  opacity: 0;
  transform: translate3d(0, 10px, 0);
}
.viewer-info-drawer-enter-from,
.viewer-info-drawer-leave-to {
  opacity: 0;
  transform: translate3d(24px, 0, 0);
}
@media (max-width: 780px) {
  .viewer-info-drawer-wrap {
    top: auto;
    left: 0;
    right: 0;
    bottom: 0;
    width: 100%;
    height: min(62dvh, 460px);
  }
  .viewer-info-drawer-enter-from,
  .viewer-info-drawer-leave-to {
    transform: translate3d(0, 28px, 0);
  }
}
@media (max-width: 767px) {
  .gallery-modal-toolbar.viewer-obsidian-topbar {
    flex-wrap: wrap;
    gap: 8px;
    padding: max(10px, env(safe-area-inset-top)) 12px 10px;
  }
  .viewer-obsidian-topbar > div:first-child { flex: 1 1 100%; }
  .gallery-modal-actions {
    width: 100%;
    justify-content: flex-end;
    gap: 5px;
  }
  .viewer-obsidian-stage .gallery-modal-actions button {
    width: 31px;
    height: 31px;
    flex-shrink: 0;
  }
  .viewer-obsidian-stage .gallery-modal-actions button.album-remove-pill,
  .viewer-obsidian-stage .gallery-modal-actions button.viewer-pill-btn {
    width: auto;
    max-width: 100%;
    height: 31px;
    padding: 0 9px;
    font-size: 11.5px;
  }
  .viewer-pill-detail { display: none; }
}
@media (prefers-reduced-transparency: reduce) {
  .gallery-modal-toolbar.viewer-obsidian-topbar,
  .viewer-obsidian-bottom,
  .viewer-floating-restore button,
  .gallery-original-quality,
  .viewer-nav {
    -webkit-backdrop-filter: none;
    backdrop-filter: none;
    background: rgba(12, 12, 16, 0.94);
  }
}
@media (prefers-reduced-motion: reduce) {
  .gallery-viewer .gallery-modal-image,
  .viewer-chrome-top-enter-active,
  .viewer-chrome-top-leave-active,
  .viewer-chrome-bottom-enter-active,
  .viewer-chrome-bottom-leave-active,
  .viewer-info-drawer-enter-active,
  .viewer-info-drawer-leave-active {
    transition: none;
  }
}
</style>
