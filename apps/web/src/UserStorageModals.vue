<script setup lang="ts">
import { ArrowRightLeft, CheckCircle2, AlertTriangle, RefreshCw } from "lucide-vue-next";
import IsleButton from "./IsleButton.vue";
import IsleBanner from "./IsleBanner.vue";
import IsleModal from "./IsleModal.vue";
import AppleSelect, { type SelectOption } from "./AppleSelect.vue";

export type CategoryDef = {
  id: string;
  label: string;
  shortLabel: string;
};

export type SwitchTransferState = {
  phase?: string;
  mode?: string;
  sourceRootID?: string;
  sourceGeneration?: number;
  targetRootID?: string;
  targetGeneration?: number;
  categories?: string[];
  bytesCopied?: number;
  totalBytes?: number;
  filesCopied?: number;
  totalFiles?: number;
  filesVerified?: number;
  error?: string;
};

defineProps<{
  showAllocModal: boolean;
  allocRootId: string;
  onlineRootOptions: SelectOption[];
  allocCategories: Record<string, boolean>;
  allocQuotaGiB: string;
  allocSubdirs: string;
  allocBusy: boolean;
  allocError: string;
  allocUnlimited: boolean;
  categories: CategoryDef[];
  showMigrateModal: boolean;
  migrateSourceName: string;
  migrateTargetName: string;
  migrateSourceCompound: string;
  migrateSourceOptions: SelectOption[];
  migrateTargetRootId: string;
  migrateTargetOptions: SelectOption[];
  migrateCategories: Record<string, boolean>;
  migrateMode: "migrate" | "copy" | "empty";
  migrateQuotaGiB: string;
  migratePassword: string;
  migrateBusy: boolean;
  migrateError: string;
  migrateStatus: SwitchTransferState | null;
  prettyBytes: (bytes: number | null | undefined) => string;
  migrationPhaseLabel: (phase?: string) => string;
}>();

const emit = defineEmits<{
  (e: "update:showAllocModal", val: boolean): void;
  (e: "update:allocRootId", val: string): void;
  (e: "update:allocQuotaGiB", val: string): void;
  (e: "update:allocSubdirs", val: string): void;
  (e: "submitAllocation"): void;
  (e: "update:showMigrateModal", val: boolean): void;
  (e: "update:migrateSourceCompound", val: string): void;
  (e: "update:migrateTargetRootId", val: string): void;
  (e: "update:migrateMode", val: "migrate" | "copy" | "empty"): void;
  (e: "update:migrateQuotaGiB", val: string): void;
  (e: "update:migratePassword", val: string): void;
  (e: "startMigration"): void;
  (e: "confirmMigrationCleanup"): void;
  (e: "cancelMigration"): void;
}>();
</script>

