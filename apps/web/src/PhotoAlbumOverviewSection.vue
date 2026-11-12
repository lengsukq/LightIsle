<script setup lang="ts">
import { FolderPlus, Images, RefreshCw, Share2, Trash2, Plus } from "lucide-vue-next";
import AppleSelect from "./AppleSelect.vue";
import IsleCard from "./IsleCard.vue";
import IsleButton from "./IsleButton.vue";
import IsleBanner from "./IsleBanner.vue";
import IsleEmpty from "./IsleEmpty.vue";
import type { FolderAlbum } from "./usePhotoFilterAndSharing.ts";

interface LegacyAlbumItem {
  id: number;
  name: string;
  count: number;
  coverAssetId?: number;
}

defineProps<{
  admin: boolean;
  folderAlbums: FolderAlbum[];
  folderCursor: string;
  folderError: string;
  folderLoading: boolean;
  folderName: string;
  albumBusy: boolean;
  shareTargetsCount: number;
  sharingAlbumPath: string;
  shareMemberId: number;
  shareCanWrite: boolean;
  shareTargetOptions: Array<{ value: number; label: string }>;
  privateAlbums: LegacyAlbumItem[];
  privateAlbumsError: string;
  privateAlbumsLoading: boolean;
  albums: LegacyAlbumItem[];
  sharedAlbumsError: string;
  sharedAlbumsLoading: boolean;
  failedAlbumCovers: Record<string, boolean>;
  mediaPath: (path: string) => string;
}>();

const emit = defineEmits<{
  (e: "update:folderName", v: string): void;
  (e: "update:shareMemberId", v: number): void;
  (e: "update:shareCanWrite", v: boolean): void;
  (e: "refresh-folders", more?: boolean): void;
  (e: "create-folder"): void;
  (e: "open-folder", album: FolderAlbum): void;
  (e: "open-share", album: FolderAlbum): void;
  (e: "delete-folder", album: FolderAlbum): void;
  (e: "submit-share", album: FolderAlbum): void;
  (e: "remove-share", album: FolderAlbum, memberId: number, ownerId?: number): void;
  (e: "refresh-private"): void;
  (e: "refresh-shared"): void;
  (e: "open-legacy", album: LegacyAlbumItem, isPrivate: boolean): void;
  (e: "cover-error", key: string): void;
}>();
</script>

