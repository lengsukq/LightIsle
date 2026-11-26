<script setup lang="ts">
import { inject } from "vue";
import { ChevronDown } from "lucide-vue-next";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import { PHOTO_VIEWER_CTX } from "../../contexts/photosContext.ts";

const ctx = inject(PHOTO_VIEWER_CTX);
if (!ctx) throw new Error("PhotoViewerAlbumDrawer requires PHOTO_VIEWER_CTX");

const {
  selected, admin, canWrite, folderAlbums, folderAlbumOptions, folderTarget,
  albums, albumOptions, addAlbum, activeAlbum, sharedAlbumsError, sharedAlbumsLoading,
  privateAlbums, privateAlbumOptions, addPrivateAlbum, activePrivateAlbum,
  privateAlbumsError, privateAlbumsLoading, albumBusy,
  folderAction, addShared, removeShared, retryShared, addPrivate, removePrivate, retryPrivate,
} = ctx;
</script>

<template>
  <div class="gallery-modal-footer gallery-modal-footer--obsidian">
    <div v-if="folderAlbums.length" class="private-album-picker">
      <span>文件夹相册</span>
      <AppleSelect v-model="folderTarget" :options="folderAlbumOptions" size="sm" aria-label="选择文件夹相册" />
      <button type="button" :disabled="!folderTarget || albumBusy" @click="folderAction('copy')">复制到相册</button>
      <button type="button" :disabled="!folderTarget || albumBusy || !canWrite" @click="folderAction('move')">移动到相册</button>
    </div>
    <span v-else class="private-album-hint">可在相册页新建「文件夹相册」，以真实目录整理照片。</span>

    <div v-if="admin && albums.length" class="private-album-picker">
      <span>旧版共享相册</span>
      <AppleSelect v-model="addAlbum" :options="albumOptions" size="sm" aria-label="选择相册" />
      <button type="button" :disabled="!addAlbum || albumBusy" @click="addShared()">加入 <ChevronDown :size="13" /></button>
      <button v-if="activeAlbum" type="button" class="album-remove-photo" :disabled="albumBusy" @click="removeShared()">从相册移出（保留原片）</button>
    </div>
    <div v-if="sharedAlbumsError && selected" class="gallery-modal-feedback" role="alert">
      共享相册读取失败：{{ sharedAlbumsError }}
      <button type="button" class="refresh" :disabled="sharedAlbumsLoading" @click="retryShared()">{{ sharedAlbumsLoading ? "正在重试…" : "重试" }}</button>
    </div>

    <div v-if="privateAlbums.length" class="private-album-picker">
      <span>旧版私人相册</span>
      <AppleSelect v-model="addPrivateAlbum" :options="privateAlbumOptions" size="sm" aria-label="选择我的私人相册" />
      <button type="button" :disabled="!addPrivateAlbum || albumBusy" @click="addPrivate()">加入 <ChevronDown :size="13" /></button>
    </div>
    <span v-else-if="privateAlbumsError && selected" class="private-album-hint" role="alert">
      私人相册读取失败：{{ privateAlbumsError }}
      <button type="button" class="refresh" :disabled="privateAlbumsLoading" @click="retryPrivate()">{{ privateAlbumsLoading ? "正在重试…" : "重试" }}</button>
    </span>

    <button v-if="activePrivateAlbum" type="button" class="album-remove-photo" :disabled="albumBusy" @click="removePrivate()">从相册移出（保留原片）</button>
  </div>
</template>

<style scoped>
.gallery-modal-footer.gallery-modal-footer--obsidian {
  display: flex;
  align-items: center;
  justify-content: flex-start;
  flex-wrap: wrap;
  gap: 8px 14px;
  padding: 10px 18px;
  border-top: 1px solid rgba(255, 255, 255, 0.08);
  color: rgba(245, 245, 247, 0.86);
}
.private-album-picker {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
  color: rgba(245, 245, 247, 0.82);
  font-size: 12px;
}
.private-album-picker > span {
  font-weight: 650;
}
.gallery-modal-footer--obsidian button {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  border-radius: 9px;
  border: 1px solid rgba(255, 255, 255, 0.16);
  background: rgba(255, 255, 255, 0.12);
  color: #f5f5f7;
  font-size: 11.5px;
  font-weight: 600;
  padding: 5px 10px;
  cursor: pointer;
}
.gallery-modal-footer--obsidian button:hover:not(:disabled) {
  background: rgba(255, 255, 255, 0.22);
}
.gallery-modal-footer--obsidian button:disabled {
  opacity: 0.45;
  cursor: wait;
}
.gallery-modal-footer--obsidian .album-remove-photo {
  background: rgba(255, 255, 255, 0.08);
  color: rgba(245, 245, 247, 0.88);
}
.private-album-hint {
  color: rgba(245, 245, 247, 0.68);
  font-size: 12px;
  line-height: 1.5;
}
.gallery-modal-feedback {
  margin: 0;
  color: #fca5a5;
  font-size: 12px;
}
@media (max-width: 780px) {
  .gallery-modal-footer.gallery-modal-footer--obsidian {
    max-height: min(26dvh, 210px);
    overflow: auto;
    padding: 8px 12px;
  }
}
</style>
