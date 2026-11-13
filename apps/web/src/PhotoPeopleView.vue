<script setup lang="ts">
import { computed, onMounted, ref, watch } from "vue";
import { Users, RefreshCw, Pencil, EyeOff, Eye, GitMerge } from "lucide-vue-next";
import IsleEmpty from "./IsleEmpty.vue";
import IsleButton from "./IsleButton.vue";
import AppleSelect from "./AppleSelect.vue";
import PhotoPersonSharesSection from "./PhotoPersonSharesSection.vue";
import { describeUserFacingError } from "./userFacingError.ts";
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
const editingId = ref<number | null>(null);
const editingName = ref("");
const mergingSourceId = ref<number | null>(null);
const mergeTargetId = ref<string>("");
const busy = ref(false);
const failedAvatars = ref<Record<number, boolean>>({});

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
  editingId.value = p.id;
  editingName.value = p.name;
  mergingSourceId.value = null;
}

async function saveRename(p: PersonSummary) {
  if (busy.value) return;
  busy.value = true;
  error.value = "";
  try {
    await props.api(props.apiPath(`/api/v2/photos/persons/${p.id}`), "PATCH", { name: editingName.value.trim() });
    editingId.value = null;
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
    .filter((item) => item.id !== mergingSourceId.value)
    .map((other) => ({
      value: String(other.id),
      label: `合并到：${other.name || "未命名 #" + other.id}`,
      hint: `${other.photoCount} 张`,
    })),
);

function beginMerge(p: PersonSummary) {
  mergingSourceId.value = mergingSourceId.value === p.id ? null : p.id;
  editingId.value = null;
  const candidate = persons.value.find((other) => other.id !== p.id);
  mergeTargetId.value = candidate ? String(candidate.id) : "";
}

async function confirmMerge(source: PersonSummary) {
  const targetId = Number(mergeTargetId.value);
  if (!targetId || targetId === source.id || busy.value) return;
  busy.value = true;
  error.value = "";
  try {
    await props.api(props.apiPath(`/api/v2/photos/persons/${source.id}/merge`), "POST", { targetPersonId: targetId });
    mergingSourceId.value = null;
    await loadPersons();
  } catch (e) {
    error.value = "合并人物失败：" + describeUserFacingError(e);
  } finally {
    busy.value = false;
  }
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
      :icon="Users"
      :icon-size="42"
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
              loading="lazy"
              decoding="async"
              @error="failedAvatars[person.id] = true"
            />
            <Users v-else :size="30" />
          </span>
          <strong class="person-name">{{ person.name || "点击命名人物" }}</strong>
          <small class="person-count">{{ person.photoCount }} 张照片<span v-if="person.hidden"> · 已隐藏</span></small>
        </button>

        <div class="person-actions">
          <button type="button" class="person-mini-btn" :disabled="busy" title="修改姓名" @click="beginRename(person)">
            <Pencil :size="12" /> 命名
          </button>
          <button
            v-if="persons.length > 1"
            type="button"
            class="person-mini-btn"
            :disabled="busy"
            title="与同一人的其他分组聚类合并"
            @click="beginMerge(person)"
          >
            <GitMerge :size="12" /> 合并
          </button>
          <button type="button" class="person-mini-btn" :disabled="busy" @click="toggleHidden(person)">
            <Eye v-if="person.hidden" :size="12" /><EyeOff v-else :size="12" />
            {{ person.hidden ? "恢复" : "隐藏" }}
          </button>
        </div>

        <form v-if="editingId === person.id" class="person-inline-form" @submit.prevent="saveRename(person)">
          <input
            v-model="editingName"
            maxlength="40"
            placeholder="例如：宝宝、妈妈…"
            aria-label="人物姓名"
          />
          <button type="submit" :disabled="busy">保存</button>
          <button type="button" class="secondary" @click="editingId = null">取消</button>
        </form>

        <div v-if="mergingSourceId === person.id" class="person-inline-form">
          <AppleSelect
            v-model="mergeTargetId"
            :options="mergeTargetOptions"
            :disabled="busy"
            size="sm"
            block
            aria-label="选择合并目标人物"
          />
          <button type="button" :disabled="busy || !mergeTargetId" @click="confirmMerge(person)">确认合并</button>
          <button type="button" class="secondary" @click="mergingSourceId = null">取消</button>
        </div>
      </div>
    </div>

    <PhotoPersonSharesSection
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
  gap: 16px;
}
.people-header {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}
.people-header h3 {
  margin: 0 0 4px;
  font-size: 17px;
}
.people-header p {
  margin: 0;
  font-size: 13px;
  color: var(--text-secondary, #6e6e73);
}
.people-header-actions {
  display: flex;
  align-items: center;
  gap: 12px;
}
.people-toggle-hidden {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 13px;
  cursor: pointer;
}
.people-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(175px, 1fr));
  gap: 14px;
}
.person-card {
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: 16px 12px 12px;
  border-radius: 16px;
  background: var(--surface-card, rgba(255, 255, 255, 0.72));
  border: 1px solid var(--border-subtle, rgba(0, 0, 0, 0.07));
  gap: 10px;
  content-visibility: auto;
  contain-intrinsic-size: 175px 190px;
  transition: transform var(--motion-fast) var(--motion-spring), opacity var(--motion-fast) ease;
}
.person-card:hover {
  transform: translateY(-2px);
}
.person-card:active {
  transform: scale(0.985);
}
.person-card.is-hidden {
  opacity: 0.65;
}
.person-avatar-btn {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 8px;
  background: none;
  border: none;
  color: inherit;
  cursor: pointer;
  width: 100%;
}
.person-avatar-ring {
  width: 88px;
  height: 88px;
  border-radius: 50%;
  overflow: hidden;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(120, 120, 128, 0.12);
  box-shadow: 0 4px 14px rgba(0, 0, 0, 0.08);
}
.person-avatar-ring img {
  width: 100%;
  height: 100%;
  object-fit: cover;
}
.person-name {
  font-size: 14px;
  max-width: 150px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.person-count {
  font-size: 12px;
  color: var(--text-secondary, #6e6e73);
}
.person-actions {
  display: flex;
  flex-wrap: wrap;
  justify-content: center;
  gap: 6px;
}
.person-mini-btn {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  padding: 4px 8px;
  font-size: 12px;
  border-radius: 8px;
  border: 1px solid var(--border-subtle, rgba(0, 0, 0, 0.09));
  background: transparent;
  color: inherit;
  cursor: pointer;
}
.person-inline-form {
  display: flex;
  flex-direction: column;
  gap: 6px;
  width: 100%;
}
.person-inline-form input,
.person-inline-form select {
  width: 100%;
  padding: 6px 8px;
  font-size: 12px;
  border-radius: 8px;
  border: 1px solid var(--border-subtle, rgba(0, 0, 0, 0.14));
  background: var(--surface-input, #fff);
  color: inherit;
}
.person-inline-form button {
  padding: 5px 8px;
  font-size: 12px;
  border-radius: 8px;
  border: none;
  background: var(--accent, #0071e3);
  color: #fff;
  cursor: pointer;
}
.person-inline-form button.secondary {
  background: rgba(120, 120, 128, 0.14);
  color: inherit;
}
@media (prefers-reduced-motion: reduce) {
  .person-card {
    transition: none;
  }
}
</style>
