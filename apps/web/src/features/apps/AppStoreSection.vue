<script setup lang="ts">
import { computed, ref, watch } from "vue";
import {
  ArrowUpCircle,
  Check,
  ChevronDown,
  ChevronUp,
  Download,
  Package,
  RefreshCcw,
  Settings2,
  Store,
} from "lucide-vue-next";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleChip from "../../components/ui/IsleChip.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleSearchInput from "../../components/ui/IsleSearchInput.vue";
import AppStoreConfigModal from "./AppStoreConfigModal.vue";
import { categoryLabel } from "../../composables/useAppsCenterController.ts";
import { formatDateTime } from "../../utils/dateTimeFormat.ts";
import type {
  AppStorageSnapshot,
  AppStoreConfigPayload,
  AppStorePluginItem,
  AppStoreSnapshot,
} from "../../types/appsCenter.ts";

const props = defineProps<{
  store: AppStoreSnapshot | null;
  storeLoading: boolean;
  storeActionPluginId: string;
  storeError: string;
  installedAppsCount: number;
  busy: boolean;
  appStorage: AppStorageSnapshot | null;
  selectedInstallLocationId: string;
  installLocationOptions: Array<{ value: string; label: string; disabled?: boolean }>;
}>();

const emit = defineEmits<{
  (e: "update:selectedInstallLocationId", id: string): void;
  (e: "refresh"): void;
  (e: "install", plugin: AppStorePluginItem): void;
  (e: "upgrade", plugin: AppStorePluginItem): void;
  (e: "save-config", payload: AppStoreConfigPayload): void;
}>();

const manualExpanded = ref<boolean | null>(null);
const storeSearch = ref("");
const storeCategory = ref("all");
const failedStoreIcons = ref<Set<string>>(new Set());
const configModalOpen = ref(false);

const plugins = computed(() => props.store?.plugins ?? []);
const updatableCount = computed(() => plugins.value.filter((p) => p.updateAvailable).length);
const uninstalledCount = computed(() => plugins.value.filter((p) => !p.installed).length);
const expanded = computed(() => {
  if (manualExpanded.value !== null) return manualExpanded.value;
  return props.installedAppsCount === 0 || updatableCount.value > 0;
});

const categories = computed(() => {
  const seen = new Set<string>();
  for (const p of plugins.value) {
    if (p.category) seen.add(p.category);
  }
  return Array.from(seen);
});

watch(categories, (cats) => {
  if (storeCategory.value !== "all" && !cats.includes(storeCategory.value)) {
    storeCategory.value = "all";
  }
});

watch(() => props.store?.registryUrl, () => {
  failedStoreIcons.value = new Set();
});

const filteredPlugins = computed(() => {
  const q = storeSearch.value.trim().toLowerCase();
  return plugins.value.filter((p) => {
    if (storeCategory.value !== "all" && p.category !== storeCategory.value) return false;
    if (!q) return true;
    return (
      p.name.toLowerCase().includes(q) ||
      p.id.toLowerCase().includes(q) ||
      (p.description || "").toLowerCase().includes(q)
    );
  });
});

const fetchedLabel = computed(() => {
  const raw = props.store?.fetchedAt;
  if (!raw) return "";
  const formatted = formatDateTime(raw);
  return formatted ? `同步于 ${formatted.replace(/^.*?\s/, "")}` : "";
});

