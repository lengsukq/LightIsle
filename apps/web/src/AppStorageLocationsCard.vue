<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { HardDrive, FolderCog, CheckCircle2, AlertTriangle, Plus, RotateCcw, Trash2, Star } from "lucide-vue-next";
import IsleButton from "./IsleButton.vue";
import IsleBadge from "./IsleBadge.vue";
import type {
  AppStorageLocationItem,
  AppStorageMutationPayload,
  AppStorageSnapshot,
} from "./types/appsCenter.ts";

const props = defineProps<{
  storage: AppStorageSnapshot | null;
  busy?: boolean;
}>();

const emit = defineEmits<{
  (e: "mutate", payload: AppStorageMutationPayload): void;
}>();

const editorMode = ref<"internal" | "external" | null>(null);
const pathDraft = ref("");
const nameDraft = ref("");
const setAsDefault = ref(false);

const locations = computed(() => props.storage?.locations ?? []);
const internalLocation = computed(() => locations.value.find((loc) => loc.kind === "internal") ?? null);
const externalLocation = computed(() => locations.value.find((loc) => loc.kind === "external") ?? null);
const volumes = computed(() => props.storage?.availableVolumes ?? []);

watch(
  () => props.storage,
  () => {
    editorMode.value = null;
  },
);

function formatBytes(bytes?: number): string {
  if (!bytes || bytes <= 0) return "";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let idx = 0;
  while (value >= 1024 && idx < units.length - 1) {
    value /= 1024;
    idx++;
  }
  return `${value >= 100 || idx <= 1 ? Math.round(value) : value.toFixed(1)} ${units[idx]}`;
}

function openInternalEditor(loc: AppStorageLocationItem | null) {
  editorMode.value = "internal";
  pathDraft.value = loc?.path || "";
  nameDraft.value = loc?.name || "Mac 内置盘";
  setAsDefault.value = false;
}

function openExternalEditor(loc: AppStorageLocationItem | null) {
  editorMode.value = "external";
  if (loc) {
    pathDraft.value = loc.path;
    nameDraft.value = loc.name;
    setAsDefault.value = loc.isDefault;
  } else if (volumes.value.length > 0) {
    pathDraft.value = volumes.value[0].suggestedPath;
    nameDraft.value = volumes.value[0].name;
    setAsDefault.value = false;
  } else {
    pathDraft.value = "";
    nameDraft.value = "";
    setAsDefault.value = false;
  }
}

function pickVolume(suggestedPath: string, name: string) {
  pathDraft.value = suggestedPath;
  if (!nameDraft.value.trim()) {
    nameDraft.value = name;
  }
}

function submitEditor() {
  if (!editorMode.value || !pathDraft.value.trim()) return;
  if (editorMode.value === "internal") {
    emit("mutate", {
      action: "set",
      kind: "internal",
      path: pathDraft.value.trim(),
      name: nameDraft.value.trim() || "Mac 内置盘",
      setDefault: setAsDefault.value,
    });
    return;
  }
  emit("mutate", {
    action: externalLocation.value ? "set" : "add",
    kind: "external",
    path: pathDraft.value.trim(),
    name: nameDraft.value.trim(),
    setDefault: setAsDefault.value,
  });
}
</script>

