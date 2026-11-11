<script setup lang="ts">
import { ref } from "vue";
import { localDiagnosticReport } from "./betaDiagnostics.ts";
import IsleButton from "./IsleButton.vue";

const preview = ref("");

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
  <section class="account-panel">
    <div class="account-heading">
      <h3>Beta 故障报告</h3>
      <IsleButton variant="glass" size="sm" @click="preview = preview ? '' : localDiagnosticReport()">
        {{ preview ? "关闭预览" : "预览本机报告" }}
      </IsleButton>
    </div>
    <template v-if="preview">
      <p>可从报告复制故障编号，或保存后手动发给开发者。</p>
      <textarea :value="preview" readonly rows="8" aria-label="本机诊断报告" style="width:100%" />
      <IsleButton variant="primary" size="sm" @click="exportReport">保存报告</IsleButton>
    </template>
  </section>
</template>
