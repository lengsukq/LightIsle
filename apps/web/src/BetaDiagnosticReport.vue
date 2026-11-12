<script setup lang="ts">
import { ref } from "vue";
import { FileText, Download, Copy, Check } from "lucide-vue-next";
import { localDiagnosticReport } from "./betaDiagnostics.ts";
import IsleCard from "./IsleCard.vue";
import IsleButton from "./IsleButton.vue";

const preview = ref("");
const copied = ref(false);

function togglePreview() {
  copied.value = false;
  preview.value = preview.value ? "" : localDiagnosticReport();
}

function copyReport() {
  if (!preview.value || !navigator.clipboard) return;
  navigator.clipboard.writeText(preview.value).then(() => {
    copied.value = true;
    window.setTimeout(() => {
      copied.value = false;
    }, 2000);
  }).catch(() => {});
}

function exportReport() {
  const url = URL.createObjectURL(new Blob([preview.value], { type: "application/json" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = "lightisle-web-diagnostics.json";
  link.click();
  window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}
</script>

<template>
  <IsleCard
    title="Beta 故障报告"
    subtitle="生成当前浏览器会话的脱敏诊断摘要（仅含错误码、请求编号与耗时，不含密码、路径或文件名）。"
  >
    <template #icon><FileText :size="18" /></template>
    <template #actions>
      <IsleButton variant="glass" size="sm" @click="togglePreview">
        {{ preview ? "收起报告" : "预览本机报告" }}
      </IsleButton>
    </template>

    <div v-if="preview" class="diag-preview-box">
      <p class="diag-hint">可从下方复制故障编号，或导出 JSON 报告后发送给开发者排查。</p>
      <textarea
        class="diag-textarea"
        :value="preview"
        readonly
        rows="8"
        aria-label="本机诊断报告"
        spellcheck="false"
      />
      <div class="diag-actions">
        <IsleButton variant="glass" size="sm" @click="copyReport">
          <template #icon>
            <Check v-if="copied" :size="14" />
            <Copy v-else :size="14" />
          </template>
          {{ copied ? "已复制内容" : "复制报告内容" }}
        </IsleButton>
        <IsleButton variant="primary" size="sm" @click="exportReport">
          <template #icon><Download :size="14" /></template>
          导出报告文件
        </IsleButton>
      </div>
    </div>
  </IsleCard>
</template>

<style scoped>
.diag-preview-box {
  display: flex;
  flex-direction: column;
  gap: 12px;
}
.diag-hint {
  margin: 0;
  font-size: 12.5px;
  color: var(--text-secondary);
}
.diag-textarea {
  width: 100%;
  box-sizing: border-box;
  padding: 12px 14px;
  border-radius: 12px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-bottom);
  color: var(--text-primary);
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-size: 12px;
  line-height: 1.55;
  resize: vertical;
  outline: none;
}
.diag-textarea:focus {
  border-color: var(--accent-primary);
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent-primary) 18%, transparent);
}
.diag-actions {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 10px;
  flex-wrap: wrap;
}
</style>
