<script setup lang="ts">
import { ref } from "vue";
import { X, MapPin, Copy, Check, Sparkles, User, Pencil } from "lucide-vue-next";
import { copyTextToClipboard } from "../../utils/clipboard.ts";
import { TIMINGS_MS } from "../../constants/timings.ts";
import type { BatchAsset } from "./usePhotoBatchActions.ts";
import type { AssetAIDetail } from "./usePhotoAISearchAndPeople.ts";
import {
  capturedLabel, formatBytes, formatExposure, formatAperture,
  formatDuration, coordinateLabel,
} from "./photoPresentation.ts";

const props = defineProps<{
  asset: BatchAsset;
  aiDetail: AssetAIDetail | null;
  aiLoading: boolean;
  canWrite?: boolean;
  mediaPath: (path: string) => string;
}>();

const emit = defineEmits<{
  (e: "close"): void;
  (e: "show-on-map", latitude: number, longitude: number): void;
  (e: "select-person", person: { id: number; name: string }): void;
  (e: "search-tag", tag: string): void;
  (e: "edit-metadata"): void;
}>();

const copied = ref(false);

async function copyOcrText() {
  const text = props.aiDetail?.ocrText?.trim();
  if (!text) return;
  if (await copyTextToClipboard(text)) {
    copied.value = true;
    window.setTimeout(() => { copied.value = false; }, TIMINGS_MS.COPIED_FEEDBACK);
  } else {
    copied.value = false;
  }
}
</script>

<template>
  <div id="photo-viewer-info" class="viewer-info viewer-info--obsidian" role="region" aria-label="当前媒体信息">
    <div class="viewer-info-heading">
      <strong>媒体与拍摄参数</strong>
      <div class="viewer-info-heading-actions">
        <button v-if="canWrite" type="button" title="修正拍摄时间或地点" aria-label="修正拍摄时间或地点" @click="emit('edit-metadata')"><Pencil :size="14" /></button>
        <button type="button" aria-label="关闭媒体信息" @click="emit('close')"><X :size="16" /></button>
      </div>
    </div>

    <div
      v-if="asset.cameraMake || asset.cameraModel || asset.lensModel || asset.iso || asset.fNumber || asset.exposureSeconds || asset.focalLength"
      class="exif-filmstrip-card"
    >
      <div v-if="asset.cameraMake || asset.cameraModel" class="exif-camera-name">
        {{ [asset.cameraMake, asset.cameraModel].filter(Boolean).join(" ") }}
      </div>
      <div v-if="asset.lensModel" class="exif-lens-name">{{ asset.lensModel }}</div>
      <div v-if="asset.iso || asset.fNumber || asset.exposureSeconds || asset.focalLength" class="exif-filmstrip-pills">
        <span v-if="asset.focalLength" class="exif-pill">{{ asset.focalLength }}mm</span>
        <span v-if="asset.fNumber" class="exif-pill">{{ formatAperture(asset.fNumber) }}</span>
        <span v-if="asset.exposureSeconds" class="exif-pill">{{ formatExposure(asset.exposureSeconds) }}</span>
        <span v-if="asset.iso" class="exif-pill">ISO {{ asset.iso }}</span>
      </div>
    </div>

    <dl>
      <div v-if="capturedLabel(asset)"><dt>拍摄时间</dt><dd>{{ capturedLabel(asset) }}</dd></div>
      <div v-if="asset.width && asset.height"><dt>像素尺寸</dt><dd>{{ asset.width }} × {{ asset.height }}</dd></div>
      <div v-if="asset.durationSeconds"><dt>视频时长</dt><dd>{{ formatDuration(asset.durationSeconds) }}</dd></div>
      <div><dt>文件体积</dt><dd>{{ formatBytes(asset.size) }}</dd></div>
      <div v-if="asset.path"><dt>存储路径</dt><dd class="viewer-path-dd">{{ asset.path }}</dd></div>
      <div v-if="asset.latitude != null && asset.longitude != null">
        <dt>位置</dt>
        <dd class="viewer-location">
          <MapPin :size="13" />
          {{ coordinateLabel(asset.latitude, asset.longitude) }}
          <button type="button" class="viewer-map-link" @click="emit('show-on-map', asset.latitude!, asset.longitude!)">
            在地图上查看
          </button>
        </dd>
      </div>
    </dl>

    <template v-if="asset.type === 'photo'">
      <div v-if="aiLoading" class="ai-sidebar-section">
        <small class="ai-sidebar-muted">正在读取本地智能识别信息…</small>
      </div>
      <template v-else-if="aiDetail">
        <div v-if="aiDetail.sceneLabels && aiDetail.sceneLabels.length" class="ai-sidebar-section">
          <div class="ai-sidebar-title"><Sparkles :size="13" /> 画面标签</div>
          <div class="ai-tag-list">
            <button
              v-for="tag in aiDetail.sceneLabels"
              :key="tag"
              type="button"
              class="ai-tag-chip"
              title="点击搜索同类画面"
              @click="emit('search-tag', tag)"
            >
              {{ tag }}
            </button>
          </div>
        </div>

        <div v-if="aiDetail.faces && aiDetail.faces.length" class="ai-sidebar-section">
          <div class="ai-sidebar-title"><User :size="13" /> 图中人物</div>
          <div class="ai-face-chip-list">
            <button
              v-for="face in aiDetail.faces"
              :key="face.faceId"
              type="button"
              class="ai-face-chip"
              :disabled="!face.personId"
              @click="face.personId && emit('select-person', { id: face.personId, name: face.personName || '' })"
            >
              <img
                :src="mediaPath('/api/v2/photos/faces/' + face.faceId + '/thumbnail')"
                alt="人物头像"
                loading="lazy"
                decoding="async"
              />
              <span>{{ face.personName || (face.personId ? "未命名人物" : "待归类") }}</span>
            </button>
          </div>
        </div>

        <div v-if="aiDetail.ocrText" class="ai-sidebar-section">
          <div class="ai-sidebar-title-row">
            <span class="ai-sidebar-title">实况文本 (离线 OCR)</span>
            <button type="button" class="ai-copy-btn" @click="copyOcrText">
              <Check v-if="copied" :size="12" /><Copy v-else :size="12" />
              {{ copied ? "已复制" : "复制文字" }}
            </button>
          </div>
          <pre class="ai-ocr-box">{{ aiDetail.ocrText }}</pre>
        </div>
        <div v-else-if="!aiDetail.indexed" class="ai-sidebar-section">
          <small class="ai-sidebar-muted">等待后台建立离线智能识图与文字索引…</small>
        </div>
      </template>
    </template>
  </div>
