<script setup lang="ts">
import { ref, watch } from "vue";
import { ExternalLink, RotateCcw, Store } from "lucide-vue-next";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleModal from "../../components/ui/IsleModal.vue";
import type { AppStoreConfigPayload, AppStoreSnapshot } from "../../types/appsCenter.ts";

const MIRROR_PRESETS = [
  { label: "直连 GitHub", value: "" },
  { label: "ghfast.top 镜像", value: "https://ghfast.top/" },
  { label: "gh-proxy.com 镜像", value: "https://gh-proxy.com/" },
] as const;

const props = defineProps<{
  open: boolean;
  store: AppStoreSnapshot | null;
  loading: boolean;
}>();

const emit = defineEmits<{
  (e: "close"): void;
  (e: "save", payload: AppStoreConfigPayload): void;
}>();

const draftRegistryUrl = ref("");
const draftMirrorPrefix = ref("");

watch(
  () => props.open,
  (isOpen) => {
    if (!isOpen) return;
    draftRegistryUrl.value = props.store?.isOfficial ? "" : (props.store?.registryUrl || "");
    draftMirrorPrefix.value = props.store?.mirrorPrefix || "";
  },
  { immediate: true },
);

function submit() {
  emit("save", {
    registryUrl: draftRegistryUrl.value.trim(),
    mirrorPrefix: draftMirrorPrefix.value.trim(),
  });
  emit("close");
}

function resetDefault() {
  draftRegistryUrl.value = "";
  draftMirrorPrefix.value = "";
  emit("save", { registryUrl: "", mirrorPrefix: "", resetDefault: true });
  emit("close");
}
</script>

<template>
  <IsleModal
    v-if="open"
    title="在线插件商店源设置"
    description="配置官方 Git 仓库地址或国内 HTTPS 镜像前缀；下载所有插件包均会强制校验 SHA-256。"
    size="md"
    @close="emit('close')"
  >
    <template #icon><Store :size="16" /></template>

    <div class="store-config-form">
      <div class="store-config-field">
        <label for="store-registry-url">Git 商店索引地址（留空使用官方默认源）</label>
        <input
          id="store-registry-url"
          v-model="draftRegistryUrl"
          type="url"
          class="store-config-input"
          :placeholder="store?.defaultUrl || 'https://raw.githubusercontent.com/lengsukq/LightIsle/main/plugins-store/registry.json'"
        />
        <small class="store-config-hint">
          支持任意公开 HTTPS Git 仓库的 <code>registry.json</code>（自定义第三方源安装的插件需管理员确认激活）。
        </small>
      </div>

      <div class="store-config-field">
        <label for="store-mirror-prefix">GitHub 加速镜像前缀（选填）</label>
        <div class="store-mirror-presets">
          <button
            v-for="preset in MIRROR_PRESETS"
            :key="preset.label"
            type="button"
            class="store-preset-chip"
            :class="{ active: draftMirrorPrefix.trim() === preset.value }"
            @click="draftMirrorPrefix = preset.value"
          >
            {{ preset.label }}
          </button>
        </div>
        <input
          id="store-mirror-prefix"
          v-model="draftMirrorPrefix"
          type="url"
          class="store-config-input"
          placeholder="例如 https://ghfast.top/（仅对 GitHub Raw 地址生效）"
        />
      </div>

      <div v-if="store?.repositoryUrl" class="store-repo-link-row">
        <span>当前商店源码仓库：</span>
        <a :href="store.repositoryUrl" target="_blank" rel="noopener noreferrer">
          {{ store.repositoryUrl }}
          <ExternalLink :size="12" aria-hidden="true" />
        </a>
      </div>
    </div>

    <template #footer>
      <IsleButton variant="ghost" size="sm" @click="resetDefault">
        <template #icon><RotateCcw :size="13" /></template>
        恢复官方默认
      </IsleButton>
      <div class="store-modal-footer-right">
        <IsleButton variant="glass" size="sm" @click="emit('close')">取消</IsleButton>
        <IsleButton variant="primary" size="sm" :loading="loading" @click="submit">
          保存并刷新商店
        </IsleButton>
      </div>
    </template>
  </IsleModal>
</template>

<style scoped>
.store-config-form {
  display: grid;
  gap: 14px;
}

.store-config-field {
  display: grid;
  gap: 6px;
}

.store-config-field label {
  font-size: 12.5px;
  font-weight: 620;
  color: var(--text-primary);
}

.store-config-input {
  width: 100%;
  box-sizing: border-box;
  padding: 9px 12px;
  border-radius: 10px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-bottom);
  color: var(--text-primary);
  font: inherit;
  font-size: 12.5px;
  outline: none;
  transition: border-color 150ms ease, box-shadow 150ms ease;
}

.store-config-input:focus {
  border-color: var(--accent-primary);
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent-primary) 16%, transparent);
}

.store-config-hint {
  font-size: 11.5px;
  color: var(--text-secondary);
  line-height: 1.45;
}

.store-mirror-presets {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
}

.store-preset-chip {
  padding: 4px 10px;
  border-radius: 999px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  color: var(--text-secondary);
  font: inherit;
  font-size: 11.5px;
  font-weight: 580;
  cursor: pointer;
  transition: border-color 140ms ease, background-color 140ms ease, color 140ms ease;
}

.store-preset-chip.active {
  border-color: var(--accent-primary);
  background: color-mix(in srgb, var(--accent-primary) 12%, transparent);
  color: var(--accent-primary);
}

.store-repo-link-row {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
  font-size: 12px;
  color: var(--text-secondary);
}

.store-repo-link-row a {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  color: var(--accent-primary);
  text-decoration: none;
  overflow-wrap: anywhere;
}

.store-repo-link-row a:hover {
  text-decoration: underline;
}

.store-modal-footer-right {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-left: auto;
}

@media (prefers-reduced-motion: reduce) {
  .store-config-input,
  .store-preset-chip {
    transition: none;
  }
}
</style>