<template>
  <!-- MODAL 1: 分配存储目录 -->
  <IsleModal
    :model-value="showAllocModal"
    title="为用户分配存储目录"
    max-width="520px"
    @update:model-value="emit('update:showAllocModal', $event)"
  >
    <div class="modal-form">
      <IsleBanner v-if="allocError" type="error" compact :message="allocError" />

      <div class="form-field">
        <label class="field-label">目标在线存储目录</label>
        <AppleSelect
          :model-value="allocRootId"
          :options="onlineRootOptions"
          placeholder="请选择已就绪的存储目录…"
          block
          @update:model-value="emit('update:allocRootId', String($event ?? ''))"
        />
        <small class="field-hint">支持默认主目录或任意已通过整盘读写校验的扩展目录。</small>
      </div>

      <div class="form-field">
        <label class="field-label">勾选要在此目录开通的空间分类</label>
        <div class="checkbox-group">
          <label v-for="cat in categories" :key="cat.id" class="checkbox-pill">
            <input v-model="allocCategories[cat.id]" type="checkbox" />
            <span>{{ cat.label }}</span>
          </label>
        </div>
      </div>

      <div v-if="!allocUnlimited" class="form-field">
        <label class="field-label">该目录配额上限 (GiB)</label>
        <div class="quota-input-row">
          <input
            :value="allocQuotaGiB"
            type="number"
            min="1"
            class="isle-input"
            placeholder="100"
            @input="emit('update:allocQuotaGiB', ($event.target as HTMLInputElement).value)"
          />
          <div class="quota-presets">
            <button
              v-for="preset in [50, 100, 200, 500, 1024]"
              :key="preset"
              type="button"
              class="preset-chip"
              @click="emit('update:allocQuotaGiB', String(preset))"
            >
              {{ preset >= 1024 ? "1 TB" : preset + " GB" }}
            </button>
          </div>
        </div>
      </div>

      <div class="form-field">
        <label class="field-label">初始化新建子文件夹（可选，用英文逗号分隔）</label>
        <input
          :value="allocSubdirs"
          type="text"
          class="isle-input"
          placeholder="例如：files/工作文档, photos/家庭相册, videos/电影"
          @input="emit('update:allocSubdirs', ($event.target as HTMLInputElement).value)"
        />
      </div>
    </div>

    <template #footer>
      <IsleButton variant="ghost" @click="emit('update:showAllocModal', false)">取消</IsleButton>
      <IsleButton variant="primary" :loading="allocBusy" @click="emit('submitAllocation')">
        确认分配并创建目录
      </IsleButton>
    </template>
  </IsleModal>

  <!-- MODAL 2: 旧目录 → 新目录数据迁移向导 -->
  <IsleModal
    :model-value="showMigrateModal"
    title="旧目录 → 新目录数据迁移向导"
    max-width="580px"
    @update:model-value="emit('update:showMigrateModal', $event)"
  >
    <div class="modal-form">
      <div class="migration-route-pill">
        <div class="route-node">
          <span class="node-tag">旧目录</span>
          <strong>{{ migrateSourceName }}</strong>
        </div>
        <ArrowRightLeft :size="16" class="route-arrow" />
        <div class="route-node is-target">
          <span class="node-tag">新目录</span>
          <strong>{{ migrateTargetName }}</strong>
        </div>
      </div>

      <IsleBanner v-if="migrateError" type="error" compact :message="migrateError" />

      <div v-if="migrateStatus && migrateStatus.phase" class="migration-status-card">
        <div class="status-header">
          <CheckCircle2
            v-if="migrateStatus.phase === 'completed' || migrateStatus.phase === 'ready_to_cleanup'"
            :size="16"
            class="status-icon ok"
          />
          <AlertTriangle
            v-else-if="migrateStatus.phase === 'failed'"
            :size="16"
            class="status-icon err"
          />
          <RefreshCw v-else :size="16" class="status-icon spin" />
          <strong>{{ migrationPhaseLabel(migrateStatus.phase) }}</strong>
        </div>

        <div
          v-if="migrateStatus.totalBytes && migrateStatus.totalBytes > 0"
          class="capacity-bar-track"
        >
          <div
            class="capacity-bar-fill"
            :style="{
              width:
                Math.min(
                  100,
                  Math.round(((migrateStatus.bytesCopied || 0) / migrateStatus.totalBytes) * 100)
                ) + '%',
            }"
          />
        </div>

        <small class="status-stats">
          已复制 {{ migrateStatus.filesCopied ?? 0 }} / {{ migrateStatus.totalFiles ?? 0 }} 个文件
          （{{ prettyBytes(migrateStatus.bytesCopied ?? 0) }} /
          {{ prettyBytes(migrateStatus.totalBytes ?? 0) }}）
          <template v-if="migrateStatus.filesVerified">
            · 已校验 {{ migrateStatus.filesVerified }} 个文件
          </template>
        </small>

        <p v-if="migrateStatus.error" class="status-error-detail">
          错误详情：{{ migrateStatus.error }}（若因目标盘缺少读写权限导致失败，请在 Mac 端「设置 → 权限与初始化」中一键修复整盘读写权限后重试，旧目录原文件完好无损）。
        </p>
      </div>

      <div v-if="migrateSourceOptions.length > 1" class="form-field">
        <label class="field-label">1. 选择要迁出的旧目录</label>
        <AppleSelect
          :model-value="migrateSourceCompound"
          :options="migrateSourceOptions"
          placeholder="选择旧目录…"
          block
          @update:model-value="emit('update:migrateSourceCompound', String($event ?? ''))"
        />
      </div>

      <div class="form-field">
        <label class="field-label">2. 选择要迁入的目标新目录</label>
        <AppleSelect
          :model-value="migrateTargetRootId"
          :options="migrateTargetOptions"
          placeholder="请选择已登记的在线新目录…"
          block
          @update:model-value="emit('update:migrateTargetRootId', String($event ?? ''))"
        />
        <small v-if="!migrateTargetOptions.length" class="field-hint warn">
          当前没有其他在线目录可选。请先在 Mac 管理端「存储 → 存储位置」添加新的存储目录并完成整盘读写授权。
        </small>
      </div>

      <div class="form-field">
        <label class="field-label">3. 勾选要一起迁移到新目录的空间分类</label>
        <div class="checkbox-group">
          <label v-for="cat in categories" :key="cat.id" class="checkbox-pill">
            <input v-model="migrateCategories[cat.id]" type="checkbox" />
            <span>{{ cat.label }}</span>
          </label>
        </div>
      </div>

      <div class="form-field">
        <label class="field-label">4. 选择迁移方式</label>
        <div class="mode-cards">
          <label
            class="mode-card"
            :class="{ active: migrateMode === 'migrate' }"
            @click="emit('update:migrateMode', 'migrate')"
          >
            <input :checked="migrateMode === 'migrate'" type="radio" value="migrate" />
            <div>
              <strong>复制并核验后回收旧目录（推荐）</strong>
              <small>完整复制到新目录并逐文件核验通过后，再由你确认将旧目录源文件移入回收站。</small>
            </div>
          </label>
          <label
            class="mode-card"
            :class="{ active: migrateMode === 'copy' }"
            @click="emit('update:migrateMode', 'copy')"
          >
            <input :checked="migrateMode === 'copy'" type="radio" value="copy" />
            <div>
              <strong>仅复制到新目录（保留两份）</strong>
              <small>复制到新目录并切换绑定，旧目录中的原文件保留不动。</small>
            </div>
          </label>
          <label
            class="mode-card"
            :class="{ active: migrateMode === 'empty' }"
            @click="emit('update:migrateMode', 'empty')"
          >
            <input :checked="migrateMode === 'empty'" type="radio" value="empty" />
            <div>
              <strong>直接启用空白新目录（旧盘已拔除或无需搬移）</strong>
              <small>在新目录创建空白用户目录并切换绑定，不读取旧目录文件。</small>
            </div>
          </label>
        </div>
      </div>

      <div class="form-row-two">
        <div class="form-field">
          <label class="field-label">新目录配额 (GiB，留空沿用原配额)</label>
          <input
            :value="migrateQuotaGiB"
            type="number"
            min="1"
            class="isle-input"
            placeholder="沿用原配额"
            @input="emit('update:migrateQuotaGiB', ($event.target as HTMLInputElement).value)"
          />
        </div>
        <div class="form-field">
          <label class="field-label">当前管理员密码（二次验证）</label>
          <input
            :value="migratePassword"
            type="password"
            class="isle-input"
            placeholder="输入管理员登录密码"
            autocomplete="current-password"
            @input="emit('update:migratePassword', ($event.target as HTMLInputElement).value)"
          />
        </div>
      </div>
    </div>

    <template #footer>
      <IsleButton variant="ghost" @click="emit('update:showMigrateModal', false)">关闭</IsleButton>
      <IsleButton
        v-if="
          migrateStatus?.phase === 'copying' ||
          migrateStatus?.phase === 'verifying' ||
          migrateStatus?.phase === 'ready_to_cleanup'
        "
        variant="danger"
        :loading="migrateBusy"
        @click="emit('cancelMigration')"
      >
        取消迁移
      </IsleButton>
      <IsleButton
        v-if="migrateStatus?.phase === 'ready_to_cleanup'"
        variant="primary"
        :loading="migrateBusy"
        @click="emit('confirmMigrationCleanup')"
      >
        确认回收旧目录源文件并完成
      </IsleButton>
      <IsleButton
        v-else
        variant="primary"
        :loading="migrateBusy"
        :disabled="!migrateTargetOptions.length"
        @click="emit('startMigration')"
      >
        开始迁移到新目录
      </IsleButton>
    </template>
  </IsleModal>
