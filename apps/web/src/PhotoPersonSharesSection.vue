<script setup lang="ts">
import { computed, onMounted, ref, watch } from "vue";
import { Share2, Trash2, Users, Eye, X } from "lucide-vue-next";
import AppleSelect from "./AppleSelect.vue";
import IsleButton from "./IsleButton.vue";
import IsleModal from "./IsleModal.vue";
import PhotoLiveOverlay from "./PhotoLiveOverlay.vue";
import { describeUserFacingError } from "./userFacingError.ts";
import { requestConfirm } from "./useConfirmDialog.ts";
import type { PersonSummary } from "./usePhotoAISearchAndPeople.ts";

type PersonShareItem = {
  id: number;
  ownerUserId: number;
  ownerUsername?: string;
  memberUserId: number;
  memberUsername?: string;
  personId: number;
  personName: string;
  label: string;
  sinceTakenAt?: number;
  photoCount: number;
  coverAssetId?: number;
  direction: "outgoing" | "incoming";
};

type SharedAssetItem = {
  id: number;
  name: string;
  type: "photo" | "video";
  takenAt: number;
  liveVideoAssetId?: number;
};

const props = defineProps<{
  active: boolean;
  rootKey: string;
  persons: PersonSummary[];
  api: <T = unknown>(url: string, method?: string, body?: object, signal?: AbortSignal) => Promise<T>;
  apiPath: (path: string) => string;
  mediaPath: (path: string) => string;
}>();

const shares = ref<PersonShareItem[]>([]);
const members = ref<Array<{ id: number; username: string }>>([]);
const selectedPersonId = ref("");
const selectedMemberId = ref("");
const shareLabel = ref("");
const sinceDate = ref("");
const busy = ref(false);
const error = ref("");
const notice = ref("");

const activeShare = ref<PersonShareItem | null>(null);
const shareAssets = ref<SharedAssetItem[]>([]);
const shareAssetsLoading = ref(false);
const previewAsset = ref<SharedAssetItem | null>(null);

const personOptions = computed(() =>
  props.persons.map((p) => ({
    value: String(p.id),
    label: `${p.name || "未命名人物 #" + p.id}（${p.photoCount} 张）`,
  })),
);

const memberOptions = computed(() =>
  members.value.map((m) => ({
    value: String(m.id),
    label: m.username,
  })),
);

const incomingShares = computed(() => shares.value.filter((s) => s.direction === "incoming"));
const outgoingShares = computed(() => shares.value.filter((s) => s.direction === "outgoing"));

async function loadShares() {
  error.value = "";
  try {
    const res = await props.api<{
      shares?: PersonShareItem[];
      members?: Array<{ id: number; username: string }>;
    }>(props.apiPath("/api/v2/photos/person-shares"));
    shares.value = Array.isArray(res.shares) ? res.shares : [];
    members.value = Array.isArray(res.members) ? res.members : [];
    if (!selectedPersonId.value && props.persons.length > 0) {
      selectedPersonId.value = String(props.persons[0].id);
    }
    if (!selectedMemberId.value && members.value.length > 0) {
      selectedMemberId.value = String(members.value[0].id);
    }
  } catch (e) {
    error.value = "读取人物共享列表失败：" + describeUserFacingError(e);
  }
}

async function createShare() {
  const pid = Number(selectedPersonId.value);
  const mid = Number(selectedMemberId.value);
  if (!pid || !mid || busy.value) return;
  busy.value = true;
  error.value = "";
  notice.value = "";
  try {
    const sinceTakenAt = sinceDate.value
      ? Math.max(0, Math.floor(new Date(sinceDate.value + "T00:00:00").getTime() / 1000))
      : 0;
    await props.api(props.apiPath("/api/v2/photos/person-shares"), "POST", {
      personId: pid,
      memberUserId: mid,
      label: shareLabel.value.trim(),
      sinceTakenAt,
    });
    shareLabel.value = "";
    notice.value = "已创建家庭人物只读共享视图，新识别出的同人物照片将自动同步展示（零原片拷贝）。";
    await loadShares();
  } catch (e) {
    error.value = "创建人物共享失败：" + describeUserFacingError(e);
  } finally {
    busy.value = false;
  }
}

async function removeShare(item: PersonShareItem) {
  const isOwner = item.direction === "outgoing";
  const ok = await requestConfirm({
    title: isOwner ? "撤销人物共享" : "退出人物共享",
    message: isOwner
      ? `确认撤销共享给「${item.memberUsername || "成员"}」的「${item.label}」吗？对方将立即无法查看，你的原照片不受任何影响。`
      : `确认退出「${item.label}」共享视图吗？`,
    confirmText: isOwner ? "确认撤销" : "退出共享",
    variant: "danger",
  });
  if (!ok || busy.value) return;
  busy.value = true;
  error.value = "";
  try {
    await props.api(props.apiPath(`/api/v2/photos/person-shares/${item.id}`), "DELETE");
    if (activeShare.value?.id === item.id) activeShare.value = null;
    await loadShares();
  } catch (e) {
    error.value = "操作失败：" + describeUserFacingError(e);
  } finally {
    busy.value = false;
  }
}

