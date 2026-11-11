<script setup lang="ts">
import { FolderPlus, Images } from "lucide-vue-next";
import AppleSelect from "./AppleSelect.vue";
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
  <section class="photo-album-overview" aria-label="相册总览">
    <header class="photo-album-overview-header">
      <div><h3>整理与分享</h3><p>文件夹相册直接保存在你的照片目录中，加入照片时可选择复制或移动。</p></div>
    </header>
    <div class="photo-album-section-heading">
      <h4>照片目录中的相册</h4>
      <button type="button" class="refresh" :disabled="folderLoading" @click="emit('refresh-folders')">刷新</button>
    </div>
    <form class="album-new" @submit.prevent="emit('create-folder')">
      <FolderPlus :size="18" />
      <input
        :value="folderName"
        maxlength="120"
        aria-label="文件夹相册名称"
        placeholder="新相册名称"
        required
        @input="emit('update:folderName', ($event.target as HTMLInputElement).value)"
      />
      <button type="submit" :disabled="albumBusy">新建相册</button>
    </form>
    <div v-if="folderError" class="gallery-message" role="alert">
      文件夹相册读取失败：{{ folderError }}
      <button type="button" class="refresh" @click="emit('refresh-folders')">重试</button>
    </div>
    <div v-if="folderAlbums.length" class="photo-album-card-grid">
      <div v-for="album in folderAlbums" :key="album.path">
        <button type="button" class="photo-album-card" @click="emit('open-folder', album)">
          <span class="photo-album-cover"><FolderPlus :size="30" /></span>
          <strong :title="album.name">{{ album.name }}</strong>
          <small>{{ album.shared ? `来自 @${album.ownerUsername} · ${album.canWrite ? '可读写' : '只读'}` : album.shares?.length ? `已共享给 ${album.shares.length} 人` : '照片目录中的文件夹' }}</small>
        </button>
        <div class="timeline-tools" style="margin-top:6px">
          <button v-if="!album.shared && shareTargetsCount" type="button" class="refresh" :disabled="albumBusy" @click="emit('open-share', album)">
            {{ sharingAlbumPath === album.path ? "收起共享" : "共享给家人" }}
          </button>
          <button v-if="!album.shared" type="button" class="refresh" :disabled="albumBusy" @click="emit('delete-folder', album)">删除空相册</button>
          <button v-if="album.shared && album.ownerUserId" type="button" class="refresh" :disabled="albumBusy" @click="emit('remove-share', album, album.memberUserId || 0, album.ownerUserId)">退出共享</button>
        </div>
        <div v-if="sharingAlbumPath === album.path && !album.shared" class="album-new" style="margin-top:6px;flex-wrap:wrap">
          <AppleSelect :model-value="shareMemberId" :options="shareTargetOptions" size="sm" aria-label="选择共享成员" @update:model-value="emit('update:shareMemberId', Number($event))" />
          <label style="display:inline-flex;align-items:center;gap:4px;font-size:12px">
            <input type="checkbox" :checked="shareCanWrite" @change="emit('update:shareCanWrite', ($event.target as HTMLInputElement).checked)" />
            允许上传（计入我的配额）
          </label>
          <button type="button" :disabled="albumBusy || !shareMemberId" @click="emit('submit-share', album)">确认共享</button>
          <span v-for="s in album.shares" :key="s.id" style="display:inline-flex;align-items:center;gap:4px;font-size:12px">
            @{{ s.memberUsername }}（{{ s.canWrite ? '可写' : '只读' }}）
            <button type="button" class="refresh" :disabled="albumBusy" @click="emit('remove-share', album, s.memberUserId)">移除</button>
          </span>
        </div>
      </div>
    </div>
    <IsleEmpty v-else-if="!folderError && !folderLoading && !folderCursor" compact :icon="Images" description="照片目录中还没有文件夹相册。" />
    <button v-if="folderCursor" type="button" class="refresh" :disabled="folderLoading" @click="emit('refresh-folders', true)">加载更多文件夹</button>

    <div v-if="privateAlbumsError" class="gallery-message" role="alert">
      私人相册读取失败：{{ privateAlbumsError }}
      <button type="button" class="refresh" :disabled="privateAlbumsLoading" @click="emit('refresh-private')">重试</button>
    </div>
    <div class="photo-album-section-heading"><h4>旧版私人相册 ({{ privateAlbums.length }})</h4><small>保留原有照片关联</small></div>
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

    <div class="photo-album-section-heading"><h4>旧版共享相册 ({{ albums.length }})</h4><small>保留原有照片关联</small></div>
    <div v-if="sharedAlbumsError" class="gallery-message" role="alert">
      共享相册读取失败：{{ sharedAlbumsError }}
      <button type="button" class="refresh" :disabled="sharedAlbumsLoading" @click="emit('refresh-shared')">重试</button>
    </div>
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
  </section>
</template>
