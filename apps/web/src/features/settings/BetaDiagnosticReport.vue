<script setup lang="ts">
import { ref } from "vue";
import { FileText, Download, Copy, Check } from "lucide-vue-next";
import { localDiagnosticReport } from "./betaDiagnostics.ts";
import { copyTextToClipboard } from "../../utils/clipboard.ts";
import { TIMINGS_MS } from "../../constants/timings.ts";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleModal from "../../components/ui/IsleModal.vue";
import IsleButton from "../../components/ui/IsleButton.vue";

const modalOpen = ref(false);
const preview = ref("");
const copied = ref(false);

function openReportModal() {
  copied.value = false;
  preview.value = localDiagnosticReport();
  modalOpen.value = true;
}

function refreshPreview() {
  copied.value = false;
  preview.value = localDiagnosticReport();
}

async function copyReport() {
  if (!preview.value) return;
  if (await copyTextToClipboard(preview.value)) {
    copied.value = true;
    window.setTimeout(() => {
      copied.value = false;
    }, TIMINGS_MS.COPIED_FEEDBACK);
  }
}

function exportReport() {
  const content = preview.value || localDiagnosticReport();
  const url = URL.createObjectURL(new Blob([content], { type: "application/json" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = "lightisle-web-diagnostics.json";
  link.click();
  window.setTimeout(() => URL.revokeObjectURL(url), TIMINGS_MS.BLOB_REVOKE_DELAY);
}
</script>

<template>
  <IsleCard
    padding="sm"
    title="本机脱敏故障报告"
    subtitle="仅含错误码与请求耗时，不含密码、路径或文件名。"
  >
    <template #icon><FileText :size="17" /></template>
    <template #actions>
      <IsleButton variant="glass" size="sm" @click="openReportModal">查看与导出</IsleButton>
    </template>
  </IsleCard>

  <IsleModal
    v-if="modalOpen"
    :open="modalOpen"
    title="本机脱敏故障报告"
    description="仅含错误码、请求编号与耗时，不含任何敏感路径或文件名。"
    size="md"
    @close="modalOpen = false"
  >
    <template #icon><FileText :size="16" /></template>
    <textarea
      class="diag-textarea"
      :value="preview"
      readonly
      rows="8"
      aria-label="本机诊断报告"
      spellcheck="false"
    />
    <template #footer>
      <IsleButton variant="glass" size="sm" @click="refreshPreview">刷新</IsleButton>
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
    </template>
  </IsleModal>
</template>

<style scoped>
.diag-textarea {
  width: 100%;
  box-sizing: border-box;
  padding: 10px 12px;
  border-radius: 11px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-bottom);
  color: var(--text-primary);
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-size: 11.5px;
  line-height: 1.5;
  resize: vertical;
  outline: none;
  transition: border-color 0.16s ease, box-shadow 0.16s ease;
}
.diag-textarea:focus {
  border-color: var(--accent-primary);
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--accent-primary) 16%, transparent);
}
@media (prefers-reduced-motion: reduce) {
  .diag-textarea {
    transition: none;
  }
}
</style>