function formatBytes(size?: number): string {
  if (!size || size <= 0) return "";
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${Math.max(1, Math.round(size / 1024))} KB`;
  return `${(size / (1024 * 1024)).toFixed(1)} MB`;
}

function tagLabel(tag: string): string {
  switch (tag) {
    case "zero-ram": return "纯静态 0 MB";
    case "kv-sync": return "全家共享";
    case "reminders": return "到期提醒";
    case "network": return "网络监测";
    default: return tag;
  }
}

function openConfigModal() {
  configModalOpen.value = true;
}
</script>

<template>
  <section class="store-shell" aria-label="在线插件商店">
    <div class="store-header">
      <div class="store-header-lead">
        <span class="store-header-icon" aria-hidden="true">
          <Store :size="17" />
        </span>
        <div class="store-header-copy">
          <div class="store-header-title">
            <strong>{{ store?.storeName || "在线插件商店" }}</strong>
            <IsleBadge :variant="store?.isOfficial !== false ? 'accent' : 'neutral'" size="sm">
              {{ store?.isOfficial !== false ? "Git 官方源" : "自定义 Git 源" }}
            </IsleBadge>
            <IsleBadge v-if="store?.mirrorPrefix" variant="online" size="sm">已启用镜像加速</IsleBadge>
            <IsleBadge v-if="updatableCount > 0" variant="warning" size="sm" dot>
              {{ updatableCount }} 款可更新
            </IsleBadge>
          </div>
          <p class="store-header-sub store-tabular">
            <template v-if="plugins.length > 0">
              共 {{ plugins.length }} 款可下载插件
              <template v-if="uninstalledCount > 0"> · {{ uninstalledCount }} 款未安装</template>
              <template v-else> · 均已安装</template>
              <template v-if="fetchedLabel"> · {{ fetchedLabel }}</template>
            </template>
            <template v-else-if="storeLoading">正在从 Git 仓库同步插件目录…</template>
            <template v-else>从 Git 仓库按需下载、SHA-256 校验安装与无损升级轻应用</template>
          </p>
        </div>
      </div>

      <div class="store-header-actions">
        <IsleButton
          variant="ghost"
          size="sm"
          :disabled="storeLoading || busy"
          @click="openConfigModal"
        >
          <template #icon><Settings2 :size="14" /></template>
          商店源
        </IsleButton>
        <IsleButton
          variant="glass"
          size="sm"
          :loading="storeLoading"
          :disabled="busy || Boolean(storeActionPluginId)"
          @click="emit('refresh')"
        >
          <template #icon><RefreshCcw :size="14" /></template>
          {{ storeLoading ? "同步中…" : "刷新商店" }}
        </IsleButton>
        <button
          v-if="installedAppsCount > 0"
          type="button"
          class="store-toggle-btn"
          :aria-expanded="expanded"
          @click="manualExpanded = !expanded"
        >
          <span>{{ expanded ? "收起商店" : "展开商店" }}</span>
          <ChevronUp v-if="expanded" :size="14" />
          <ChevronDown v-else :size="14" />
        </button>
      </div>
    </div>

    <div v-if="expanded" class="store-body">
      <IsleBanner
        v-if="storeError || store?.error"
        type="warning"
        compact
        role="status"
      >
        {{ storeError || store?.error }}
        <template #action>
          <IsleButton variant="glass" size="sm" @click="openConfigModal">配置镜像源</IsleButton>
          <IsleButton variant="tonal" size="sm" :loading="storeLoading" @click="emit('refresh')">重试</IsleButton>
        </template>
      </IsleBanner>

      <div v-if="plugins.length > 0" class="store-toolbar">
        <div class="store-toolbar-left">
          <div class="store-cat-pills" role="group" aria-label="商店分类筛选">
            <IsleChip small :selected="storeCategory === 'all'" @select="storeCategory = 'all'">
              全部 ({{ plugins.length }})
            </IsleChip>
            <IsleChip
              v-for="cat in categories"
              :key="cat"
              small
              :selected="storeCategory === cat"
              @select="storeCategory = cat"
            >
              {{ categoryLabel(cat) }}
            </IsleChip>
          </div>
          <div v-if="appStorage && appStorage.locations.length > 1" class="store-target-picker">
            <span>安装到</span>
            <AppleSelect
              :model-value="selectedInstallLocationId"
              :options="installLocationOptions"
              size="sm"
              aria-label="选择商店插件安装位置"
              @update:model-value="emit('update:selectedInstallLocationId', $event)"
            />
          </div>
        </div>
        <IsleSearchInput
          v-if="plugins.length > 4"
          v-model="storeSearch"
          placeholder="搜索商店插件…"
          aria-label="搜索商店插件"
          @clear="storeSearch = ''"
        />
      </div>

      <IsleEmpty
        v-if="!plugins.length && storeLoading"
        compact
        :icon="Store"
        title="正在同步在线插件商店…"
        description="正在拉取 Git 仓库中的插件清单与 SHA-256 校验信息。"
      />
      <IsleEmpty
        v-else-if="!plugins.length"
        compact
        :icon="Store"
        title="暂未拉取到在线商店目录"
        description="点击「刷新商店」从 Git 仓库获取插件列表；若直连 GitHub 较慢，可在「商店源」配置加速镜像。"
      >
        <template #action>
          <IsleButton variant="primary" size="sm" :loading="storeLoading" @click="emit('refresh')">
            <template #icon><RefreshCcw :size="14" /></template>
            立即拉取商店目录
          </IsleButton>
          <IsleButton variant="glass" size="sm" @click="openConfigModal">
            <template #icon><Settings2 :size="14" /></template>
            配置镜像源
          </IsleButton>
        </template>
      </IsleEmpty>
      <IsleEmpty
        v-else-if="!filteredPlugins.length"
        compact
        :icon="Package"
        title="没有匹配的商店插件"
        description="尝试清除分类或搜索关键词。"
      >
        <template #action>
          <IsleButton variant="tonal" size="sm" @click="storeSearch = ''; storeCategory = 'all'">重置筛选</IsleButton>
        </template>
      </IsleEmpty>

      <div v-else class="store-grid">
        <article
          v-for="plugin in filteredPlugins"
          :key="plugin.id"
          class="store-card"
          :class="{ 'has-update': plugin.updateAvailable }"
        >
          <div class="store-card-top">
            <div class="store-card-icon">
              <img
                v-if="plugin.iconUrl && !failedStoreIcons.has(plugin.id)"
                :src="plugin.iconUrl"
                :alt="plugin.name + ' 图标'"
                loading="lazy"
                decoding="async"
                @error="failedStoreIcons.add(plugin.id)"
              />
              <Package v-else :size="20" aria-hidden="true" />
            </div>
            <div class="store-card-heading">
              <div class="store-card-title-row">
                <strong>{{ plugin.name }}</strong>
                <IsleBadge variant="category" size="sm">{{ categoryLabel(plugin.category) }}</IsleBadge>
              </div>
              <span class="store-card-meta store-tabular">
                v{{ plugin.version }}
                <template v-if="formatBytes(plugin.sizeBytes)"> · {{ formatBytes(plugin.sizeBytes) }}</template>
                <template v-if="plugin.installed && plugin.installedVersion && plugin.updateAvailable">
                  · 当前 v{{ plugin.installedVersion }}
                </template>
              </span>
            </div>
          </div>

          <p class="store-card-desc">{{ plugin.description }}</p>

          <div class="store-card-footer">
            <div class="store-card-tags">
              <span
                v-for="tag in (plugin.tags || []).slice(0, 2)"
                :key="tag"
                class="store-tag-pill"
              >
                {{ tagLabel(tag) }}
              </span>
            </div>

            <IsleButton
              v-if="plugin.updateAvailable"
              variant="primary"
              size="sm"
              :loading="storeActionPluginId === plugin.id"
              :disabled="busy || (Boolean(storeActionPluginId) && storeActionPluginId !== plugin.id)"
              @click="emit('upgrade', plugin)"
            >
              <template #icon><ArrowUpCircle :size="14" /></template>
              {{ storeActionPluginId === plugin.id ? "升级中…" : `更新 v${plugin.version}` }}
            </IsleButton>
            <IsleButton
              v-else-if="plugin.installed"
              variant="glass"
              size="sm"
              disabled
            >
              <template #icon><Check :size="13" /></template>
              已安装
            </IsleButton>
            <IsleButton
              v-else
              variant="tonal"
              size="sm"
              :loading="storeActionPluginId === plugin.id"
              :disabled="busy || (Boolean(storeActionPluginId) && storeActionPluginId !== plugin.id)"
              @click="emit('install', plugin)"
            >
              <template #icon><Download :size="14" /></template>
              {{ storeActionPluginId === plugin.id ? "下载中…" : "下载安装" }}
            </IsleButton>
          </div>
        </article>
      </div>
    </div>

    <AppStoreConfigModal
      :open="configModalOpen"
      :store="store"
      :loading="storeLoading"
      @close="configModalOpen = false"
      @save="emit('save-config', $event)"
    />
  </section>
</template>

<style scoped>
.store-tabular {
  font-variant-numeric: tabular-nums;
}

.store-shell {
  border: 1px solid var(--fluid-card-border);
  border-radius: 18px;
  padding: 16px 18px;
  background: var(--fluid-card-fill);
  box-shadow: var(--fluid-card-shadow);
  display: flex;
  flex-direction: column;
  gap: 14px;
}

.store-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px 16px;
  flex-wrap: wrap;
}

.store-header-lead {
  display: flex;
  align-items: center;
  gap: 12px;
  min-width: 0;
  flex: 1 1 260px;
}

.store-header-icon {
  width: 38px;
  height: 38px;
  border-radius: 11px;
  display: grid;
  place-items: center;
  flex-shrink: 0;
  background: color-mix(in srgb, var(--accent-primary) 11%, var(--fluid-card-item-top));
  border: 1px solid color-mix(in srgb, var(--accent-primary) 22%, var(--fluid-card-border));
  color: var(--accent-primary);
}

.store-header-copy {
  display: grid;
  gap: 3px;
  min-width: 0;
}

.store-header-title {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}

.store-header-title strong {
  font-size: 14.5px;
  font-weight: 660;
  color: var(--text-primary);
}

.store-header-sub {
  margin: 0;
  font-size: 12px;
  color: var(--text-secondary);
  line-height: 1.45;
}

.store-header-actions {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}

.store-toggle-btn {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  min-height: 30px;
  padding: 0 11px;
  border-radius: 999px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  color: var(--text-secondary);
  font: inherit;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
  transition: background-color 150ms ease, color 150ms ease, border-color 150ms ease;
}

.store-toggle-btn:hover {
  background: var(--fluid-card-hover);
  color: var(--text-primary);
  border-color: var(--fluid-card-border-strong, var(--fluid-card-border));
}

.store-body {
  display: flex;
  flex-direction: column;
  gap: 12px;
  padding-top: 12px;
  border-top: 1px solid var(--fluid-divider, rgba(20, 19, 17, 0.06));
}

.store-toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px 14px;
  flex-wrap: wrap;
}

.store-toolbar-left {
  display: flex;
  align-items: center;
  gap: 10px 14px;
  flex-wrap: wrap;
  min-width: 0;
}

.store-cat-pills {
  display: flex;
  align-items: center;
  gap: 4px;
  flex-wrap: wrap;
}

.store-target-picker {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 12px;
  color: var(--text-secondary);
}

.store-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(min(100%, 268px), 1fr));
  gap: 12px;
}

.store-card {
  border: 1px solid var(--fluid-card-border);
  border-radius: 14px;
  padding: 14px 15px;
  background: var(--fluid-card-item-fill);
  display: flex;
  flex-direction: column;
  gap: 10px;
  min-width: 0;
  transition: border-color 160ms ease, box-shadow 180ms ease, transform 180ms var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1));
}

.store-card.has-update {
  border-color: color-mix(in srgb, var(--warning, #9a5506) 36%, var(--fluid-card-border));
}

@media (hover: hover) {
  .store-card:hover {
    border-color: var(--fluid-card-border-strong, var(--fluid-card-border));
    box-shadow: var(--fluid-item-hover-shadow);
    transform: translateY(-1px);
  }
}

.store-card-top {
  display: flex;
  align-items: center;
  gap: 11px;
  min-width: 0;
}

.store-card-icon {
  width: 40px;
  height: 40px;
  border-radius: 11px;
  display: grid;
  place-items: center;
  flex-shrink: 0;
  overflow: hidden;
  background: var(--fluid-card-fill);
  border: 1px solid var(--fluid-card-border);
  color: var(--accent-primary);
}

.store-card-icon img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}

.store-card-heading {
  display: grid;
  gap: 2px;
  min-width: 0;
  flex: 1;
}

.store-card-title-row {
  display: flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
}

.store-card-title-row strong {
  font-size: 13.5px;
  font-weight: 660;
  color: var(--text-primary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.store-card-meta {
  font-size: 11.5px;
  color: var(--text-tertiary);
}

.store-card-desc {
  margin: 0;
  font-size: 12px;
  line-height: 1.5;
  color: var(--text-secondary);
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
  flex: 1;
}

.store-card-footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  padding-top: 8px;
  border-top: 1px solid var(--fluid-divider, rgba(20, 19, 17, 0.06));
}

.store-card-tags {
  display: flex;
  align-items: center;
  gap: 5px;
  flex-wrap: wrap;
  min-width: 0;
}

.store-tag-pill {
  font-size: 10.5px;
  font-weight: 560;
  color: var(--text-tertiary);
  padding: 2px 7px;
  border-radius: 999px;
  background: color-mix(in srgb, var(--text-primary) 4.5%, transparent);
  white-space: nowrap;
}

@media (prefers-reduced-motion: reduce) {
  .store-card,
  .store-toggle-btn {
    transition: none;
  }
}
</style>
