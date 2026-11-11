<script setup lang="ts">
import { ref } from "vue";
import { X, MapPin, Copy, Check, Sparkles, User } from "lucide-vue-next";
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
  mediaPath: (path: string) => string;
}>();

const emit = defineEmits<{
  (e: "close"): void;
  (e: "show-on-map", latitude: number, longitude: number): void;
  (e: "select-person", person: { id: number; name: string }): void;
  (e: "search-tag", tag: string): void;
}>();

const copied = ref(false);

async function copyOcrText() {
  const text = props.aiDetail?.ocrText?.trim();
  if (!text) return;
  try {
    await navigator.clipboard.writeText(text);
    copied.value = true;
    window.setTimeout(() => { copied.value = false; }, 1800);
  } catch {
    copied.value = false;
  }
}
</script>

<template>
  <div id="photo-viewer-info" class="viewer-info" role="region" aria-label="当前媒体信息">
    <div class="viewer-info-heading">
      <strong>媒体与智能识别</strong>
      <button type="button" aria-label="关闭媒体信息" @click="emit('close')"><X :size="18" /></button>
    </div>
    <dl>
      <div v-if="capturedLabel(asset)"><dt>拍摄时间</dt><dd>{{ capturedLabel(asset) }}</dd></div>
      <div v-if="asset.cameraMake || asset.cameraModel">
        <dt>相机</dt>
        <dd>{{ [asset.cameraMake, asset.cameraModel].filter(Boolean).join(" ") }}</dd>
      </div>
      <div v-if="asset.lensModel"><dt>镜头</dt><dd>{{ asset.lensModel }}</dd></div>
      <div v-if="asset.iso || asset.fNumber || asset.exposureSeconds || asset.focalLength">
        <dt>参数</dt>
        <dd>
          {{
            [
              asset.iso ? "ISO " + asset.iso : "",
              asset.fNumber ? formatAperture(asset.fNumber) : "",
              asset.exposureSeconds ? formatExposure(asset.exposureSeconds) : "",
              asset.focalLength ? asset.focalLength + "mm" : "",
            ].filter(Boolean).join(" · ")
          }}
        </dd>
      </div>
      <div v-if="asset.width && asset.height"><dt>分辨率</dt><dd>{{ asset.width }} × {{ asset.height }}</dd></div>
      <div v-if="asset.durationSeconds"><dt>时长</dt><dd>{{ formatDuration(asset.durationSeconds) }}</dd></div>
      <div><dt>文件</dt><dd>{{ formatBytes(asset.size) }}</dd></div>
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
.ai-sidebar-section {
  margin-top: 14px;
  padding-top: 12px;
  border-top: 1px solid rgba(255, 255, 255, 0.1);
}
.ai-sidebar-title-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  margin-bottom: 8px;
}
.ai-sidebar-title {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  font-size: 12px;
  font-weight: 600;
  opacity: 0.88;
  margin-bottom: 6px;
}
.ai-sidebar-title-row .ai-sidebar-title {
  margin-bottom: 0;
}
.ai-sidebar-muted {
  font-size: 12px;
  opacity: 0.65;
}
.ai-tag-list,
.ai-face-chip-list {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
}
.ai-tag-chip {
  padding: 3px 9px;
  border-radius: 999px;
  font-size: 12px;
  background: rgba(255, 255, 255, 0.12);
  color: inherit;
  border: 1px solid rgba(255, 255, 255, 0.16);
  cursor: pointer;
}
.ai-tag-chip:hover {
  background: rgba(255, 255, 255, 0.2);
}
.ai-face-chip {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 3px 9px 3px 3px;
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.12);
  color: inherit;
  border: 1px solid rgba(255, 255, 255, 0.16);
  font-size: 12px;
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
  padding: 2px 8px;
  border-radius: 6px;
  font-size: 11px;
  background: rgba(255, 255, 255, 0.14);
  color: inherit;
  border: none;
  cursor: pointer;
}
.ai-ocr-box {
  margin: 0;
  padding: 8px 10px;
  max-height: 150px;
  overflow-y: auto;
  white-space: pre-wrap;
  word-break: break-word;
  font-family: inherit;
  font-size: 12px;
  line-height: 1.5;
  border-radius: 8px;
  background: rgba(0, 0, 0, 0.28);
  user-select: text;
}
</style>
