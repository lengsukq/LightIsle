<script setup lang="ts">
import { nextTick, ref, watch } from "vue";
import { FolderPlus, Pencil, Trash2 } from "lucide-vue-next";
import type { PhotoAlbum } from "./usePhotoAlbums.ts";
import type { FolderAlbum } from "./usePhotoFilterAndSharing.ts";

const props = defineProps<{
  admin: boolean;
  albumBusy: boolean;
  selectedOpen: boolean;
  sharedAlbumsError: string;
  sharedAlbumsLoading: boolean;
  privateAlbumsError: string;
  privateAlbumsLoading: boolean;
  activeFolderAlbum: FolderAlbum | null;
  currentPrivateAlbum?: PhotoAlbum | null;
  currentAlbum?: PhotoAlbum | null;
  creatingPrivate: boolean;
  editingPrivate: PhotoAlbum | null;
  creating: boolean;
  editingAlbum: PhotoAlbum | null;
}>();

const privateAlbumName = defineModel<string>("privateAlbumName", { required: true });
const albumName = defineModel<string>("albumName", { required: true });

const emit = defineEmits<{
  (e: "retry-shared"): void;
  (e: "retry-private"): void;
  (e: "back-to-albums"): void;
  (e: "edit-private", album: PhotoAlbum): void;
  (e: "delete-private"): void;
  (e: "save-private"): void;
  (e: "cancel-private"): void;
  (e: "begin-rename", album: PhotoAlbum): void;
  (e: "delete-album"): void;
  (e: "save-album"): void;
  (e: "cancel-album"): void;
}>();

const privateAlbumInputRef = ref<HTMLInputElement | null>(null);
const sharedAlbumInputRef = ref<HTMLInputElement | null>(null);

watch(
  () => props.creatingPrivate,
  (openState) => {
    if (openState) void nextTick(() => { privateAlbumInputRef.value?.focus(); privateAlbumInputRef.value?.select(); });
  },
);
watch(
  () => props.creating,
  (openState) => {
    if (openState) void nextTick(() => { sharedAlbumInputRef.value?.focus(); sharedAlbumInputRef.value?.select(); });
  },
);
</script>

<template>
  <div v-if="sharedAlbumsError && !selectedOpen" class="gallery-message" role="alert">
    共享相册读取失败：{{ sharedAlbumsError }}
    <button type="button" class="refresh" :disabled="sharedAlbumsLoading" @click="emit('retry-shared')">
      {{ sharedAlbumsLoading ? "正在重试…" : "重试共享相册" }}
    </button>
  </div>
  <div v-if="privateAlbumsError && !selectedOpen" class="gallery-message" role="alert">
    私人相册读取失败：{{ privateAlbumsError }}
    <button type="button" class="refresh" :disabled="privateAlbumsLoading" @click="emit('retry-private')">
      {{ privateAlbumsLoading ? "正在重试…" : "重试私人相册" }}
    </button>
  </div>
  <div v-if="activeFolderAlbum" class="album-management">
    <span>文件夹相册：{{ activeFolderAlbum.name }}</span>
    <button type="button" class="refresh" @click="emit('back-to-albums')">返回相册</button>
  </div>
  <div v-if="currentPrivateAlbum" class="album-management">
    <span>我的私人相册：{{ currentPrivateAlbum.name }}（只有当前账号可查看）</span>
    <button type="button" :disabled="albumBusy" @click="emit('edit-private', currentPrivateAlbum)">
      <Pencil :size="14" /> 改名
    </button>
    <button type="button" :disabled="albumBusy" class="album-delete" @click="emit('delete-private')">
      <Trash2 :size="14" /> 删除
    </button>
  </div>
  <form v-if="creatingPrivate" class="album-new" @submit.prevent="emit('save-private')" @keydown.esc.stop="emit('cancel-private')">
    <FolderPlus :size="18" />
    <input ref="privateAlbumInputRef" v-model="privateAlbumName" maxlength="120" aria-label="私人相册名称" placeholder="私人相册名称（最多60个字符）" required />
    <button type="submit" :disabled="albumBusy">{{ albumBusy ? "保存中…" : editingPrivate ? "保存修改" : "创建私人相册" }}</button>
    <button type="button" class="album-cancel" :disabled="albumBusy" @click="emit('cancel-private')">取消</button>
  </form>
  <div v-if="admin && currentAlbum" class="album-management">
    <span>当前相册：{{ currentAlbum.name }}</span>
    <button type="button" :disabled="albumBusy" @click="emit('begin-rename', currentAlbum)">
      <Pencil :size="14" />改名
    </button>
    <button type="button" :disabled="albumBusy" class="album-delete" @click="emit('delete-album')">
      <Trash2 :size="14" />删除相册
    </button>
  </div>
  <form v-if="admin && creating" class="album-new" @submit.prevent="emit('save-album')" @keydown.esc.stop="emit('cancel-album')">
    <FolderPlus :size="18" />
    <input ref="sharedAlbumInputRef" v-model="albumName" maxlength="120" aria-label="相册名称，最多60个字符" placeholder="相册名称（最多60个字符）" required />
    <button type="submit" :disabled="albumBusy">{{ albumBusy ? "保存中…" : editingAlbum ? "保存修改" : "创建" }}</button>
    <button type="button" class="album-cancel" :disabled="albumBusy" @click="emit('cancel-album')">取消</button>
  </form>
</template>
