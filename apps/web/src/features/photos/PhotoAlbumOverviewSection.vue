<script setup lang="ts">
import { computed, inject, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { FolderOpen, FolderPlus, Images, LogOut, Plus, RefreshCw, Share2, Sparkles, Trash2 } from "lucide-vue-next";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import IsleActionMenu from "../../components/ui/IsleActionMenu.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleModal from "../../components/ui/IsleModal.vue";
import PhotoMemoriesStrip from "./PhotoMemoriesStrip.vue";
import { PHOTO_ALBUMS_OVERVIEW_CTX, PHOTO_TIMELINE_CTX } from "../../contexts/photosContext.ts";
import { PHOTO_STAGE_EXT_CTX } from "./photoStageContext.ts";

const ctx = inject(PHOTO_ALBUMS_OVERVIEW_CTX);
if (!ctx) throw new Error("PhotoAlbumOverviewSection requires PHOTO_ALBUMS_OVERVIEW_CTX");
const timelineCtx = inject(PHOTO_TIMELINE_CTX, null);
const stageExt = inject(PHOTO_STAGE_EXT_CTX, null);

const {
  folderAlbums, folderCursor, folderError, folderLoading, folderName, albumBusy,
  shareTargetsCount, sharingAlbumPath, shareMemberId, shareCanWrite, shareTargetOptions,
  privateAlbums, privateAlbumsError, privateAlbumsLoading, albums, sharedAlbumsError,
  sharedAlbumsLoading, failedAlbumCovers, mediaPath, refreshFolders, createFolder,
  openFolder, openShare, deleteFolder, submitShare, removeShare, refreshPrivate,
  refreshShared, openLegacy, markCoverError,
} = ctx;

const activeSharingAlbum = computed(
  () => folderAlbums.value.find((album) => album.path === sharingAlbumPath.value && !album.shared) ?? null,
);

const smartMemories = computed(() => timelineCtx?.smartMemories.value ?? []);
const folderCovers = computed(() => stageExt?.folderCovers.value ?? {});
const loadedCovers = ref<Record<string, boolean>>({});
const gridRef = ref<HTMLElement | null>(null);
let coverObserver: IntersectionObserver | null = null;

function onCoverLoad(event: Event, key: string) {
  const img = event.target as HTMLImageElement | null;
  if (img && img.naturalWidth === 0) {
    markCoverError(key);
    return;
  }
  loadedCovers.value = { ...loadedCovers.value, [key]: true };
}

function observeVisibleFolderCovers() {
  if (!stageExt) return;
  const grid = gridRef.value;
  if (!grid || !folderAlbums.value.length) return;
  if (typeof IntersectionObserver === "undefined") {
    for (const album of folderAlbums.value.slice(0, 12)) {
      stageExt.requestFolderCover(album.path);
    }
    return;
  }
  coverObserver?.disconnect();
  coverObserver = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        const path = (entry.target as HTMLElement).dataset.albumPath;
        if (path) {
          stageExt.requestFolderCover(path);
          coverObserver?.unobserve(entry.target);
        }
      }
    },
    { rootMargin: "180px 0px" },
  );
  const cells = grid.querySelectorAll<HTMLElement>("[data-album-path]");
  cells.forEach((cell) => {
    const path = cell.dataset.albumPath;
    if (path && !folderCovers.value[path]) {
      coverObserver?.observe(cell);
    }
  });
}

watch(
  () => folderAlbums.value,
  () => {
    void nextTick(() => observeVisibleFolderCovers());
  },
  { flush: "post" },
);

onMounted(() => {
  void nextTick(() => observeVisibleFolderCovers());
});

onBeforeUnmount(() => {
  coverObserver?.disconnect();
  coverObserver = null;
});
</script>

