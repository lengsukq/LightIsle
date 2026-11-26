<script setup lang="ts">
import { ref, watch } from "vue";
import { Calendar, MapPin, RotateCcw } from "lucide-vue-next";
import IsleModal from "../../components/ui/IsleModal.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";

export type MetadataEditPayload = {
  ids: number[];
  takenAt?: number;
  latitude?: number;
  longitude?: number;
  clearLocation?: boolean;
  reset?: boolean;
};

const props = defineProps<{
  open: boolean;
  assetIds: number[];
  initialTakenAt?: number;
  initialLatitude?: number | null;
  initialLongitude?: number | null;
  busy?: boolean;
  error?: string;
}>();

const emit = defineEmits<{
  close: [];
  submit: [payload: MetadataEditPayload];
}>();

const dateTimeInput = ref("");
const latInput = ref("");
const lonInput = ref("");
const clearLocation = ref(false);
const localError = ref("");

const cityPresets = [
  { name: "北京", lat: 39.9042, lon: 116.4074 },
  { name: "上海", lat: 31.2304, lon: 121.4737 },
  { name: "深圳", lat: 22.5431, lon: 114.0579 },
  { name: "杭州", lat: 30.2741, lon: 120.1551 },
  { name: "成都", lat: 30.5728, lon: 104.0668 },
  { name: "三亚", lat: 18.2528, lon: 109.512 },
];

function toDateTimeLocal(epochSeconds?: number): string {
  if (!epochSeconds || epochSeconds <= 0) return "";
  const d = new Date(epochSeconds * 1000);
  if (Number.isNaN(d.getTime())) return "";
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

watch(
  () => props.open,
  (isOpen) => {
    if (!isOpen) return;
    localError.value = "";
    clearLocation.value = false;
    dateTimeInput.value = toDateTimeLocal(props.initialTakenAt);
    latInput.value = props.initialLatitude != null ? String(props.initialLatitude) : "";
    lonInput.value = props.initialLongitude != null ? String(props.initialLongitude) : "";
  },
  { immediate: true },
);

function applyPreset(lat: number, lon: number) {
  clearLocation.value = false;
  latInput.value = String(lat);
  lonInput.value = String(lon);
  localError.value = "";
}

function submitPatch() {
  localError.value = "";
  const payload: MetadataEditPayload = { ids: [...props.assetIds] };
  if (dateTimeInput.value.trim()) {
    const ms = new Date(dateTimeInput.value).getTime();
    if (!Number.isFinite(ms) || ms <= 0) {
      localError.value = "请输入有效的拍摄日期与时间。";
      return;
    }
    payload.takenAt = Math.floor(ms / 1000);
  }
  if (clearLocation.value) {
    payload.clearLocation = true;
  } else if (latInput.value.trim() || lonInput.value.trim()) {
    const lat = Number(latInput.value.trim());
    const lon = Number(lonInput.value.trim());
    if (!Number.isFinite(lat) || !Number.isFinite(lon) || lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      localError.value = "请输入合法的经纬度（纬度 -90~90，经度 -180~180）。";
      return;
    }
    payload.latitude = lat;
    payload.longitude = lon;
  }
  if (payload.takenAt === undefined && payload.latitude === undefined && !payload.clearLocation) {
    localError.value = "请至少填写拍摄时间、位置坐标或勾选清除位置。";
    return;
  }
  emit("submit", payload);
}

function submitReset() {
  localError.value = "";
  emit("submit", { ids: [...props.assetIds], reset: true });
}
</script>

<template>
  <IsleModal
    v-if="open"
    :title="assetIds.length > 1 ? `批量修正拍摄时间与地点 (${assetIds.length} 项)` : '修正拍摄时间与地点'"
    @close="emit('close')"
  >
    <template #icon><Calendar :size="17" /></template>
    <p class="meta-edit-hint">
      修正结果仅保存在轻屿元数据索引中，绝不修改硬盘上的原片文件；时间线与足迹地图会立即更新。
    </p>
    <IsleBanner v-if="localError || error" type="error" compact :message="localError || error" style="margin-bottom: 12px" />

    <div class="meta-edit-field">
      <label for="meta-edit-datetime"><Calendar :size="14" /> 拍摄日期与时间</label>
      <input id="meta-edit-datetime" v-model="dateTimeInput" type="datetime-local" />
    </div>

    <div class="meta-edit-field">
      <label><MapPin :size="14" /> 拍摄地点坐标（纬度 / 经度）</label>
      <div class="meta-edit-coords">
        <input v-model="latInput" type="number" step="0.0001" min="-90" max="90" placeholder="纬度 (如 39.9042)" :disabled="clearLocation" />
        <input v-model="lonInput" type="number" step="0.0001" min="-180" max="180" placeholder="经度 (如 116.4074)" :disabled="clearLocation" />
      </div>
      <div class="meta-edit-presets">
        <button
          v-for="city in cityPresets"
          :key="city.name"
          type="button"
          class="meta-preset-chip"
          @click="applyPreset(city.lat, city.lon)"
        >
          {{ city.name }}
        </button>
      </div>
      <label class="meta-clear-check">
        <input v-model="clearLocation" type="checkbox" />
        <span>清除已有位置信息（从足迹地图隐藏）</span>
      </label>
    </div>

    <template #footer>
      <div class="meta-edit-footer">
        <IsleButton variant="glass" size="sm" :disabled="busy" @click="submitReset">
          <RotateCcw :size="13" /> 恢复原片 EXIF
        </IsleButton>
        <div class="meta-edit-footer-right">
          <IsleButton variant="glass" size="sm" :disabled="busy" @click="emit('close')">取消</IsleButton>
          <IsleButton variant="primary" size="sm" :loading="busy" :disabled="busy" @click="submitPatch">保存修正</IsleButton>
        </div>
      </div>
    </template>
  </IsleModal>
</template>

<style scoped>
.meta-edit-hint {
  margin: 0 0 12px;
  font-size: 12.5px;
  line-height: 1.5;
  color: var(--text-secondary);
}
.meta-edit-field {
  display: grid;
  gap: 6px;
  margin-bottom: 14px;
}
.meta-edit-field > label {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 12.5px;
  font-weight: 600;
  color: var(--text-primary);
}
.meta-edit-field input[type="datetime-local"],
.meta-edit-coords input {
  box-sizing: border-box;
  width: 100%;
  padding: 8px 11px;
  border-radius: 10px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  color: var(--text-primary);
  font-size: 13px;
}
.meta-edit-coords {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(100%, 160px), 1fr));
  gap: 8px;
}
@media (max-width: 480px) {
  .meta-edit-field input[type="datetime-local"],
  .meta-edit-coords input {
    font-size: 16px;
  }
}
.meta-edit-presets {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin-top: 2px;
}
.meta-preset-chip {
  padding: 3px 9px;
  border-radius: 999px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  color: var(--text-secondary);
  font-size: 11.5px;
  cursor: pointer;
}
.meta-preset-chip:hover {
  color: var(--text-primary);
  border-color: var(--accent-primary);
}
.meta-clear-check {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 12px;
  font-weight: 400 !important;
  color: var(--text-secondary) !important;
  cursor: pointer;
}
.meta-edit-footer {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 10px;
  width: 100%;
  flex-wrap: wrap;
}
.meta-edit-footer-right {
  display: flex;
  gap: 8px;
}
</style>