</template>

<style scoped>
.modal-form {
  display: flex;
  flex-direction: column;
  gap: 14px;
}
.form-field {
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.form-row-two {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(210px, 1fr));
  gap: 12px;
}
.field-label {
  font-size: 12.5px;
  font-weight: 600;
  color: var(--text-primary);
}
.field-hint,
.status-stats {
  font-size: 11.5px;
  color: var(--text-secondary);
}
.field-hint.warn {
  color: var(--warning, #ff9500);
}
.isle-input {
  border: 1px solid var(--fluid-card-border);
  border-radius: 10px;
  padding: 7px 11px;
  font-size: 13px;
  background: var(--fluid-card-fill);
  color: var(--text-primary);
  outline: none;
}
.isle-input:focus {
  border-color: var(--accent, #007aff);
}
.quota-input-row,
.checkbox-group,
.quota-presets {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}
.preset-chip {
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-fill);
  border-radius: 999px;
  padding: 3px 9px;
  font-size: 11.5px;
  cursor: pointer;
  color: var(--text-primary);
}
.checkbox-pill {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 6px 12px;
  border-radius: 999px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-fill);
  font-size: 12.5px;
  cursor: pointer;
}
.migration-route-pill {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 12px 16px;
  border-radius: 14px;
  background: rgba(0, 122, 255, 0.07);
  border: 1px solid rgba(0, 122, 255, 0.2);
}
.route-node {
  display: flex;
  flex-direction: column;
  gap: 2px;
  font-size: 13px;
}
.node-tag {
  font-size: 11px;
  color: var(--text-secondary);
}
.route-arrow {
  color: var(--accent, #007aff);
  flex-shrink: 0;
}
.mode-cards {
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.mode-card {
  display: flex;
  align-items: flex-start;
  gap: 10px;
  padding: 10px 12px;
  border-radius: 12px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-fill);
  cursor: pointer;
}
.mode-card.active {
  border-color: var(--accent, #007aff);
  background: rgba(0, 122, 255, 0.06);
}
.mode-card strong {
  display: block;
  font-size: 13px;
  margin-bottom: 2px;
}
.mode-card small {
  font-size: 11.5px;
  color: var(--text-secondary);
}
.migration-status-card {
  padding: 12px 14px;
  border-radius: 12px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-fill);
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.status-header {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 13px;
}
.status-icon.ok {
  color: #34c759;
}
.status-icon.err {
  color: #ff3b30;
}
.status-icon.spin {
  color: var(--accent, #007aff);
  animation: spin 1.2s linear infinite;
}
.capacity-bar-track {
  width: 100%;
  height: 6px;
  border-radius: 999px;
  background: var(--stroke-subtle, rgba(120, 120, 128, 0.16));
  overflow: hidden;
}
.capacity-bar-fill {
  height: 100%;
  border-radius: 999px;
  background: linear-gradient(90deg, var(--accent, #007aff), #32ade6);
}
.status-error-detail {
  margin: 0;
  font-size: 12px;
  color: #ff3b30;
}
@keyframes spin {
  to {
    transform: rotate(360deg);
  }
}
</style>
