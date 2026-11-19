<script setup lang="ts">
import { Pencil } from "lucide-vue-next";
import IsleBanner from "./IsleBanner.vue";
import IsleButton from "./IsleButton.vue";
import IsleModal from "./IsleModal.vue";

defineProps<{
  open: boolean;
  renameTitle: string;
  renameBusy: boolean;
  renameError: string;
}>();

const emit = defineEmits<{
  (e: "close"): void;
  (e: "submit"): void;
  (e: "update:renameTitle", val: string): void;
}>();
</script>

<template>
  <IsleModal
    :open="open"
    title="修改影片展示名称"
    description="仅更新轻屿影片库展示标题，不改动原始视频文件名。"
    size="sm"
    :close-on-backdrop="!renameBusy"
    :close-on-esc="!renameBusy"
    :show-close="!renameBusy"
    @close="emit('close')"
  >
    <template #icon><Pencil :size="16" /></template>
    <IsleBanner v-if="renameError" type="error" compact :message="renameError" style="margin-bottom: 10px" />
    <form id="cinema-rename-form" class="cinema-rename-form" @submit.prevent="emit('submit')">
      <label>
        <span>展示名称</span>
        <input
          :value="renameTitle"
          type="text"
          maxlength="200"
          required
          autofocus
          :disabled="renameBusy"
          placeholder="输入影片展示名称"
          @input="emit('update:renameTitle', ($event.target as HTMLInputElement).value)"
        />
      </label>
    </form>
    <template #footer>
      <div style="display:flex;justify-content:flex-end;gap:8px;width:100%">
        <IsleButton variant="glass" :disabled="renameBusy" @click="emit('close')">取消</IsleButton>
        <IsleButton type="submit" form="cinema-rename-form" variant="primary" :loading="renameBusy">保存名称</IsleButton>
      </div>
    </template>
  </IsleModal>
</template>

<style scoped>
.cinema-rename-form label {
  display: grid;
  gap: 5px;
  font-size: 12px;
  font-weight: 600;
  color: var(--text-secondary);
}
.cinema-rename-form input {
  width: 100%;
  height: 35px;
  box-sizing: border-box;
  border: 1px solid var(--fluid-card-border);
  border-radius: 9px;
  background: var(--fluid-card-item-fill);
  color: var(--text-primary);
  padding: 0 11px;
  font-size: 13px;
  outline: none;
}
.cinema-rename-form input:focus {
  border-color: var(--accent-primary, #2563eb);
}
</style>