</template>

<style scoped>
.viewer-info.viewer-info--obsidian {
  position: relative;
  min-width: 0;
  min-height: 0;
  height: 100%;
  box-sizing: border-box;
  overflow: auto;
  padding: max(16px, env(safe-area-inset-top)) max(16px, env(safe-area-inset-right)) max(18px, env(safe-area-inset-bottom)) 16px;
  border: 0;
  border-left: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 0;
  background: rgba(15, 16, 20, 0.86);
  -webkit-backdrop-filter: blur(28px) saturate(165%);
  backdrop-filter: blur(28px) saturate(165%);
  color: #f5f5f7;
  box-shadow: -16px 0 40px rgba(0, 0, 0, 0.48);
}
.viewer-info-heading {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 8px;
  margin-bottom: 12px;
  font-size: 13.5px;
  color: #f5f5f7;
}
.viewer-info-heading-actions {
  display: inline-flex;
  gap: 6px;
  align-items: center;
}
.viewer-info-heading button {
  width: 30px;
  height: 30px;
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.1);
  border: 1px solid rgba(255, 255, 255, 0.14);
  color: rgba(255, 255, 255, 0.86);
  padding: 0;
  display: grid;
  place-items: center;
  cursor: pointer;
}
.viewer-info-heading button:hover {
  color: #fff;
  background: rgba(255, 255, 255, 0.18);
}
.exif-filmstrip-card {
  margin-bottom: 12px;
  padding: 10px 12px;
  border-radius: 12px;
  border: 1px solid rgba(255, 255, 255, 0.1);
  background: rgba(255, 255, 255, 0.06);
  display: grid;
  gap: 4px;
}
.exif-camera-name {
  font-size: 12.5px;
  font-weight: 650;
  color: #f5f5f7;
}
.exif-lens-name {
  font-size: 11px;
  color: rgba(245, 245, 247, 0.66);
}
.exif-filmstrip-pills {
  display: flex;
  flex-wrap: wrap;
  gap: 5px;
  margin-top: 3px;
}
.exif-pill {
  font-size: 11px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  padding: 2px 7px;
  border-radius: 6px;
  background: rgba(255, 255, 255, 0.08);
  border: 1px solid rgba(255, 255, 255, 0.12);
  color: rgba(245, 245, 247, 0.92);
}
.viewer-info dl {
  display: grid;
  grid-template-columns: 1fr;
  gap: 8px;
  margin: 0;
}
.viewer-info dl > div {
  display: flex;
  gap: 10px;
  align-items: baseline;
  min-width: 0;
}
.viewer-info dt {
  flex: none;
  min-width: 56px;
  color: rgba(245, 245, 247, 0.6);
  font-size: 11.5px;
}
.viewer-info dd {
  margin: 0;
  color: rgba(245, 245, 247, 0.94);
  font-size: 12px;
  font-variant-numeric: tabular-nums;
  word-break: break-word;
}
.viewer-info .viewer-path-dd {
  font-size: 11px;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  color: rgba(245, 245, 247, 0.64);
}
.viewer-location {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  flex-wrap: wrap;
}
.viewer-map-link {
  border: none;
  background: none;
  color: #60a5fa;
  font-size: 11.5px;
  font-weight: 600;
  padding: 0;
  text-decoration: underline;
  cursor: pointer;
}
.ai-sidebar-section {
  margin-top: 12px;
  padding-top: 11px;
  border-top: 1px solid rgba(255, 255, 255, 0.1);
}
.ai-sidebar-title-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  margin-bottom: 6px;
}
.ai-sidebar-title {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  font-size: 11.5px;
  font-weight: 650;
  color: rgba(245, 245, 247, 0.72);
  margin-bottom: 6px;
}
.ai-sidebar-title-row .ai-sidebar-title {
  margin-bottom: 0;
}
.ai-sidebar-muted {
  font-size: 11.5px;
  color: rgba(245, 245, 247, 0.62);
}
.ai-tag-list,
.ai-face-chip-list {
  display: flex;
  flex-wrap: wrap;
  gap: 5px;
}
.ai-tag-chip {
  padding: 3px 9px;
  border-radius: 999px;
  font-size: 11.5px;
  background: rgba(255, 255, 255, 0.08);
  color: #f5f5f7;
  border: 1px solid rgba(255, 255, 255, 0.12);
  cursor: pointer;
}
.ai-tag-chip:hover {
  background: rgba(255, 255, 255, 0.16);
  border-color: rgba(255, 255, 255, 0.28);
}
.ai-face-chip {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 2px 9px 2px 3px;
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.08);
  color: #f5f5f7;
  border: 1px solid rgba(255, 255, 255, 0.12);
  font-size: 11.5px;
  cursor: pointer;
}
.ai-face-chip img {
  width: 22px;
  height: 22px;
  border-radius: 50%;
  object-fit: cover;
}
.ai-copy-btn {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  padding: 3px 8px;
  border-radius: 7px;
  font-size: 11px;
  background: rgba(255, 255, 255, 0.09);
  border: 1px solid rgba(255, 255, 255, 0.14);
  color: rgba(245, 245, 247, 0.86);
  cursor: pointer;
}
.ai-copy-btn:hover {
  color: #fff;
  background: rgba(255, 255, 255, 0.16);
}
.ai-ocr-box {
  margin: 0;
  padding: 9px 11px;
  max-height: 140px;
  overflow-y: auto;
  white-space: pre-wrap;
  word-break: break-word;
  font-family: inherit;
  font-size: 11.5px;
  line-height: 1.5;
  border-radius: 9px;
  border: 1px solid rgba(255, 255, 255, 0.1);
  background: rgba(255, 255, 255, 0.05);
  color: #f5f5f7;
  user-select: text;
}
@media (max-width: 780px) {
  .viewer-info.viewer-info--obsidian {
    border-left: 0;
    border-top: 1px solid rgba(255, 255, 255, 0.14);
    border-radius: 18px 18px 0 0;
    padding: 14px 16px max(18px, env(safe-area-inset-bottom));
    box-shadow: 0 -16px 40px rgba(0, 0, 0, 0.52);
  }
}
@media (prefers-reduced-transparency: reduce) {
  .viewer-info.viewer-info--obsidian {
    -webkit-backdrop-filter: none;
    backdrop-filter: none;
    background: #141519;
  }
}
</style>
