<script setup lang="ts">
import { inject } from "vue";
import { FolderPlus, Images, RefreshCw, Share2, Trash2, Plus } from "lucide-vue-next";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import { PHOTO_ALBUMS_OVERVIEW_CTX } from "../../contexts/photosContext.ts";

const ctx = inject(PHOTO_ALBUMS_OVERVIEW_CTX);
if (!ctx) throw new Error("PhotoAlbumOverviewSection requires PHOTO_ALBUMS_OVERVIEW_CTX");

const {
  folderAlbums, folderCursor, folderError, folderLoading, folderName, albumBusy,
  shareTargetsCount, sharingAlbumPath, shareMemberId, shareCanWrite, shareTargetOptions,
  privateAlbums, privateAlbumsError, privateAlbumsLoading, albums, sharedAlbumsError,
  sharedAlbumsLoading, failedAlbumCovers, mediaPath, refreshFolders, createFolder,
  openFolder, openShare, deleteFolder, submitShare, removeShare, refreshPrivate,
  refreshShared, openLegacy, markCoverError,
} = ctx;
</script>

<template>
  <section class="photo-album-overview settings-stack" aria-label="相册总览">
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

        <div v-if="folderAlbums.length" class="photo-album-card-grid">
          <div v-for="album in folderAlbums" :key="album.path" class="folder-album-cell">
            <button type="button" class="photo-album-card" @click="openFolder(album)">
              <span class="photo-album-cover"><FolderPlus :size="30" /></span>
              <strong :title="album.name">{{ album.name }}</strong>
              <small>{{ album.shared ? `来自 @${album.ownerUsername} · ${album.canWrite ? '可读写' : '只读'}` : album.shares?.length ? `已共享给 ${album.shares.length} 人` : '照片目录中的文件夹' }}</small>
            </button>
            <div class="timeline-tools folder-album-actions">
              <IsleButton v-if="!album.shared && shareTargetsCount" variant="tonal" size="sm" :disabled="albumBusy" @click="openShare(album)">
                <template #icon><Share2 :size="13" /></template>
                {{ sharingAlbumPath === album.path ? "收起共享" : "共享给家人" }}
              </IsleButton>
              <IsleButton v-if="!album.shared" variant="glass" size="sm" :disabled="albumBusy" @click="deleteFolder(album)">
                <template #icon><Trash2 :size="13" /></template>
                删除空相册
              </IsleButton>
              <IsleButton v-if="album.shared && album.ownerUserId" variant="danger" size="sm" :disabled="albumBusy" @click="removeShare(album, album.memberUserId || 0, album.ownerUserId)">
                退出共享
              </IsleButton>
            </div>
            <div v-if="sharingAlbumPath === album.path && !album.shared" class="album-new folder-album-share-form">
              <AppleSelect v-model="shareMemberId" :options="shareTargetOptions" size="sm" aria-label="选择共享成员" />
              <label class="folder-album-share-check">
                <input v-model="shareCanWrite" type="checkbox" />
                允许上传（计入我的配额）
              </label>
              <IsleButton variant="primary" size="sm" :disabled="albumBusy || !shareMemberId" @click="submitShare(album)">确认共享</IsleButton>
              <span v-for="s in album.shares" :key="s.id" class="folder-album-share-chip">
                @{{ s.memberUsername }}（{{ s.canWrite ? '可写' : '只读' }}）
                <IsleButton variant="danger" size="sm" :disabled="albumBusy" @click="removeShare(album, s.memberUserId)">移除</IsleButton>
              </span>
            </div>
          </div>
        </div>
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
            <img v-if="album.coverAssetId && !failedAlbumCovers['personal:' + album.id]" :src="mediaPath('/api/v2/photos/' + album.coverAssetId + '/thumbnail')" :alt="album.name + '封面'" loading="lazy" decoding="async" @error="markCoverError('personal:' + album.id)" />
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
            <img v-if="album.coverAssetId && !failedAlbumCovers['shared:' + album.id]" :src="mediaPath('/api/v2/photos/' + album.coverAssetId + '/thumbnail')" :alt="album.name + '封面'" loading="lazy" decoding="async" @error="markCoverError('shared:' + album.id)" />
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
  display: flex;
  flex-direction: column;
}
.folder-album-actions {
  margin-top: 8px;
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
}
.folder-album-share-form {
  margin-top: 8px;
  flex-wrap: wrap;
  gap: 8px;
}
.folder-album-share-check,
.folder-album-share-chip {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 12px;
}
</style>
