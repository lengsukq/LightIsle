<script setup lang="ts">
import { inject } from "vue";
import { Images } from "lucide-vue-next";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { PHOTO_TIMELINE_CTX } from "../../contexts/photosContext.ts";

defineProps<{
  admin: boolean;
  loading: boolean;
  galleryLoaded: boolean;
  loadError: string;
  scanActionError: string;
  scanStatusError: string;
  scanStatusLoaded: boolean;
  scanStatusLoading: boolean;
  scanRunning: boolean;
  scanLastError?: string;
  rootName?: string;
  hasOtherRoots?: boolean;
}>();

const ctx = inject(PHOTO_TIMELINE_CTX)!;
const {
  searchApplied, activeFolderAlbum, currentPrivateAlbum, currentAlbum,
  isOnThisDay, personalOnly, favoritesOnly, typeFilter, selectAll,
} = ctx;

const emit = defineEmits<{
  (e: "retry-load"): void;
  (e: "retry-status"): void;
  (e: "start-scan"): void;
}>();
</script>

<template>
  <IsleEmpty
    v-if="loadError || scanActionError || scanStatusError || (scanStatusLoaded && scanLastError)"
    :icon="Images"
    :icon-size="44"
    :title="loadError ? '暂时无法读取图库' : scanActionError ? '扫描无法启动' : scanStatusError ? '无法确认扫描状态' : '上次扫描未完成'"
    :description="loadError || scanActionError || (scanStatusError ? '扫描状态暂不可用：' + scanStatusError : '上次扫描未完成：' + describeUserFacingError(scanLastError || ''))"
    role="alert"
  >
    <template #action>
      <IsleButton v-if="loadError" variant="tonal" size="sm" :disabled="loading" @click="emit('retry-load')">重试读取图库</IsleButton>
      <IsleButton v-if="scanStatusError" variant="tonal" size="sm" :disabled="scanStatusLoading" @click="emit('retry-status')">重试读取扫描状态</IsleButton>
      <IsleButton v-if="admin && (!loadError || scanActionError || scanLastError)" variant="tonal" size="sm" :disabled="scanRunning && !scanStatusError" @click="emit('start-scan')">重新扫描</IsleButton>
    </template>
  </IsleEmpty>

  <IsleEmpty
    v-else-if="loading || !galleryLoaded || (!scanStatusLoaded && !scanStatusError) || (scanRunning && !scanStatusError)"
    :icon="Images"
    :icon-size="44"
    :title="scanRunning && !scanStatusError ? '正在扫描媒体…' : !scanStatusLoaded && !scanStatusError ? '正在确认媒体扫描状态…' : '正在读取媒体索引…'"
  />

  <IsleEmpty
    v-else
    :icon="Images"
    :icon-size="44"
    :title="searchApplied ? '没有匹配「' + searchApplied + '」的媒体' : activeFolderAlbum ? '文件夹相册还没有照片' : currentPrivateAlbum ? '私人相册还没有照片' : currentAlbum ? '此相册还没有照片' : isOnThisDay ? '今天还没有那年今天的回忆' : personalOnly ? '还没有个人收藏' : favoritesOnly ? '还没有共享收藏' : typeFilter === 'live' ? '这里还没有实况照片' : typeFilter === 'video' ? '这里还没有视频' : typeFilter === 'photo' ? '这里还没有照片' : rootName ? `当前目录「${rootName}」还没有照片或视频` : '这里还没有照片或视频'"
  >
    <p v-if="activeFolderAlbum">可在文件页放入照片，或在照片预览中复制/移动到此相册。</p>
    <p v-else-if="currentPrivateAlbum">在全部照片中打开预览，选择「加入我的相册」（仅自己可见）。</p>
    <p v-else-if="currentAlbum">在全部照片中打开预览，选择此相册并点击「加入相册」。</p>
    <p v-else-if="isOnThisDay">带拍摄时间的往年同日照片与视频会自动显示在这里。</p>
    <p v-else-if="favoritesOnly">在预览中点击心形收藏，已授权成员可共同浏览。</p>
    <p v-else-if="personalOnly">在预览中点击星标收藏，仅自己可见。</p>
    <p v-else>上传照片或视频后点击「扫描媒体」即可显示。<span v-if="!admin">请联系管理员执行扫描。</span><template v-if="hasOtherRoots"> 若迁移前的照片或相册保存在原存储目录（如旧盘根层或「图库 / PhonePhotos」），原数据未丢失：可在右上角切换存储目录查看，或在 Mac 访达中将原照片放入当前个人相册目录后重新扫描。</template></p>
    <template v-if="activeFolderAlbum || currentAlbum || currentPrivateAlbum || favoritesOnly || personalOnly || isOnThisDay" #action>
      <IsleButton variant="tonal" size="sm" @click="selectAll()">浏览全部照片</IsleButton>
    </template>
  </IsleEmpty>
</template>