<template>
  <section class="photo-album-overview settings-stack" aria-label="相册总览">
    <IsleCard
      v-if="smartMemories.length > 0"
      title="智能回忆与精选"
      subtitle="基于拍摄时间、地点与实况自动整理的回忆时刻。"
    >
      <template #icon><Sparkles :size="18" /></template>
      <PhotoMemoriesStrip
        compact
        :memories="smartMemories"
        :media-path="mediaPath"
        @select="stageExt ? stageExt.openSmartMemory($event) : timelineCtx?.selectSmartMemory($event)"
      />
    </IsleCard>

    <IsleCard
      title="照片目录中的文件夹相册"
      subtitle="文件夹相册直接保存在你的照片目录中，加入照片时可选择复制或移动，并支持共享给家庭成员。"
    >
      <template #icon><FolderPlus :size="18" /></template>
      <template #actions>
        <IsleButton variant="glass" size="sm" :loading="folderLoading" @click="refreshFolders()">
          <template #icon><RefreshCw :size="14" /></template>
          刷新
        </IsleButton>
      </template>

      <div class="album-overview-stack">
        <form class="album-new" @submit.prevent="createFolder()">
          <FolderPlus :size="18" />
          <input
            v-model="folderName"
            maxlength="120"
            aria-label="文件夹相册名称"
            placeholder="输入新文件夹相册名称…"
            required
          />
          <IsleButton type="submit" variant="primary" size="sm" :disabled="albumBusy">
            <template #icon><Plus :size="14" /></template>
            新建相册
          </IsleButton>
        </form>

        <IsleBanner v-if="folderError" type="error" compact role="alert" :message="'文件夹相册读取失败：' + folderError">
          <template #action>
            <IsleButton variant="glass" size="sm" @click="refreshFolders()">重试</IsleButton>
          </template>
        </IsleBanner>

        <div v-if="folderAlbums.length" ref="gridRef" class="photo-album-card-grid">
          <div
            v-for="album in folderAlbums"
            :key="album.path"
            :data-album-path="album.path"
            class="folder-album-cell"
          >
            <button type="button" class="photo-album-card" @click="openFolder(album)">
              <span class="photo-album-cover">
                <img
                  v-if="folderCovers[album.path] && !failedAlbumCovers['folder:' + album.path]"
                  :src="mediaPath('/api/v2/photos/' + folderCovers[album.path] + '/thumbnail')"
                  :alt="album.name + ' 封面'"
                  :class="{ 'is-loaded': loadedCovers['folder:' + album.path] }"
                  loading="lazy"
                  decoding="async"
                  @load="onCoverLoad($event, 'folder:' + album.path)"
                  @error="markCoverError('folder:' + album.path)"
                />
                <FolderPlus v-else :size="30" />
                <span v-if="album.shared" class="folder-album-badge">共享</span>
                <span v-else-if="album.shares?.length" class="folder-album-badge">{{ album.shares.length }} 人共享</span>
              </span>
              <strong :title="album.name">{{ album.name }}</strong>
              <small>{{ album.shared ? `来自 @${album.ownerUsername} · ${album.canWrite ? '可读写' : '只读'}` : album.shares?.length ? `已共享给 ${album.shares.length} 人` : '照片目录中的文件夹' }}</small>
            </button>
            <div class="folder-album-menu-wrap" @click.stop>
              <IsleActionMenu size="sm" align="right" :aria-label="'更多操作：' + album.name">
                <button type="button" @click="openFolder(album)">
                  <FolderOpen :size="14" /> 打开相册
                </button>
                <button
                  v-if="!album.shared && shareTargetsCount"
                  type="button"
                  :disabled="albumBusy"
                  @click="openShare(album)"
                >
                  <Share2 :size="14" /> {{ sharingAlbumPath === album.path ? "管理共享" : "共享给家人" }}
                </button>
                <button
                  v-if="!album.shared"
                  type="button"
                  class="danger"
                  :disabled="albumBusy"
                  @click="deleteFolder(album)"
                >
                  <Trash2 :size="14" /> 删除空相册
                </button>
                <button
                  v-if="album.shared && album.ownerUserId"
                  type="button"
                  class="danger"
                  :disabled="albumBusy"
                  @click="removeShare(album, album.memberUserId || 0, album.ownerUserId)"
                >
                  <LogOut :size="14" /> 退出共享
                </button>
              </IsleActionMenu>
            </div>
          </div>
        </div>
        <IsleModal
          v-if="activeSharingAlbum"
          :title="`共享文件夹相册 · ${activeSharingAlbum.name}`"
          size="sm"
          @close="openShare(activeSharingAlbum)"
        >
          <template #icon><Share2 :size="17" /></template>
          <div class="folder-album-share-form">
            <label class="folder-album-share-field">
              <span>选择家庭成员</span>
              <AppleSelect v-model="shareMemberId" :options="shareTargetOptions" size="sm" block aria-label="选择共享成员" />
            </label>
            <label class="folder-album-share-check">
              <input v-model="shareCanWrite" type="checkbox" />
              <span>允许上传（计入我的配额）</span>
            </label>
            <div v-if="activeSharingAlbum.shares?.length" class="folder-album-share-list">
              <span class="folder-album-share-subtitle">当前已共享成员</span>
              <div class="folder-album-share-chips">
                <span v-for="s in activeSharingAlbum.shares" :key="s.id" class="folder-album-share-chip">
                  @{{ s.memberUsername }}（{{ s.canWrite ? '可写' : '只读' }}）
                  <IsleButton variant="danger" size="sm" :disabled="albumBusy" @click="removeShare(activeSharingAlbum, s.memberUserId)">移除</IsleButton>
                </span>
              </div>
            </div>
          </div>
          <template #footer>
            <div class="folder-album-share-footer">
              <IsleButton variant="glass" size="sm" :disabled="albumBusy" @click="openShare(activeSharingAlbum)">关闭</IsleButton>
              <IsleButton variant="primary" size="sm" :disabled="albumBusy || !shareMemberId" @click="submitShare(activeSharingAlbum)">确认共享</IsleButton>
            </div>
          </template>
        </IsleModal>
        <IsleEmpty v-else-if="!folderError && !folderLoading && !folderCursor" compact :icon="Images" description="照片目录中还没有文件夹相册。" />
        <div v-if="folderCursor">
          <IsleButton variant="glass" size="sm" :loading="folderLoading" @click="refreshFolders(true)">加载更多文件夹</IsleButton>
        </div>
      </div>
    </IsleCard>

    <IsleCard
      v-if="privateAlbums.length > 0 || privateAlbumsError"
      :title="`旧版私人相册 (${privateAlbums.length})`"
      subtitle="仅当前账号可见，保留历史照片收藏集关联。"
    >
      <template #icon><Images :size="18" /></template>
      <IsleBanner v-if="privateAlbumsError" type="error" compact role="alert" :message="'私人相册读取失败：' + privateAlbumsError">
        <template #action>
          <IsleButton variant="glass" size="sm" :loading="privateAlbumsLoading" @click="refreshPrivate()">重试</IsleButton>
        </template>
      </IsleBanner>
      <div v-if="privateAlbums.length" class="photo-album-card-grid">
        <button v-for="album in privateAlbums" :key="'personal-' + album.id" type="button" class="photo-album-card" @click="openLegacy(album, true)">
          <span class="photo-album-cover">
            <img
              v-if="album.coverAssetId && !failedAlbumCovers['personal:' + album.id]"
              :src="mediaPath('/api/v2/photos/' + album.coverAssetId + '/thumbnail')"
              :alt="album.name + '封面'"
              :class="{ 'is-loaded': loadedCovers['personal:' + album.id] }"
              loading="lazy"
              decoding="async"
              @load="onCoverLoad($event, 'personal:' + album.id)"
              @error="markCoverError('personal:' + album.id)"
            />
            <Images v-else :size="30" />
          </span>
          <strong :title="album.name">{{ album.name }}</strong><small>{{ album.count }} 项 · 仅自己可见</small>
        </button>
      </div>
    </IsleCard>

    <IsleCard
      v-if="albums.length > 0 || sharedAlbumsError"
      :title="`旧版共享相册 (${albums.length})`"
      subtitle="保留历史共享相册记录，新相册建议直接使用上方「文件夹相册」。"
    >
      <template #icon><Images :size="18" /></template>
      <IsleBanner v-if="sharedAlbumsError" type="error" compact role="alert" :message="'共享相册读取失败：' + sharedAlbumsError">
        <template #action>
          <IsleButton variant="glass" size="sm" :loading="sharedAlbumsLoading" @click="refreshShared()">重试</IsleButton>
        </template>
      </IsleBanner>
      <div v-if="albums.length" class="photo-album-card-grid">
        <button v-for="album in albums" :key="'shared-' + album.id" type="button" class="photo-album-card" @click="openLegacy(album, false)">
          <span class="photo-album-cover">
            <img
              v-if="album.coverAssetId && !failedAlbumCovers['shared:' + album.id]"
              :src="mediaPath('/api/v2/photos/' + album.coverAssetId + '/thumbnail')"
              :alt="album.name + '封面'"
              :class="{ 'is-loaded': loadedCovers['shared:' + album.id] }"
              loading="lazy"
              decoding="async"
              @load="onCoverLoad($event, 'shared:' + album.id)"
              @error="markCoverError('shared:' + album.id)"
            />
            <Images v-else :size="30" />
          </span>
          <strong :title="album.name">{{ album.name }}</strong><small>{{ album.count }} 项 · 共享</small>
        </button>
      </div>
    </IsleCard>
  </section>
