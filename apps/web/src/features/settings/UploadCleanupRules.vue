<script setup lang="ts">
import { onMounted, onUnmounted, ref } from "vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleGroupedList from "../../components/ui/IsleGroupedList.vue";
import { apiFetch } from "../../api/apiClient.ts";
import { readApiFailure } from "../../api/apiFailure.ts";
import { describeUserFacingError } from "../../api/userFacingError.ts";

const days = ref("30");
const savedDays = ref<number | null>(null);
const busy = ref(false);
const error = ref("");
const notice = ref("");
const controller = new AbortController();
let disposed = false;

async function request(method = "GET", body?: object) {
  const response = await apiFetch("/api/v2/admin/cleanup-rules", { method, signal: controller.signal, json: body });
  if (!response.ok) throw await readApiFailure(response);
  const result = (await response.json().catch(() => ({}))) as { uploadRetentionDays?: unknown };
  if (
    !Number.isInteger(result.uploadRetentionDays) ||
    (result.uploadRetentionDays as number) < 0 ||
    (result.uploadRetentionDays as number) > 3650
  ) {
    throw new Error("invalid_response");
  }
  return result.uploadRetentionDays as number;
}

async function load() {
  if (busy.value) return;
  busy.value = true;
  error.value = "";
  try {
    const value = await request();
    if (!disposed) {
      savedDays.value = value;
      days.value = String(value);
    }
  } catch (reason) {
    if (!disposed) error.value = "无法读取清理规则：" + describeUserFacingError(reason);
  } finally {
    busy.value = false;
  }
}

async function save() {
  if (busy.value || savedDays.value === null) return;
  if (!/^\d+$/.test(days.value) || Number(days.value) > 3650) {
    error.value = "请输入 0 至 3650 天的整数。";
    return;
  }
  busy.value = true;
  error.value = "";
  notice.value = "";
  try {
    const value = await request("PUT", { uploadRetentionDays: Number(days.value) });
    if (!disposed) {
      savedDays.value = value;
      days.value = String(value);
      notice.value = "规则已保存，将用于之后开始的清理。";
    }
  } catch (reason) {
    if (!disposed) error.value = "保存结果尚未确认，请重新读取规则：" + describeUserFacingError(reason);
  } finally {
    busy.value = false;
  }
}

async function disableUntilRepaired() {
  if (busy.value) return;
  busy.value = true;
  error.value = "";
  notice.value = "";
  try {
    const value = await request("PUT", { uploadRetentionDays: 0 });
    if (!disposed) {
      savedDays.value = value;
      days.value = String(value);
      notice.value = "自动清理已关闭。核对后可重新设置保留期。";
    }
  } catch (reason) {
    if (!disposed) error.value = "无法确认清理已关闭，请检查 Mac 服务后重试：" + describeUserFacingError(reason);
  } finally {
    busy.value = false;
  }
}

onMounted(() => void load());
onUnmounted(() => {
  disposed = true;
  controller.abort();
});
</script>

<template>
  <div class="upload-cleanup-rules">
    <p>仅清理确认未发布且长期无活动的上传暂存（默认保留 30 天，填 0 关闭自动清理）；已发布文件不受影响。</p>
    <IsleBanner v-if="error" type="error" compact role="alert">
      {{ error }}
      <template #action>
        <IsleButton variant="glass" size="sm" :disabled="busy" @click="load">重新读取</IsleButton>
      </template>
    </IsleBanner>
    <div v-if="error && savedDays === null" class="cleanup-repair-row">
      <IsleButton variant="danger" size="sm" :disabled="busy" @click="disableUntilRepaired">暂停清理并修复规则</IsleButton>
    </div>
    <IsleBanner v-if="notice" type="info" compact role="status">{{ notice }}</IsleBanner>
    <IsleGroupedList variant="item" flush>
      <div class="cleanup-rule-row">
        <label class="cleanup-rule-label">
          <span>未活动保留天数</span>
          <input
            v-model="days"
            type="number"
            min="0"
            max="3650"
            step="1"
            :disabled="busy || savedDays === null"
          />
        </label>
        <IsleButton variant="primary" size="sm" :loading="busy" :disabled="busy || savedDays === null" @click="save">
          {{ busy ? "处理中…" : "保存规则" }}
        </IsleButton>
      </div>
    </IsleGroupedList>
  </div>
</template>

<style scoped>
.upload-cleanup-rules {
  margin: 2px 0;
  display: grid;
  gap: 8px;
}

.upload-cleanup-rules p {
  margin: 0;
  font-size: 12px;
  color: var(--text-secondary);
  line-height: 1.5;
}

.cleanup-repair-row {
  margin: 2px 0;
}

.cleanup-rule-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  flex-wrap: wrap;
  padding: 10px 14px;
  font-size: 12.5px;
}

.cleanup-rule-label {
  display: inline-flex;
  align-items: center;
  gap: 10px;
  font-weight: 580;
  color: var(--text-primary);
}

.upload-cleanup-rules input {
  width: 88px;
  height: 32px;
  padding: 0 10px;
  border-radius: 8px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-bottom);
  color: var(--text-primary);
  font: inherit;
  font-size: 12.5px;
  font-variant-numeric: tabular-nums;
}
</style>