<template>
  <section v-if="storage" class="apps-storage-card" aria-label="应用数据存储位置">
    <div class="apps-storage-header">
      <div>
        <div class="mcp-title-row">
          <HardDrive :size="17" />
          <strong>应用数据存储位置</strong>
          <IsleBadge variant="accent" size="sm">
            已配置 {{ locations.length }} / {{ storage.maxLocations }}（1 内置盘 + 1 其他盘）
          </IsleBadge>
        </div>
        <small>
          选择应用中心轻应用代码（<code>plugins/</code>）及运行数据（<code>plugin-data/</code>）的存放位置。
          系统仅支持 <strong>1 个内置盘</strong> 与 <strong>1 个其他盘</strong>，最多 2 个可选位置。
        </small>
      </div>
    </div>

    <div class="apps-storage-slots">
      <!-- Slot 1: Internal Disk -->
      <article v-if="internalLocation" class="apps-storage-slot" :class="{ default: internalLocation.isDefault }">
        <div class="apps-storage-slot-top">
          <div>
            <div class="apps-storage-slot-title">
              <strong>{{ internalLocation.name || "Mac 内置盘" }}</strong>
              <IsleBadge variant="neutral" size="sm">内置盘 1/1</IsleBadge>
              <IsleBadge v-if="internalLocation.isDefault" variant="accent" size="sm">
                <Star :size="11" /> 默认安装位置
              </IsleBadge>
              <IsleBadge :variant="internalLocation.online && internalLocation.writable ? 'online' : 'offline'" dot size="sm">
                {{ internalLocation.online && internalLocation.writable ? "可用" : "不可用" }}
              </IsleBadge>
            </div>
            <code class="apps-storage-path">{{ internalLocation.path }}</code>
          </div>
        </div>
        <div class="apps-storage-meta">
          <span>已安装 {{ internalLocation.appCount }} 个应用</span>
          <span v-if="internalLocation.freeBytes">
            剩余 {{ formatBytes(internalLocation.freeBytes) }}
            <template v-if="internalLocation.totalBytes"> / {{ formatBytes(internalLocation.totalBytes) }}</template>
          </span>
          <span>{{ internalLocation.isCustomPath ? "自定义内置目录" : "系统默认目录" }}</span>
        </div>
        <p v-if="internalLocation.error" class="apps-error">{{ internalLocation.error }}</p>
        <div class="apps-storage-actions">
          <IsleButton
            v-if="!internalLocation.isDefault"
            variant="glass"
            size="sm"
            :disabled="busy"
            @click="emit('mutate', { action: 'set_default', defaultLocationId: 'internal' })"
          >
            设为默认安装位置
          </IsleButton>
          <IsleButton variant="glass" size="sm" :disabled="busy" @click="openInternalEditor(internalLocation)">
            <FolderCog :size="13" /> 修改内置路径
          </IsleButton>
          <IsleButton
            v-if="internalLocation.isCustomPath"
            variant="glass"
            size="sm"
            :disabled="busy"
            @click="emit('mutate', { action: 'reset_internal' })"
          >
            <RotateCcw :size="13" /> 恢复默认
          </IsleButton>
        </div>
      </article>

      <!-- Slot 2: External / Other Disk (Max 1) -->
      <article v-if="externalLocation" class="apps-storage-slot" :class="{ default: externalLocation.isDefault, offline: !externalLocation.online }">
        <div class="apps-storage-slot-top">
          <div>
            <div class="apps-storage-slot-title">
              <strong>{{ externalLocation.name || "外置其他盘" }}</strong>
              <IsleBadge variant="neutral" size="sm">其他盘 1/1</IsleBadge>
              <IsleBadge v-if="externalLocation.isDefault" variant="accent" size="sm">
                <Star :size="11" /> 默认安装位置
              </IsleBadge>
              <IsleBadge :variant="externalLocation.online && externalLocation.writable ? 'online' : 'offline'" dot size="sm">
                <CheckCircle2 v-if="externalLocation.online && externalLocation.writable" :size="11" />
                <AlertTriangle v-else :size="11" />
                {{ externalLocation.online ? (externalLocation.writable ? "在线可写" : "只读") : "已离线" }}
              </IsleBadge>
            </div>
            <code class="apps-storage-path">{{ externalLocation.path }}</code>
          </div>
        </div>
        <div class="apps-storage-meta">
          <span>已安装 {{ externalLocation.appCount }} 个应用</span>
          <span v-if="externalLocation.freeBytes">
            剩余 {{ formatBytes(externalLocation.freeBytes) }}
            <template v-if="externalLocation.totalBytes"> / {{ formatBytes(externalLocation.totalBytes) }}</template>
          </span>
          <span v-if="externalLocation.volumeName">卷：{{ externalLocation.volumeName }}</span>
        </div>
        <p v-if="externalLocation.error" class="apps-error">{{ externalLocation.error }}</p>
        <div class="apps-storage-actions">
          <IsleButton
            v-if="!externalLocation.isDefault"
            variant="glass"
            size="sm"
            :disabled="busy || !externalLocation.online || !externalLocation.writable"
            @click="emit('mutate', { action: 'set_default', defaultLocationId: 'external' })"
          >
            设为默认安装位置
          </IsleButton>
          <IsleButton variant="glass" size="sm" :disabled="busy" @click="openExternalEditor(externalLocation)">
            <FolderCog :size="13" /> 更换路径
          </IsleButton>
          <IsleButton variant="danger" size="sm" :disabled="busy" @click="emit('mutate', { action: 'remove_external' })">
            <Trash2 :size="13" /> 移除登记
          </IsleButton>
        </div>
      </article>

      <article v-else class="apps-storage-slot apps-storage-slot-empty">
        <div class="apps-storage-slot-title">
          <strong>其他盘位置（可选）</strong>
          <IsleBadge variant="neutral" size="sm">其他盘 0/1</IsleBadge>
        </div>
        <small>可额外绑定 1 个外置或非系统磁盘目录（如 <code>/Volumes/磁盘名/LightIsleApps</code>），安装轻应用时即可自由选择存放在内置盘或其他盘。</small>
        <div class="apps-storage-actions">
          <IsleButton variant="primary" size="sm" :disabled="busy" @click="openExternalEditor(null)">
            <Plus :size="13" /> 添加其他盘位置
          </IsleButton>
        </div>
      </article>
    </div>

    <!-- Inline Editor for Internal or External Location -->
    <div v-if="editorMode" class="apps-storage-editor">
      <div class="apps-storage-editor-head">
        <strong>{{ editorMode === "internal" ? "修改 Mac 内置盘应用目录" : (externalLocation ? "更换其他盘位置" : "添加其他盘位置（仅限 1 个）") }}</strong>
        <button type="button" class="mcp-mini-btn" @click="editorMode = null">收起</button>
      </div>

      <div v-if="editorMode === 'external' && volumes.length > 0" class="apps-storage-vol-picks">
        <span>已识别可用磁盘卷：</span>
        <button
          v-for="vol in volumes"
          :key="vol.mount"
          type="button"
          class="apps-storage-vol-chip"
          :disabled="vol.readOnly"
          @click="pickVolume(vol.suggestedPath, vol.name)"
        >
          {{ vol.name }}
          <small v-if="vol.freeBytes">（余 {{ formatBytes(vol.freeBytes) }}）</small>
        </button>
      </div>

      <div class="apps-storage-editor-fields">
        <label>
          目录路径（Mac 本机绝对路径）
          <input
            v-model.trim="pathDraft"
            :placeholder="editorMode === 'external' ? '/Volumes/MyDisk/LightIsleApps' : '/Users/name/LightIsleApps'"
          />
        </label>
        <label>
          显示名称（可选）
          <input v-model.trim="nameDraft" :placeholder="editorMode === 'external' ? '外置扩展盘' : 'Mac 内置盘'" />
        </label>
      </div>
      <div class="apps-storage-editor-footer">
        <label class="apps-check-item">
          <input v-model="setAsDefault" type="checkbox" class="isle-checkbox" />
          同时设为新建 / 安装应用默认位置
        </label>
        <div class="apps-storage-actions">
          <IsleButton variant="glass" size="sm" :disabled="busy" @click="editorMode = null">取消</IsleButton>
          <IsleButton variant="primary" size="sm" :disabled="busy || !pathDraft.trim()" @click="submitEditor">
            保存并生效
          </IsleButton>
        </div>
      </div>
    </div>
  </section>
</template>
