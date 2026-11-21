<script setup lang="ts">
import { computed, onMounted, ref, watch } from "vue";
import { Users, RefreshCw, Pencil, EyeOff, Eye, GitMerge } from "lucide-vue-next";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
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
            <Users v-else :size="26" />
          </span>
          <strong class="person-name">{{ person.name || "点击命名人物" }}</strong>
          <small class="person-count">{{ person.photoCount }} 张照片<span v-if="person.hidden"> · 已隐藏</span></small>
        </button>

        <div class="person-actions">
          <button type="button" class="person-mini-btn" :disabled="busy" title="修改姓名" @click="beginRename(person)">
            <Pencil :size="11" /> 命名
          </button>
          <button
            v-if="persons.length > 1"
            type="button"
            class="person-mini-btn"
            :disabled="busy"
            title="与同一人的其他分组聚类合并"
            @click="beginMerge(person)"
          >
            <GitMerge :size="11" /> 合并
          </button>
          <button type="button" class="person-mini-btn" :disabled="busy" @click="toggleHidden(person)">
            <Eye v-if="person.hidden" :size="11" /><EyeOff v-else :size="11" />
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
          <div class="person-inline-btns">
            <button type="submit" :disabled="busy">保存</button>
            <button type="button" class="secondary" @click="editingId = null">取消</button>
          </div>
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
          <div class="person-inline-btns">
            <button type="button" :disabled="busy || !mergeTargetId" @click="confirmMerge(person)">确认合并</button>
            <button type="button" class="secondary" @click="mergingSourceId = null">取消</button>
          </div>
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
  grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
  gap: 10px;
}
.person-card {
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: 14px 10px 11px;
  border-radius: 14px;
  background: var(--fluid-card-fill);
  border: 1px solid var(--fluid-card-border);
  box-shadow: var(--fluid-item-card-shadow);
  gap: 8px;
  content-visibility: auto;
  contain-intrinsic-size: 160px 176px;
  transition: border-color var(--motion-fast) ease, background-color var(--motion-fast) ease;
}
.person-card:hover {
  border-color: var(--fluid-card-border-strong, var(--accent-primary));
  background: var(--fluid-card-hover);
}
.person-card.is-hidden {
  opacity: 0.65;
}
.person-avatar-btn {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 6px;
  background: none;
  border: none;
  color: inherit;
  cursor: pointer;
  width: 100%;
  padding: 0;
}
.person-avatar-ring {
  width: 72px;
  height: 72px;
  border-radius: 50%;
  overflow: hidden;
  display: flex;
  align-items: center;
  justify-content: center;
  background: var(--fluid-card-item-fill);
  border: 1px solid var(--fluid-card-border);
  color: var(--text-secondary);
}
.person-avatar-ring img {
  width: 100%;
  height: 100%;
  object-fit: cover;
}
.person-name {
  font-size: 13px;
  font-weight: 600;
  max-width: 140px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.person-count {
  font-size: 11.5px;
  color: var(--text-secondary);
}
.person-actions {
  display: flex;
  flex-wrap: wrap;
  justify-content: center;
  gap: 5px;
}
.person-mini-btn {
  display: inline-flex;
  align-items: center;
  gap: 3px;
  padding: 3px 7px;
  font-size: 11.5px;
  border-radius: 7px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  color: var(--text-secondary);
  cursor: pointer;
}
.person-mini-btn:hover:not(:disabled) {
  color: var(--text-primary);
  border-color: var(--fluid-card-border-strong, var(--accent-primary));
}
.person-inline-form {
  display: flex;
  flex-direction: column;
  gap: 6px;
  width: 100%;
}
.person-inline-form input {
  width: 100%;
  height: 30px;
  padding: 0 8px;
  font-size: 12px;
  border-radius: 7px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  color: inherit;
  box-sizing: border-box;
}
.person-inline-btns {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 5px;
}
.person-inline-form button {
  padding: 5px 8px;
  font-size: 11.5px;
  font-weight: 600;
  border-radius: 7px;
  border: 1px solid transparent;
  background: var(--accent-primary, #2563eb);
  color: #fff;
  cursor: pointer;
}
.person-inline-form button.secondary {
  background: var(--fluid-card-item-fill);
  border-color: var(--fluid-card-border);
  color: var(--text-primary);
}
@media (prefers-reduced-motion: reduce) {
  .person-card {
    transition: none;
  }
}
</style>
