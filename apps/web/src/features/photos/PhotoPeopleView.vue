<script setup lang="ts">
import { computed, nextTick, onMounted, ref, watch } from "vue";
import { Users, RefreshCw, Pencil, EyeOff, Eye, GitMerge, Share2 } from "lucide-vue-next";
import IsleActionMenu from "../../components/ui/IsleActionMenu.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleModal from "../../components/ui/IsleModal.vue";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import PhotoPersonSharesSection from "./PhotoPersonSharesSection.vue";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import type { PersonSummary } from "./usePhotoAISearchAndPeople.ts";

const props = defineProps<{
  active: boolean;
  rootKey: string;
  api: <T = unknown>(url: string, method?: string, body?: object, signal?: AbortSignal) => Promise<T>;
  apiPath: (path: string) => string;
  mediaPath: (path: string) => string;
}>();

const emit = defineEmits<{
  (e: "select-person", person: { id: number; name: string }): void;
}>();

const persons = ref<PersonSummary[]>([]);
const loading = ref(false);
const error = ref("");
const includeHidden = ref(false);
const editingPerson = ref<PersonSummary | null>(null);
const editingName = ref("");
const renameInputRef = ref<HTMLInputElement | null>(null);
const mergingSource = ref<PersonSummary | null>(null);
const mergeTargetId = ref<string>("");
const busy = ref(false);
const failedAvatars = ref<Record<number, boolean>>({});
const loadedAvatars = ref<Record<number, boolean>>({});
const sharesSectionRef = ref<{ openForPerson: (personId: number) => Promise<void> } | null>(null);

async function loadPersons() {
  loading.value = true;
  error.value = "";
  try {
    const suffix = includeHidden.value ? "?includeHidden=1" : "";
    const res = await props.api<{ persons: PersonSummary[] }>(props.apiPath("/api/v2/photos/persons" + suffix));
    persons.value = Array.isArray(res.persons) ? res.persons : [];
  } catch (e) {
    error.value = "读取人物相册失败：" + describeUserFacingError(e);
  } finally {
    loading.value = false;
  }
}

function beginRename(p: PersonSummary) {
  editingPerson.value = p;
  editingName.value = p.name;
  mergingSource.value = null;
  void nextTick(() => {
    renameInputRef.value?.focus();
    renameInputRef.value?.select();
  });
}

async function saveRename() {
  const p = editingPerson.value;
  if (!p || busy.value) return;
  busy.value = true;
  error.value = "";
  try {
    await props.api(props.apiPath(`/api/v2/photos/persons/${p.id}`), "PATCH", { name: editingName.value.trim() });
    editingPerson.value = null;
    await loadPersons();
  } catch (e) {
    error.value = "保存姓名失败：" + describeUserFacingError(e);
  } finally {
    busy.value = false;
  }
}

async function toggleHidden(p: PersonSummary) {
  if (busy.value) return;
  busy.value = true;
  error.value = "";
  try {
    await props.api(props.apiPath(`/api/v2/photos/persons/${p.id}`), "PATCH", { hidden: !p.hidden });
    await loadPersons();
  } catch (e) {
    error.value = "更新显示状态失败：" + describeUserFacingError(e);
  } finally {
    busy.value = false;
  }
}

const mergeTargetOptions = computed(() =>
  persons.value
    .filter((item) => item.id !== mergingSource.value?.id)
    .map((other) => ({
      value: String(other.id),
      label: `合并到：${other.name || "未命名 #" + other.id}`,
      hint: `${other.photoCount} 张`,
    })),
);

function beginMerge(p: PersonSummary) {
  mergingSource.value = p;
  editingPerson.value = null;
  const candidate = persons.value.find((other) => other.id !== p.id);
  mergeTargetId.value = candidate ? String(candidate.id) : "";
}

async function confirmMerge() {
  const source = mergingSource.value;
  const targetId = Number(mergeTargetId.value);
  if (!source || !targetId || targetId === source.id || busy.value) return;
  busy.value = true;
  error.value = "";
  try {
    await props.api(props.apiPath(`/api/v2/photos/persons/${source.id}/merge`), "POST", { targetPersonId: targetId });
    mergingSource.value = null;
    await loadPersons();
  } catch (e) {
    error.value = "合并人物失败：" + describeUserFacingError(e);
  } finally {
    busy.value = false;
  }
}

function onAvatarLoad(event: Event, id: number) {
  const img = event.target as HTMLImageElement | null;
  if (img && img.naturalWidth === 0) {
    failedAvatars.value = { ...failedAvatars.value, [id]: true };
    return;
  }
  loadedAvatars.value = { ...loadedAvatars.value, [id]: true };
}