</template>

<style scoped>
.album-overview-stack {
  display: flex;
  flex-direction: column;
  gap: 14px;
}
.folder-album-cell {
  position: relative;
  display: flex;
  flex-direction: column;
}
.photo-album-cover img {
  opacity: 0;
  transition: opacity 0.28s ease, transform 0.35s cubic-bezier(0.22, 1, 0.36, 1);
}
.photo-album-cover img.is-loaded {
  opacity: 1;
}
.folder-album-cell:hover .photo-album-cover img.is-loaded,
.photo-album-card:hover .photo-album-cover img.is-loaded {
  transform: scale(1.03);
}
.folder-album-badge {
  position: absolute;
  left: 8px;
  bottom: 8px;
  padding: 2px 8px;
  border-radius: 999px;
  background: rgba(15, 18, 24, 0.68);
  color: #fff;
  font-size: 10.5px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  pointer-events: none;
}
.folder-album-menu-wrap {
  position: absolute;
  top: 8px;
  right: 8px;
  z-index: 4;
  opacity: 0;
  transform: translate3d(0, -2px, 0);
  transition: opacity 0.16s ease, transform 0.18s ease;
}
.folder-album-cell:hover .folder-album-menu-wrap,
.folder-album-cell:focus-within .folder-album-menu-wrap,
.folder-album-menu-wrap:has([aria-expanded="true"]) {
  opacity: 1;
  transform: translate3d(0, 0, 0);
}
@media (hover: none) {
  .folder-album-menu-wrap {
    opacity: 1;
    transform: none;
  }
}
.folder-album-share-form {
  display: grid;
  gap: 12px;
}
.folder-album-share-field {
  display: grid;
  gap: 6px;
  font-size: 12.5px;
  font-weight: 600;
  color: var(--text-primary);
}
.folder-album-share-list {
  display: grid;
  gap: 6px;
  padding-top: 8px;
  border-top: 1px solid var(--fluid-divider, var(--stroke-subtle));
}
.folder-album-share-subtitle {
  font-size: 12px;
  font-weight: 600;
  color: var(--text-secondary);
}
.folder-album-share-chips {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
}
.folder-album-share-footer {
  display: flex;
  justify-content: flex-end;
  gap: 8px;
  width: 100%;
}
.folder-album-share-check,
.folder-album-share-chip {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 12px;
  color: var(--text-secondary);
}
@media (prefers-reduced-motion: reduce) {
  .photo-album-cover img,
  .folder-album-menu-wrap {
    transition: none;
  }
}
</style>
