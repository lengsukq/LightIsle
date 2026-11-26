<script setup lang="ts">
import { computed } from "vue";
import { ArrowRightLeft, CheckCircle2, AlertTriangle, RefreshCw } from "lucide-vue-next";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleModal from "../../components/ui/IsleModal.vue";
import AppleSelect, { type SelectOption } from "../../components/ui/AppleSelect.vue";

export type CategoryDef = {
  id: string;
  label: string;
  shortLabel: string;
};

export type SwitchTransferState = {
  taskID?: string;
  phase?: string;
  mode?: string;
  sourceRootID?: string;
  sourceGeneration?: number;
  targetRootID?: string;
  targetGeneration?: number;
  categories?: string[];
  copiedBytes?: number;
  bytesCopied?: number;
  totalBytes?: number;
  copiedFiles?: number;
  filesCopied?: number;
  totalFiles?: number;
  verifiedFiles?: number;
  filesVerified?: number;
  deletedSourceFiles?: number;
  affectedShares?: number;
  readyToCleanup?: boolean;
  canResume?: boolean;
  canCancel?: boolean;
  confirmationToken?: string;
  error?: string;
  errorDetail?: string;
};

const props = defineProps<{
  showAllocModal: boolean;
  allocRootId: string;
  onlineRootOptions: SelectOption[];
  allocCategories: Record<string, boolean>;
  allocQuotaGiB: string;
  allocSubdirs: string;
  allocBusy: boolean;
  allocError: string;
  allocUnlimited: boolean;
  allocEnforcementPending?: boolean;
  categories: CategoryDef[];
  showMigrateModal: boolean;
  migrateUserId?: number;
  migrateUserName?: string;
  migrateUserOptions?: SelectOption[];
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
  (e: "selectMigrateUser", userId: number): void;
  (e: "update:migrateSourceCompound", val: string): void;
  (e: "update:migrateTargetRootId", val: string): void;
  (e: "update:migrateMode", val: "migrate" | "copy" | "empty"): void;
  (e: "update:migrateQuotaGiB", val: string): void;
  (e: "update:migratePassword", val: string): void;
  (e: "startMigration"): void;
  (e: "confirmMigrationCleanup"): void;
  (e: "cancelMigration"): void;
  (e: "resumeMigration"): void;
  (e: "recoverMigrationSource"): void;
}>();

const ACTIVE_MIGRATION_PHASES = new Set(["queued", "copying", "verified", "committing", "source_pending", "interrupted"]);
const migrationActiveOrPending = computed(() =>
  Boolean(props.migrateStatus?.phase && ACTIVE_MIGRATION_PHASES.has(props.migrateStatus.phase)),
);
const needsPasswordConfirmation = computed(() => {
  const phase = props.migrateStatus?.phase;
  return !migrationActiveOrPending.value || phase === "verified" || phase === "source_pending" || phase === "interrupted";
});
</script>