function openShare(person: PersonSummary) {
  void sharesSectionRef.value?.openForPerson(person.id);
}

watch(() => [props.active, props.rootKey, includeHidden.value], ([isActive]) => {
  if (isActive) void loadPersons();
});

onMounted(() => {
  if (props.active) void loadPersons();
});
</script>

<template>
  <section class="people-view" aria-label="人物相册">
    <header class="people-header">
      <div>
        <h3>家人与人物相册</h3>
        <p>使用本机离线视觉引擎自动聚类人脸，命名与归类仅对你的当前账号可见，不会上传云端。</p>
      </div>
      <div class="people-header-actions">
        <label class="people-toggle-hidden">
          <input v-model="includeHidden" type="checkbox" />
          显示已隐藏人物
        </label>
        <IsleButton variant="glass" size="sm" :loading="loading" @click="loadPersons">
          <RefreshCw :size="14" /><span>刷新人物</span>
        </IsleButton>
      </div>
    </header>

    <p v-if="error" class="form-error" role="alert">{{ error }}</p>

    <IsleEmpty
      v-if="!persons.length && !loading"
      card
      :icon="Users"
      title="暂未发现已归类的人物面孔"
      description="照片扫描完成后，Mac 会在后台自动识别清晰人脸并建立聚类；稍后刷新即可为宝宝或家人命名。"
    />

    <div v-else class="people-grid">
      <div
        v-for="person in persons"
        :key="person.id"
        class="person-card"
        :class="{ 'is-hidden': person.hidden }"
      >
        <div class="person-card-menu" @click.stop>
          <IsleActionMenu size="sm" align="right" :aria-label="'管理人物：' + (person.name || '未命名人物')">
            <button type="button" :disabled="busy" @click="beginRename(person)">
              <Pencil :size="14" /> 命名 / 改名
            </button>
            <button v-if="persons.length > 1" type="button" :disabled="busy" @click="beginMerge(person)">
              <GitMerge :size="14" /> 合并重复聚类
            </button>
            <button type="button" :disabled="busy" @click="openShare(person)">
              <Share2 :size="14" /> 共享此人物视图
            </button>
            <button type="button" :disabled="busy" @click="toggleHidden(person)">
              <Eye v-if="person.hidden" :size="14" /><EyeOff v-else :size="14" />
              {{ person.hidden ? "恢复显示" : "隐藏人物" }}
            </button>
          </IsleActionMenu>
        </div>

        <button
          type="button"
          class="person-avatar-btn"
          :title="'查看「' + (person.name || '未命名人物') + '」的照片'"
          @click="emit('select-person', { id: person.id, name: person.name })"
        >
          <span class="person-avatar-ring">
            <img
              v-if="person.coverFaceId && !failedAvatars[person.id]"
              :src="mediaPath('/api/v2/photos/faces/' + person.coverFaceId + '/thumbnail')"
              :alt="person.name || '人物头像'"
              :class="{ 'is-loaded': loadedAvatars[person.id] }"
              loading="lazy"
              decoding="async"
              @load="onAvatarLoad($event, person.id)"
              @error="failedAvatars[person.id] = true"
            />
            <Users v-else :size="28" />
          </span>
          <strong class="person-name">{{ person.name || "点击命名人物" }}</strong>
          <small class="person-count">{{ person.photoCount }} 张照片<span v-if="person.hidden"> · 已隐藏</span></small>
        </button>
      </div>
    </div>

    <IsleModal v-if="editingPerson" title="命名人物" size="sm" @close="editingPerson = null">
      <template #icon><Pencil :size="16" /></template>
      <form class="person-modal-form" @submit.prevent="saveRename">
        <label class="person-modal-field">
          <span>姓名或称呼</span>
          <input
            ref="renameInputRef"
            v-model="editingName"
            maxlength="40"
            placeholder="例如：宝宝、妈妈…"
            aria-label="人物姓名"
          />
        </label>
        <div class="person-modal-actions">
          <IsleButton variant="glass" size="sm" :disabled="busy" @click="editingPerson = null">取消</IsleButton>
          <IsleButton type="submit" variant="primary" size="sm" :loading="busy">保存</IsleButton>
        </div>
      </form>
    </IsleModal>

    <IsleModal v-if="mergingSource" :title="`合并「${mergingSource.name || '未命名人物 #' + mergingSource.id}」`" size="sm" @close="mergingSource = null">
      <template #icon><GitMerge :size="16" /></template>
      <div class="person-modal-form">
        <p class="person-modal-hint">将这个聚类下的所有人脸与照片记录合并到同一人名下，原照片不会有任何移动或修改。</p>
        <AppleSelect
          v-model="mergeTargetId"
          :options="mergeTargetOptions"
          :disabled="busy"
          size="sm"
          block
          aria-label="选择合并目标人物"
        />
        <div class="person-modal-actions">
          <IsleButton variant="glass" size="sm" :disabled="busy" @click="mergingSource = null">取消</IsleButton>
          <IsleButton variant="primary" size="sm" :loading="busy" :disabled="!mergeTargetId" @click="confirmMerge">确认合并</IsleButton>
        </div>
      </div>
    </IsleModal>

    <PhotoPersonSharesSection
      ref="sharesSectionRef"
      :active="active"
      :root-key="rootKey"
      :persons="persons"
      :api="api"
      :api-path="apiPath"
      :media-path="mediaPath"
    />
  </section>
