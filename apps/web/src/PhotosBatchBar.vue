<script setup lang="ts">
import { ref } from "vue";
import { Trash2, Share2, Download, FolderPlus, CheckSquare, X } from "lucide-vue-next";
import AppleSelect from "./AppleSelect.vue";

defineProps<{
  selecting: boolean;
  busy: boolean;
  selectedCount: number;
  totalLoaded: number;
  folderTarget: string;
  folderOptions: Array<{ value: string | number; label: string; disabled?: boolean }>;
  hasFolderAlbums: boolean;
  folderCursor: string;
  folderLoading: boolean;
  folderError: string;
  privateAlbum: number;
  privateAlbumOptions: Array<{ value: string | number; label: string; disabled?: boolean }>;
  hasPrivateAlbums: boolean;
  shareLinks: Array<{ name: string; url: string }>;
  shareNotice: string;
}>();

const emit = defineEmits<{
  (e: "selectTop50"): void;
  (e: "clearSelection"): void;
  (e: "exitSelecting"): void;
  (e: "trashSelected"): void;
  (e: "batchShare"): void;
  (e: "batchDownload"): void;
  (e: "update:folderTarget", value: string): void;
  (e: "batchFolder", mode: "copy" | "move"): void;
  (e: "loadMoreFolders"): void;
  (e: "retryFolders"): void;
  (e: "update:privateAlbum", value: number): void;
  (e: "batchPrivateAlbum"): void;
  (e: "copyShareLinks"): void;
  (e: "closeShareLinks"): void;
}>();

const albumPickerOpen = ref(false);
</script>

<template>
  <div v-if="shareLinks.length" class="photo-batch-links" role="region" aria-label="已创建的分享链接">
    <p>已创建 {{ shareLinks.length }} 条公开链接，有效期 24 小时。链接只在本次显示；可在文件管理的分享列表中撤销。</p>
    <textarea
      readonly
      :value="shareLinks.map(item => `${item.name}：${item.url}`).join('\n')"
      rows="4"
      aria-label="分享链接列表"
      @focus="($event.target as HTMLTextAreaElement).select()"
    ></textarea>
    <div>
      <button type="button" class="album-create" @click="emit('copyShareLinks')">复制全部链接</button>
      <button type="button" class="refresh" @click="emit('closeShareLinks')">关闭</button>
      <span v-if="shareNotice" role="status">{{ shareNotice }}</span>
    </div>
  </div>

  <div v-if="selecting" class="photo-batch-hud" role="toolbar" aria-label="照片批量操作">
    <div class="photo-batch-hud-main">
      <span class="photo-batch-count">已选 {{ selectedCount }} 项<small>（上限 50）</small></span>
      <button type="button" class="photo-batch-btn" :disabled="busy || !totalLoaded" @click="emit('selectTop50')">
        <CheckSquare :size="14" /> 选前 50 项
      </button>
      <button v-if="selectedCount" type="button" class="photo-batch-btn" :disabled="busy" @click="emit('clearSelection')">
        清空
      </button>
      <button
        type="button"
        class="photo-batch-btn"
        :class="{ chosen: albumPickerOpen }"
        :disabled="busy"
        @click="albumPickerOpen = !albumPickerOpen"
      >
        <FolderPlus :size="14" /> 整理到相册
      </button>
      <button type="button" class="photo-batch-btn" :disabled="busy || !selectedCount" @click="emit('batchShare')">
        <Share2 :size="14" /> 分享
      </button>
      <button type="button" class="photo-batch-btn" :disabled="busy || !selectedCount" @click="emit('batchDownload')">
        <Download :size="14" /> 下载
      </button>
      <button type="button" class="photo-batch-btn danger" :disabled="busy || !selectedCount" @click="emit('trashSelected')">
        <Trash2 :size="14" /> 移入回收站
      </button>
      <button type="button" class="photo-batch-btn close" :disabled="busy" @click="albumPickerOpen = false; emit('exitSelecting')">
        <X :size="14" /> 完成
      </button>
    </div>

    <div v-if="albumPickerOpen" class="photo-batch-hud-drawer">
      <div class="photo-batch-group">
        <span>文件夹相册</span>
        <AppleSelect
          :model-value="folderTarget"
          :options="folderOptions"
          size="sm"
          :disabled="busy || !hasFolderAlbums"
          aria-label="批量操作的文件夹相册"
          @update:model-value="emit('update:folderTarget', String($event ?? ''))"
        />
        <button type="button" class="photo-batch-btn primary" :disabled="busy || !selectedCount || !folderTarget" @click="emit('batchFolder', 'copy')">
          复制到相册
        </button>
        <button type="button" class="photo-batch-btn" :disabled="busy || !selectedCount || !folderTarget" @click="emit('batchFolder', 'move')">
          移动到相册
        </button>
        <button v-if="folderCursor" type="button" class="photo-batch-btn" :disabled="folderLoading || busy" @click="emit('loadMoreFolders')">
          更多相册
        </button>
        <button v-if="folderError" type="button" class="photo-batch-btn danger" :disabled="folderLoading || busy" @click="emit('retryFolders')">
          重试读取相册
        </button>
      </div>
      <div v-if="hasPrivateAlbums" class="photo-batch-group">
        <span>旧版私人相册</span>
        <AppleSelect
          :model-value="privateAlbum"
          :options="privateAlbumOptions"
          size="sm"
          :disabled="busy"
          aria-label="批量加入已有私人相册"
          @update:model-value="emit('update:privateAlbum', Number($event ?? 0))"
        />
        <button type="button" class="photo-batch-btn" :disabled="busy || !selectedCount || !privateAlbum" @click="emit('batchPrivateAlbum')">
          加入私人相册
        </button>
      </div>
    </div>
  </div>
</template>