async function openShareGallery(item: PersonShareItem) {
  activeShare.value = item;
  previewAsset.value = null;
  shareAssetsLoading.value = true;
  try {
    const res = await props.api<{ assets?: SharedAssetItem[] }>(
      props.apiPath(`/api/v2/photos/person-shares/${item.id}/assets?limit=120`),
    );
    shareAssets.value = Array.isArray(res.assets) ? res.assets : [];
  } catch (e) {
    error.value = "加载共享照片失败：" + describeUserFacingError(e);
  } finally {
    shareAssetsLoading.value = false;
  }
}

function sharedThumbUrl(shareId: number, assetId: number) {
  return props.mediaPath(`/api/v2/photos/person-shares/${shareId}/assets/${assetId}/thumbnail`);
}

function sharedContentUrl(shareId: number, assetId: number) {
  return props.mediaPath(`/api/v2/photos/person-shares/${shareId}/assets/${assetId}/content`);
}

function sharedLiveUrl(shareId: number, assetId: number) {
  return props.mediaPath(`/api/v2/photos/person-shares/${shareId}/assets/${assetId}/live-video`);
}

watch(
  () => [props.active, props.rootKey, props.persons.length],
  ([isActive]) => {
    if (isActive) void loadShares();
  },
);

onMounted(() => {
  if (props.active) void loadShares();
});
</script>

<template>
  <div class="person-shares-panel">
    <div class="person-shares-head">
      <div>
        <h4><Share2 :size="15" /> 宝宝 / 家人自动只读共享视图</h4>
        <p>将指定人物自动聚类流只读授权给家庭成员，后续备份的新照片会自动出现，无需手动挑图或复制文件。</p>
      </div>
    </div>

    <p v-if="error" class="form-error" role="alert">{{ error }}</p>
    <p v-if="notice" class="gallery-message" role="status">{{ notice }}</p>

    <div v-if="persons.length > 0 && members.length > 0" class="person-share-create-bar">
      <AppleSelect v-model="selectedPersonId" :options="personOptions" size="sm" aria-label="选择要共享的人物" />
      <AppleSelect v-model="selectedMemberId" :options="memberOptions" size="sm" aria-label="选择接收的家庭成员" />
      <input v-model="shareLabel" class="person-share-input" maxlength="40" placeholder="共享名称（如：宝宝成长相册）" />
      <input v-model="sinceDate" type="date" class="person-share-input" title="可选：仅共享此日期之后拍摄的照片" />
      <IsleButton variant="primary" size="sm" :loading="busy" @click="createShare">
        <Share2 :size="13" /> 生成只读共享
      </IsleButton>
    </div>

    <div v-if="incomingShares.length > 0" class="person-share-group">
      <strong>家人共享给我的人物相册</strong>
      <div class="person-share-cards">
        <div v-for="item in incomingShares" :key="item.id" class="person-share-card">
          <div>
            <strong>{{ item.label }}</strong>
            <small>来自 {{ item.ownerUsername || "家人" }} · {{ item.photoCount }} 张</small>
          </div>
          <div class="person-share-card-actions">
            <IsleButton variant="tonal" size="sm" @click="openShareGallery(item)"><Eye :size="13" /> 浏览</IsleButton>
            <IsleButton variant="glass" size="sm" @click="removeShare(item)">退出</IsleButton>
          </div>
        </div>
      </div>
    </div>

    <div v-if="outgoingShares.length > 0" class="person-share-group">
      <strong>我共享给家人的人物视图</strong>
      <div class="person-share-cards">
        <div v-for="item in outgoingShares" :key="item.id" class="person-share-card">
          <div>
            <strong>{{ item.label }}</strong>
            <small>共享给 {{ item.memberUsername || "成员 #" + item.memberUserId }} · {{ item.photoCount }} 张 · 只读</small>
          </div>
          <div class="person-share-card-actions">
            <IsleButton variant="glass" size="sm" @click="openShareGallery(item)"><Eye :size="13" /> 预览</IsleButton>
            <IsleButton variant="danger" size="sm" @click="removeShare(item)"><Trash2 :size="13" /> 撤销</IsleButton>
          </div>
        </div>
      </div>
    </div>

    <IsleModal v-if="activeShare" :title="activeShare.label" size="wide" @close="activeShare = null">
      <template #icon><Users :size="17" /></template>
      <div v-if="previewAsset" class="shared-asset-preview">
        <div class="shared-asset-preview-bar">
          <strong>{{ previewAsset.name }}</strong>
          <button type="button" class="person-mini-close" @click="previewAsset = null"><X :size="14" /> 返回缩略图</button>
        </div>
        <div class="shared-asset-stage">
          <img
            v-if="previewAsset.type === 'photo'"
            :src="sharedContentUrl(activeShare.id, previewAsset.id)"
            :alt="previewAsset.name"
          />
          <video
            v-else
            :src="sharedContentUrl(activeShare.id, previewAsset.id)"
            controls
            playsinline
          />
          <PhotoLiveOverlay
            v-if="previewAsset.type === 'photo' && (previewAsset.liveVideoAssetId ?? 0) > 0"
            :live-video-src="sharedLiveUrl(activeShare.id, previewAsset.id)"
          />
        </div>
      </div>
      <div v-else-if="shareAssetsLoading" class="shared-empty-note">正在读取人物照片…</div>
      <div v-else-if="shareAssets.length === 0" class="shared-empty-note">当前时间范围内暂无已归类照片。</div>
      <div v-else class="shared-assets-grid">
        <button
          v-for="asset in shareAssets"
          :key="asset.id"
          type="button"
          class="shared-asset-tile"
          @click="previewAsset = asset"
        >
          <img :src="sharedThumbUrl(activeShare.id, asset.id)" :alt="asset.name" loading="lazy" decoding="async" />
          <span v-if="(asset.liveVideoAssetId ?? 0) > 0" class="shared-live-tag">LIVE</span>
        </button>
      </div>
    </IsleModal>
  </div>