</template>

<style scoped>
.people-view {
  display: flex;
  flex-direction: column;
  gap: 14px;
}
.people-header {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
}
.people-header h3 {
  margin: 0 0 3px;
  font-size: 15.5px;
  font-weight: 650;
}
.people-header p {
  margin: 0;
  font-size: 12.5px;
  color: var(--text-secondary);
}
.people-header-actions {
  display: flex;
  align-items: center;
  gap: 10px;
}
.people-toggle-hidden {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 12.5px;
  color: var(--text-secondary);
  cursor: pointer;
}
.people-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(min(100%, 144px), 1fr));
  gap: 12px;
}
.person-card {
  position: relative;
  min-width: 0;
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: 16px 10px 14px;
  border-radius: 16px;
  background: var(--fluid-card-fill);
  border: 1px solid var(--fluid-card-border);
  box-shadow: var(--fluid-item-card-shadow);
  content-visibility: auto;
  contain-intrinsic-size: 150px 158px;
  transition: transform var(--motion-fast) var(--motion-spring), border-color var(--motion-fast) ease, background-color var(--motion-fast) ease;
}
.person-card:hover {
  transform: translateY(-2px);
  border-color: var(--fluid-card-border-strong, var(--accent-primary));
  background: var(--fluid-card-hover);
}
.person-card.is-hidden {
  opacity: 0.62;
}
.person-card-menu {
  position: absolute;
  top: 8px;
  right: 8px;
  z-index: 3;
  opacity: 0;
  transform: translate3d(0, -2px, 0);
  transition: opacity 0.16s ease, transform 0.18s ease;
}
.person-card:hover .person-card-menu,
.person-card:focus-within .person-card-menu,
.person-card-menu:has([aria-expanded="true"]) {
  opacity: 1;
  transform: translate3d(0, 0, 0);
}
@media (hover: none) {
  .person-card-menu {
    opacity: 1;
    transform: none;
  }
}
.person-avatar-btn {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 7px;
  background: none;
  border: none;
  color: inherit;
  cursor: pointer;
  width: 100%;
  padding: 0;
}
.person-avatar-ring {
  width: 84px;
  height: 84px;
  border-radius: 50%;
  overflow: hidden;
  display: flex;
  align-items: center;
  justify-content: center;
  background: var(--fluid-card-item-fill);
  border: 1.5px solid var(--fluid-card-border-strong, var(--fluid-card-border));
  box-shadow: 0 4px 14px rgba(0, 0, 0, 0.08);
  color: var(--text-secondary);
}
.person-avatar-ring img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  opacity: 0;
  transition: opacity 0.28s ease, transform 0.32s cubic-bezier(0.22, 1, 0.36, 1);
}
.person-avatar-ring img.is-loaded {
  opacity: 1;
}
.person-card:hover .person-avatar-ring img.is-loaded {
  transform: scale(1.04);
}
.person-name {
  font-size: 13.5px;
  font-weight: 620;
  max-width: 100%;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.person-count {
  font-size: 11.5px;
  font-variant-numeric: tabular-nums;
  color: var(--text-secondary);
}
.person-modal-form {
  display: grid;
  gap: 12px;
}
.person-modal-field {
  display: grid;
  gap: 6px;
  font-size: 12.5px;
  font-weight: 600;
  color: var(--text-primary);
}
.person-modal-field input {
  width: 100%;
  height: 36px;
  padding: 0 11px;
  font-size: 13px;
  border-radius: 10px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  color: inherit;
  box-sizing: border-box;
}
.person-modal-hint {
  margin: 0;
  font-size: 12.5px;
  line-height: 1.5;
  color: var(--text-secondary);
}
.person-modal-actions {
  display: flex;
  justify-content: flex-end;
  gap: 8px;
}
@media (prefers-reduced-motion: reduce) {
  .person-card,
  .person-card-menu,
  .person-avatar-ring img {
    transition: none;
  }
}
</style>