<template>
  <IsleModal
    :model-value="showAllocModal"
    title="为用户分配存储目录"
    size="md"
    :close-on-backdrop="!allocBusy"
    :close-on-esc="!allocBusy"
    :show-close="!allocBusy"
    @update:model-value="!allocBusy && emit('update:showAllocModal', $event)"
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
            <input v-model="allocCategories[cat.id]" type="checkbox" class="isle-checkbox" />
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
              :class="{ active: allocQuotaGiB === String(preset) }"
              @click="emit('update:allocQuotaGiB', String(preset))"
            >
              {{ preset >= 1024 ? "1024 GiB" : preset + " GiB" }}
            </button>
          </div>
        </div>
        <IsleBanner
          v-if="allocEnforcementPending !== false"
          type="info"
          compact
          message="用量统计持续校准中（暂未开启超额强制拦截）：当前用于统计展示与提醒，SMB 与直接写盘暂未强制拦截。"
        />
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
      <IsleButton variant="glass" :disabled="allocBusy" @click="emit('update:showAllocModal', false)">取消</IsleButton>
      <IsleButton variant="primary" :loading="allocBusy" @click="emit('submitAllocation')">
        确认分配并创建目录
      </IsleButton>
    </template>
  </IsleModal>

  <IsleModal
    :model-value="showMigrateModal"
    title="旧目录 → 新目录数据迁移向导"
    size="lg"
    :close-on-backdrop="!migrateBusy"
    :close-on-esc="!migrateBusy"
    :show-close="!migrateBusy"
    @update:model-value="!migrateBusy && emit('update:showMigrateModal', $event)"
  >
    <div class="modal-form">
      <div v-if="(migrateUserOptions?.length ?? 0) > 1 && !migrationActiveOrPending" class="form-field">
        <label class="field-label">选择要迁移的家庭成员</label>
        <AppleSelect
          :model-value="migrateUserId ?? null"
          :options="migrateUserOptions ?? []"
          placeholder="请选择成员…"
          block
          @update:model-value="emit('selectMigrateUser', Number($event))"
        />
      </div>
      <div v-else-if="migrateUserName" class="field-hint">
        当前迁移成员：<strong>{{ migrateUserName }}</strong>
      </div>

      <div class="migration-route-pill">
        <div class="route-node">
          <span class="node-tag">旧目录</span>
          <strong>{{ migrateSourceName }}</strong>
        </div>
        <ArrowRightLeft :size="15" class="route-arrow" />
        <div class="route-node is-target">
          <span class="node-tag">新目录</span>
          <strong>{{ migrateTargetName }}</strong>
        </div>
      </div>

      <IsleBanner v-if="migrateError" type="error" compact :message="migrateError" />

      <div v-if="migrateStatus && migrateStatus.phase" class="migration-status-card">
        <div class="status-header">
          <CheckCircle2
            v-if="migrateStatus.phase === 'completed' || migrateStatus.phase === 'verified'"
            :size="15"
            class="status-icon ok"
          />
          <AlertTriangle
            v-else-if="migrateStatus.phase === 'failed' || migrateStatus.phase === 'interrupted' || migrateStatus.phase === 'source_pending'"
            :size="15"
            class="status-icon err"
          />
          <RefreshCw v-else :size="15" class="status-icon spin" />
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
                  Math.round((((migrateStatus.copiedBytes ?? migrateStatus.bytesCopied) || 0) / migrateStatus.totalBytes) * 100)
                ) + '%',
            }"
          />
        </div>

        <small class="status-stats">
          已复制 {{ migrateStatus.copiedFiles ?? migrateStatus.filesCopied ?? 0 }} / {{ migrateStatus.totalFiles ?? 0 }} 个文件
          （{{ prettyBytes(migrateStatus.copiedBytes ?? migrateStatus.bytesCopied ?? 0) }} /
          {{ prettyBytes(migrateStatus.totalBytes ?? 0) }}）
          <template v-if="migrateStatus.verifiedFiles ?? migrateStatus.filesVerified">
            · 已校验 {{ migrateStatus.verifiedFiles ?? migrateStatus.filesVerified }} 个文件
          </template>
        </small>

        <small v-if="(migrateStatus.affectedShares ?? 0) > 0" class="field-hint warn">
          注意：切换目录后将自动撤销旧目录关联的 {{ migrateStatus.affectedShares }} 项外链或共享授权。
        </small>

        <p v-if="migrateStatus.error || migrateStatus.errorDetail" class="status-error-detail">
          错误详情：{{ migrateStatus.errorDetail || migrateStatus.error }}（若因目标盘缺少读写权限导致失败，请在 Mac 端「设置 → 权限与初始化」中一键修复整盘读写权限后重试，旧目录原文件完好无损）。
        </p>
      </div>

      <template v-if="!migrationActiveOrPending">
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
              <input v-model="migrateCategories[cat.id]" type="checkbox" class="isle-checkbox" />
              <span>{{ cat.label }}</span>
            </label>
          </div>
        </div>

        <div class="form-field">
          <label class="field-label">4. 选择迁移方式</label>
          <div class="mode-cards">
            <label class="mode-card" :class="{ active: migrateMode === 'migrate' }">
              <input
                name="migrate-mode"
                :checked="migrateMode === 'migrate'"
                type="radio"
                value="migrate"
                @change="emit('update:migrateMode', 'migrate')"
              />
              <div>
                <strong>复制并核验后回收旧目录（推荐）</strong>
                <small>完整复制到新目录并逐文件核验通过后，再由你确认将旧目录源文件移入回收站。</small>
              </div>
            </label>
            <label class="mode-card" :class="{ active: migrateMode === 'copy' }">
              <input
                name="migrate-mode"
                :checked="migrateMode === 'copy'"
                type="radio"
                value="copy"
                @change="emit('update:migrateMode', 'copy')"
              />
              <div>
                <strong>仅复制到新目录（保留两份）</strong>
                <small>复制到新目录并切换绑定，旧目录中的原文件保留不动。</small>
              </div>
            </label>
            <label class="mode-card" :class="{ active: migrateMode === 'empty' }">
              <input
                name="migrate-mode"
                :checked="migrateMode === 'empty'"
                type="radio"
                value="empty"
                @change="emit('update:migrateMode', 'empty')"
              />
              <div>
                <strong>直接启用空白新目录（旧盘已拔除或无需搬移）</strong>
                <small>在新目录创建空白用户目录并切换绑定，不读取旧目录文件。</small>
              </div>
            </label>
          </div>
        </div>
      </template>

      <div v-if="needsPasswordConfirmation" class="form-row-two">
        <div v-if="!migrationActiveOrPending" class="form-field">
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
      <IsleButton variant="glass" :disabled="migrateBusy" @click="emit('update:showMigrateModal', false)">关闭</IsleButton>
      <IsleButton
        v-if="
          migrateStatus?.phase === 'queued' ||
          migrateStatus?.phase === 'copying' ||
          migrateStatus?.phase === 'verified' ||
          (migrateStatus?.phase === 'interrupted' && migrateStatus?.canCancel)
        "
        variant="danger"
        :loading="migrateBusy"
        @click="emit('cancelMigration')"
      >
        取消迁移
      </IsleButton>
      <IsleButton
        v-if="migrateStatus?.phase === 'interrupted' && migrateStatus?.canResume"
        variant="primary"
        :loading="migrateBusy"
        @click="emit('resumeMigration')"
      >
        继续完成目录切换
      </IsleButton>
      <IsleButton
        v-else-if="migrateStatus?.phase === 'source_pending'"
        variant="primary"
        :loading="migrateBusy"
        @click="emit('recoverMigrationSource')"
      >
        重试回收旧目录源文件
      </IsleButton>
      <IsleButton
        v-else-if="migrateStatus?.phase === 'verified'"
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
        :disabled="!migrateTargetOptions.length || migrateStatus?.phase === 'queued' || migrateStatus?.phase === 'copying' || migrateStatus?.phase === 'committing'"
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
  gap: 11px;
}
.form-field {
  display: flex;
  flex-direction: column;
  gap: 5px;
}
.form-row-two {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(100%, 200px), 1fr));
  gap: 10px;
}
.field-label {
  font-size: 12px;
  font-weight: 600;
  color: var(--text-primary);
}
.field-hint,
.status-stats {
  font-size: 11.5px;
  color: var(--text-secondary);
}
.status-stats {
  font-variant-numeric: tabular-nums;
}
.field-hint.warn {
  color: var(--warning, #d97706);
}
.isle-input {
  height: 34px;
  border: 1px solid var(--fluid-card-border);
  border-radius: 9px;
  padding: 0 11px;
  font-size: 12.5px;
  font-variant-numeric: tabular-nums;
  background: var(--fluid-card-item-fill);
  color: var(--text-primary);
  outline: none;
  transition: border-color 160ms ease;
}
.isle-input:focus {
  border-color: var(--accent-primary, #2563eb);
}
.quota-input-row,
.checkbox-group,
.quota-presets {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
}
.preset-chip {
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  border-radius: 999px;
  padding: 3px 8px;
  font-size: 11px;
  font-variant-numeric: tabular-nums;
  cursor: pointer;
  color: var(--text-primary);
  transition: border-color 140ms ease, color 140ms ease, background-color 140ms ease;
}
.preset-chip:hover,
.preset-chip.active {
  border-color: var(--accent-primary, #0e6b74);
  color: var(--accent-primary, #0e6b74);
}
.checkbox-pill {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 5px 10px;
  border-radius: 999px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  font-size: 12px;
  cursor: pointer;
  transition: border-color 140ms ease, background-color 140ms ease;
}
.migration-route-pill {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  padding: 9px 13px;
  border-radius: 11px;
  background: color-mix(in srgb, var(--accent-primary) 7%, var(--fluid-card-top));
  border: 1px solid color-mix(in srgb, var(--accent-primary) 24%, var(--fluid-card-border));
}
.route-node {
  display: flex;
  flex-direction: column;
  gap: 1px;
  min-width: 0;
  overflow-wrap: anywhere;
  font-size: 12.5px;
}
.node-tag {
  font-size: 10.5px;
  color: var(--text-secondary);
}
.route-arrow {
  color: var(--accent-primary, #2563eb);
  flex-shrink: 0;
}
.mode-cards {
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.mode-card {
  display: flex;
  align-items: flex-start;
  gap: 8px;
  padding: 9px 11px;
  border-radius: 10px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  cursor: pointer;
  transition: border-color 160ms ease, background-color 160ms ease;
}
.mode-card.active {
  border-color: var(--accent-primary, #2563eb);
  background: color-mix(in srgb, var(--accent-primary) 7%, var(--fluid-card-top));
}
.mode-card strong {
  display: block;
  font-size: 12.5px;
  margin-bottom: 1px;
}
.mode-card small {
  font-size: 11px;
  color: var(--text-secondary);
}
.migration-status-card {
  padding: 10px 12px;
  border-radius: 10px;
  border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill);
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.status-header {
  display: flex;
  align-items: center;
  gap: 7px;
  font-size: 12.5px;
}
.status-icon.ok {
  color: var(--success, #10b981);
}
.status-icon.err {
  color: var(--error, #ef4444);
}
.status-icon.spin {
  color: var(--accent-primary, #2563eb);
  animation: spin 1.2s linear infinite;
}
.capacity-bar-track {
  width: 100%;
  height: 6px;
  border-radius: 999px;
  background: var(--fluid-card-border);
  overflow: hidden;
}
.capacity-bar-fill {
  height: 100%;
  border-radius: 999px;
  background: var(--accent-primary, #2563eb);
  transition: width 260ms var(--motion-spring, cubic-bezier(0.22, 1, 0.36, 1));
}
.status-error-detail {
  margin: 0;
  font-size: 11.5px;
  color: var(--error);
}
@keyframes spin {
  to {
    transform: rotate(360deg);
  }
}
@media (prefers-reduced-motion: reduce) {
  .isle-input,
  .preset-chip,
  .checkbox-pill,
  .mode-card,
  .capacity-bar-fill {
    transition: none;
  }
  .status-icon.spin {
    animation: none;
  }
}
</style>