</template>

<style scoped>
.person-shares-panel {
  margin-top: 8px;
  padding: 16px 18px;
  border-radius: 16px;
  border: 1px solid var(--fluid-card-border, rgba(0, 0, 0, 0.08));
  background: var(--fluid-card-item-fill, rgba(255, 255, 255, 0.65));
  display: flex;
  flex-direction: column;
  gap: 12px;
}
.person-shares-head h4 {
  margin: 0 0 4px;
  font-size: 14.5px;
  display: flex;
  align-items: center;
  gap: 6px;
}
.person-shares-head p {
  margin: 0;
  font-size: 12.5px;
  color: var(--text-secondary, #6e6e73);
}
.person-share-create-bar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px;
}
.person-share-input {
  padding: 6px 10px;
  border-radius: 10px;
  border: 1px solid var(--fluid-card-border, rgba(0, 0, 0, 0.14));
  background: var(--fluid-card-fill, #fff);
  color: inherit;
  font-size: 12.5px;
}
.person-share-group {
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.person-share-group > strong {
  font-size: 12.5px;
  color: var(--text-secondary, #6e6e73);
}
.person-share-cards {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
  gap: 10px;
}
.person-share-card {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  padding: 10px 14px;
  border-radius: 12px;
  border: 1px solid var(--fluid-card-border, rgba(0, 0, 0, 0.08));
  background: var(--fluid-card-fill, rgba(255, 255, 255, 0.8));
}
.person-share-card strong {
  display: block;
  font-size: 13.5px;
}
.person-share-card small {
  font-size: 11.5px;
  color: var(--text-secondary, #6e6e73);
}
.person-share-card-actions {
  display: flex;
  gap: 6px;
}
.shared-assets-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(120px, 1fr));
  gap: 8px;
  max-height: 62vh;
  overflow-y: auto;
}
.shared-asset-tile {
  position: relative;
  aspect-ratio: 1;
  border: none;
  border-radius: 10px;
  overflow: hidden;
  padding: 0;
  cursor: pointer;
  background: rgba(120, 120, 128, 0.14);
}
.shared-asset-tile img {
  width: 100%;
  height: 100%;
  object-fit: cover;
}
.shared-live-tag {
  position: absolute;
  top: 6px;
  left: 6px;
  padding: 2px 6px;
  border-radius: 999px;
  background: rgba(0, 0, 0, 0.65);
  color: #fff;
  font-size: 10px;
  font-weight: 700;
}
.shared-asset-stage {
  position: relative;
  height: 58vh;
  background: #000;
  border-radius: 12px;
  overflow: hidden;
  display: flex;
  align-items: center;
  justify-content: center;
}
.shared-asset-stage img,
.shared-asset-stage video {
  max-width: 100%;
  max-height: 100%;
  object-fit: contain;
}
.shared-asset-preview-bar {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 8px;
}
.person-mini-close {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  padding: 5px 10px;
  border-radius: 8px;
  border: 1px solid rgba(120, 120, 128, 0.25);
  background: transparent;
  color: inherit;
  cursor: pointer;
}
.shared-empty-note {
  padding: 28px;
  text-align: center;
  font-size: 13px;
  color: var(--text-secondary, #6e6e73);
}
</style>