<template>
  <section class="photo-album-overview settings-stack" aria-label="相册总览">
    <IsleCard
      title="照片目录中的文件夹相册"
      subtitle="文件夹相册直接保存在你的照片目录中，加入照片时可选择复制或移动，并支持共享给家庭成员。"
    >
      <template #icon><FolderPlus :size="18" /></template>
      <template #actions>
        <IsleButton variant="glass" size="sm" :loading="folderLoading" @click="emit('refresh-folders')">
          <template #icon><RefreshCw :size="14" /></template>
          刷新
        </IsleButton>
      </template>

      <div class="album-overview-stack">
        <form class="album-new" @submit.prevent="emit('create-folder')">
          <FolderPlus :size="18" />
          <input
            :value="folderName"
            maxlength="120"
            aria-label="文件夹相册名称"
            placeholder="输入新文件夹相册名称…"
            required
            @input="emit('update:folderName', ($event.target as HTMLInputElement).value)"
          />
          <IsleButton type="submit" variant="primary" size="sm" :disabled="albumBusy">
            <template #icon><Plus :size="14" /></template>
            新建相册
          </IsleButton>
        </form>

        <IsleBanner v-if="folderError" type="error" compact role="alert" :message="'文件夹相册读取失败：' + folderError">
          <template #action>
            <IsleButton variant="ghost" size="sm" @click="emit('refresh-folders')">重试</IsleButton>
          </template>
        </IsleBanner>

        <div v-if="folderAlbums.length" class="photo-album-card-grid">
          <div v-for="album in folderAlbums" :key="album.path" class="folder-album-cell">
            <button type="button" class="photo-album-card" @click="emit('open-folder', album)">
              <span class="photo-album-cover"><FolderPlus :size="30" /></span>
              <strong :title="album.name">{{ album.name }}</strong>
              <small>{{ album.shared ? `来自 @${album.ownerUsername} · ${album.canWrite ? '可读写' : '只读'}` : album.shares?.length ? `已共享给 ${album.shares.length} 人` : '照片目录中的文件夹' }}</small>
            </button>
            <div class="timeline-tools" style="margin-top: 8px; display: flex; gap: 6px; flex-wrap: wrap">
              <IsleButton v-if="!album.shared && shareTargetsCount" variant="tonal" size="sm" :disabled="albumBusy" @click="emit('open-share', album)">
                <template #icon><Share2 :size="13" /></template>
                {{ sharingAlbumPath === album.path ? "收起共享" : "共享给家人" }}
              </IsleButton>
              <IsleButton v-if="!album.shared" variant="glass" size="sm" :disabled="albumBusy" @click="emit('delete-folder', album)">
                <template #icon><Trash2 :size="13" /></template>
                删除空相册
              </IsleButton>
              <IsleButton v-if="album.shared && album.ownerUserId" variant="danger" size="sm" :disabled="albumBusy" @click="emit('remove-share', album, album.memberUserId || 0, album.ownerUserId)">
                退出共享
              </IsleButton>
            </div>
            <div v-if="sharingAlbumPath === album.path && !album.shared" class="album-new" style="margin-top: 8px; flex-wrap: wrap; gap: 8px">
              <AppleSelect :model-value="shareMemberId" :options="shareTargetOptions" size="sm" aria-label="选择共享成员" @update:model-value="emit('update:shareMemberId', Number($event))" />
              <label style="display: inline-flex; align-items: center; gap: 6px; font-size: 12px">
                <input type="checkbox" :checked="shareCanWrite" @change="emit('update:shareCanWrite', ($event.target as HTMLInputElement).checked)" />
                允许上传（计入我的配额）
              </label>
              <IsleButton variant="primary" size="sm" :disabled="albumBusy || !shareMemberId" @click="emit('submit-share', album)">确认共享</IsleButton>
              <span v-for="s in album.shares" :key="s.id" style="display: inline-flex; align-items: center; gap: 6px; font-size: 12px">
                @{{ s.memberUsername }}（{{ s.canWrite ? '可写' : '只读' }}）
                <IsleButton variant="danger" size="sm" :disabled="albumBusy" @click="emit('remove-share', album, s.memberUserId)">移除</IsleButton>
              </span>
            </div>
          </div>
        </div>
        <IsleEmpty v-else-if="!folderError && !folderLoading && !folderCursor" compact :icon="Images" description="照片目录中还没有文件夹相册。" />
        <div v-if="folderCursor">
          <IsleButton variant="glass" size="sm" :loading="folderLoading" @click="emit('refresh-folders', true)">加载更多文件夹</IsleButton>
        </div>
      </div>
    </IsleCard>

    <IsleCard
      :title="`旧版私人相册 (${privateAlbums.length})`"
      subtitle="仅当前账号可见，保留原有照片收藏集关联。"
    >
      <template #icon><Images :size="18" /></template>
      <IsleBanner v-if="privateAlbumsError" type="error" compact role="alert" :message="'私人相册读取失败：' + privateAlbumsError">
        <template #action>
          <IsleButton variant="ghost" size="sm" :loading="privateAlbumsLoading" @click="emit('refresh-private')">重试</IsleButton>
        </template>
      </IsleBanner>
      <div v-if="privateAlbums.length" class="photo-album-card-grid">
        <button v-for="album in privateAlbums" :key="'personal-' + album.id" type="button" class="photo-album-card" @click="emit('open-legacy', album, true)">
          <span class="photo-album-cover">
            <img v-if="album.coverAssetId && !failedAlbumCovers['personal:' + album.id]" :src="mediaPath('/api/v2/photos/' + album.coverAssetId + '/thumbnail')" :alt="album.name + '封面'" loading="lazy" @error="emit('cover-error', 'personal:' + album.id)" />
            <Images v-else :size="30" />
          </span>
          <strong :title="album.name">{{ album.name }}</strong><small>{{ album.count }} 项 · 仅自己可见</small>
        </button>
      </div>
      <IsleEmpty v-else-if="!privateAlbumsError" compact :icon="Images" description="还没有私人相册。创建后可将照片加入个人收藏集。" />
    </IsleCard>

    <IsleCard
      :title="`旧版共享相册 (${albums.length})`"
      subtitle="家庭成员共同浏览的精选相册。"
    >
      <template #icon><Images :size="18" /></template>
      <IsleBanner v-if="sharedAlbumsError" type="error" compact role="alert" :message="'共享相册读取失败：' + sharedAlbumsError">
        <template #action>
          <IsleButton variant="ghost" size="sm" :loading="sharedAlbumsLoading" @click="emit('refresh-shared')">重试</IsleButton>
        </template>
      </IsleBanner>
      <div v-if="albums.length" class="photo-album-card-grid">
        <button v-for="album in albums" :key="'shared-' + album.id" type="button" class="photo-album-card" @click="emit('open-legacy', album, false)">
          <span class="photo-album-cover">
            <img v-if="album.coverAssetId && !failedAlbumCovers['shared:' + album.id]" :src="mediaPath('/api/v2/photos/' + album.coverAssetId + '/thumbnail')" :alt="album.name + '封面'" loading="lazy" @error="emit('cover-error', 'shared:' + album.id)" />
            <Images v-else :size="30" />
          </span>
          <strong :title="album.name">{{ album.name }}</strong><small>{{ album.count }} 项 · 共享</small>
        </button>
      </div>
      <IsleEmpty v-else-if="!sharedAlbumsError" compact :icon="Images" :description="admin ? '还没有共享相册，可以创建一个与家人共享。' : '管理员创建的共享相册会显示在这里。'" />
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
</style>
