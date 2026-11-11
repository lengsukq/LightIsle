<script setup lang="ts">
import {
  HardDrive, FolderGit2, ArrowRightLeft, Plus, RefreshCw, ShieldCheck, Sliders,
} from "lucide-vue-next";
import IsleButton from "./IsleButton.vue";
import IsleBanner from "./IsleBanner.vue";
import IsleBadge from "./IsleBadge.vue";
import IsleCard from "./IsleCard.vue";
import UserStorageModals from "./UserStorageModals.vue";
import DuplicateFilesPanel from "./DuplicateFilesPanel.vue";
import {
  STORAGE_CATEGORIES as categories,
  categoryShortLabel,
  prettyBytes,
  migrationPhaseLabel,
  useUserStoragePanel,
} from "./useUserStoragePanel.ts";

const props = defineProps<{ admin: boolean; mode?: "all" | "roots" | "users" }>();

const {
  users,
  roots,
  registeredRoots,
  rootsKnown,
  policies,
  pending,
  error,
  successMessage,
  usageChecks,
  editingQuotaKey,
  editingQuotaGiB,
  savingQuota,
  showAllocModal,
  allocRootId,
  allocQuotaGiB,
  allocCategories,
  allocSubdirs,
  allocBusy,
  allocError,
  allocTargetPolicy,
  onlineRootOptions,
  showMigrateModal,
  migrateSourceRootId,
  migrateTargetRootId,
  migrateCategories,
  migrateMode,
  migrateQuotaGiB,
  migratePassword,
  migrateBusy,
  migrateError,
  migrateStatus,
  migrateTargetOptions,
  migrateSourceOptions,
  migrateSourceCompound,
  findRoot,
  rootNameById,
  rootName,
  isActiveRoot,
  allocatedDiskCount,
  diskLocations,
  rootAvailable,
  isUserUnlimited,
  boundCountForRoot,
  firstUserBoundToRoot,
  load,
  checkOnlineUsage,
  selectedLocation,
  rootLabel,
  startEditQuota,
  saveQuota,
  abandonRemovedRoot,
  openAllocModal,
  submitAllocation,
  openMigrateModal,
  startMigration,
  confirmMigrationCleanup,
  cancelMigration,
} = useUserStoragePanel(() => props.admin);
</script>

<template>
  <div class="storage-two-blocks">
    <IsleBanner v-if="error" type="error" compact dismissible :message="error" @close="error = ''" />
    <IsleBanner v-if="successMessage" type="success" compact dismissible :message="successMessage" @close="successMessage = ''" />

    <!-- BLOCK 1: 存储目录管理 -->
    <IsleCard
      v-if="admin && (!mode || mode === 'all' || mode === 'roots')"
      title="存储目录管理（默认主目录与可用空间池）"
      subtitle="整个应用初始化时设定默认主目录，后续添加的互不嵌套目录作为独立存储空间；Mac 端添加目录时强制校验整盘与目录读写权限。"
    >
      <template #icon>
        <div class="block-header-icon"><HardDrive :size="18" /></div>
      </template>
      <template #actions>
        <IsleButton variant="glass" size="sm" :loading="pending" @click="load">
          <RefreshCw :size="14" /><span>刷新目录</span>
        </IsleButton>
      </template>

      <div v-if="!registeredRoots.length && !pending" class="empty-hint">
        暂未读取到已登记的存储目录。请在 Mac 管理端「存储 → 存储位置」或「设置 → 权限与初始化」中检查目录登记与整盘读写授权。
      </div>

      <div v-else class="directory-grid">
        <div
          v-for="root in registeredRoots"
          :key="root.rootID"
          class="directory-card"
          :class="{ 'is-default': root.isDefault, 'is-offline': !root.online }"
        >
          <div class="directory-card-top">
            <div class="directory-title-row">
              <FolderGit2 :size="16" class="dir-icon" />
              <strong class="dir-name">{{ root.name }}</strong>
            </div>
            <div class="dir-badges">
              <IsleBadge v-if="root.isDefault" variant="accent" size="sm">默认主目录</IsleBadge>
              <IsleBadge :variant="root.online ? 'online' : 'offline'" size="sm" dot>
                {{ root.online ? "在线可读写" : "离线" }}
              </IsleBadge>
            </div>
          </div>

          <div
            v-if="root.filesystemTotalBytes !== undefined && root.filesystemAvailableBytes !== undefined && root.filesystemTotalBytes > 0"
            class="dir-capacity"
          >
            <div class="capacity-bar-track">
              <div
                class="capacity-bar-fill"
                :style="{ width: Math.min(100, Math.round(((root.filesystemTotalBytes - root.filesystemAvailableBytes) / root.filesystemTotalBytes) * 100)) + '%' }"
              />
            </div>
            <div class="capacity-labels">
              <span>可用 {{ prettyBytes(root.filesystemAvailableBytes) }}</span>
              <span>总容量 {{ prettyBytes(root.filesystemTotalBytes) }}</span>
            </div>
          </div>

          <div class="directory-card-footer">
            <span class="dir-meta">
              登记代次 #{{ root.generation }} · 已绑定 {{ boundCountForRoot(root.rootID) }} 项用户空间
            </span>
            <IsleButton
              v-if="firstUserBoundToRoot(root.rootID) && roots.length > 1"
              variant="tonal"
              size="sm"
              @click="() => { const t = firstUserBoundToRoot(root.rootID); if (t) openMigrateModal(t.userId, root.rootID, t.gen, t.cats); }"
            >
              <ArrowRightLeft :size="13" /><span>迁移此目录数据</span>
            </IsleButton>
          </div>
        </div>
      </div>

      <template #footer>
        <div class="permission-guard-tip">
          <ShieldCheck :size="15" class="guard-icon" />
          <span>添加新物理盘或目录、切换默认主目录及修复 macOS 整盘读写权限，请在 Mac 本机「设置 → 权限与初始化」中操作。</span>
        </div>
      </template>
    </IsleCard>

    <!-- BLOCK 2: 用户空间管理 -->
    <IsleCard
      v-if="!mode || mode === 'all' || mode === 'users'"
      :title="admin ? '用户空间管理（目录分配、独立配额与跨目录迁移）' : '我的存储空间与目录绑定'"
      :subtitle="admin ? '管理每位用户可以拥有哪些存储目录、调整单目录配额，并支持将旧目录中的数据一键迁移到新目录。' : '个人文件、照片与视频存放在已分配的存储目录中；各目录独立计算配额。'"
    >
      <template #icon>
        <div class="block-header-icon"><ArrowRightLeft :size="18" /></div>
      </template>
      <template #actions>
        <IsleButton variant="glass" size="sm" :loading="pending" @click="load">
          <RefreshCw :size="14" /><span>刷新</span>
        </IsleButton>
      </template>

      <p v-if="pending && !Object.keys(policies).length" class="loading-status" role="status">正在读取用户空间配置…</p>

      <div class="user-space-list">
        <div v-for="policy in Object.values(policies)" :key="policy.userId" class="user-space-card">
          <div class="user-space-header">
            <div class="user-identity">
              <strong class="user-name">
                {{ admin ? users.find((u) => u.id === policy.userId)?.username ?? "账号 " + policy.userId : "我的目录与配额" }}
              </strong>
              <IsleBadge :variant="isUserUnlimited(policy) ? 'accent' : 'neutral'" size="sm">
                {{ isUserUnlimited(policy) ? "管理员 · 无限配额" : `成员 · 已拥有 ${allocatedDiskCount(policy)} 个目录` }}
              </IsleBadge>
            </div>

            <div v-if="admin" class="user-header-actions">
              <IsleButton variant="tonal" size="sm" :disabled="!roots.length || pending" @click="openAllocModal(policy.userId)">
                <Plus :size="14" /><span>分配目录</span>
              </IsleButton>
              <IsleButton variant="primary" size="sm" :disabled="!policy.locations.length || pending" @click="openMigrateModal(policy.userId)">
                <ArrowRightLeft :size="14" /><span>旧目录迁移到新目录</span>
              </IsleButton>
              <IsleButton variant="ghost" size="sm" :disabled="pending || !rootsKnown" @click="checkOnlineUsage(policy)">
                核对占用
              </IsleButton>
            </div>
          </div>

          <div v-if="usageChecks[policy.userId]" class="usage-check-box">{{ usageChecks[policy.userId] }}</div>

          <div class="owned-dirs-section">
            <div v-if="!(policy.rootQuotas ?? []).length" class="empty-user-dirs">
              {{ isUserUnlimited(policy) ? "管理员默认享有无限配额（仅受所选存储目录所属磁盘的实际可用空间限制）。" : "尚未分配存储目录。点击右上角「分配目录」即可为用户开通文件、照片或视频空间。" }}
            </div>

            <div v-for="q in policy.rootQuotas ?? []" :key="q.rootID + ':' + q.rootGeneration" class="owned-dir-row">
              <div class="owned-dir-main">
                <div class="owned-dir-title">
                  <strong>{{ rootName(q) }}</strong>
                  <span class="quota-pill">{{ prettyBytes(q.quotaBytes) }}</span>
                  <IsleBadge
                    :variant="isActiveRoot(policy, q) ? (findRoot(q.rootID)?.online === false ? 'danger' : (diskLocations(policy, q).length ? 'online' : 'warning')) : 'neutral'"
                    size="sm"
                    :title="'登记代次 #' + q.rootGeneration"
                  >
                    {{ isActiveRoot(policy, q) ? (findRoot(q.rootID)?.online === false ? "离线 · 请接回原盘" : (diskLocations(policy, q).length ? "当前使用中" : "已预留配额")) : "历史账本 #" + q.rootGeneration }}
                  </IsleBadge>
                </div>

                <div v-if="admin" class="owned-dir-actions">
                  <IsleButton v-if="!isUserUnlimited(policy)" variant="ghost" size="sm" @click="startEditQuota(policy.userId, q)">
                    <Sliders :size="13" /><span>调整配额</span>
                  </IsleButton>
                  <IsleButton
                    v-if="diskLocations(policy, q).length"
                    variant="tonal"
                    size="sm"
                    @click="openMigrateModal(policy.userId, q.rootID, q.rootGeneration, diskLocations(policy, q).map((l) => l.category))"
                  >
                    <ArrowRightLeft :size="13" /><span>迁移到新目录</span>
                  </IsleButton>
                  <IsleButton v-if="!findRoot(q.rootID)" variant="danger" size="sm" @click="abandonRemovedRoot(policy.userId, q)">
                    放弃旧目录记录
                  </IsleButton>
                </div>
              </div>

              <div v-if="editingQuotaKey === `${policy.userId}:${q.rootID}:${q.rootGeneration}`" class="inline-quota-editor">
                <span class="quota-edit-label">该目录新配额 (GiB)：</span>
                <div class="quota-presets">
                  <button v-for="preset in [50, 100, 200, 500, 1024]" :key="preset" type="button" class="preset-chip" @click="editingQuotaGiB = String(preset)">
                    {{ preset >= 1024 ? "1 TB" : preset + " GB" }}
                  </button>
                </div>
                <input v-model="editingQuotaGiB" type="number" min="1" class="isle-input quota-input" />
                <IsleButton variant="primary" size="sm" :loading="savingQuota" @click="saveQuota(policy.userId, q)">保存</IsleButton>
                <IsleButton variant="ghost" size="sm" @click="editingQuotaKey = null">取消</IsleButton>
              </div>

              <div v-if="q.quotaBytes !== null && q.quotaBytes > 0" class="quota-progress-wrap">
                <div class="capacity-bar-track">
                  <div class="capacity-bar-fill" :style="{ width: Math.min(100, Math.round(((q.accountedBytes + q.reservedBytes) / q.quotaBytes) * 100)) + '%' }" />
                </div>
              </div>

              <div class="owned-dir-stats">
                <span>已用 {{ prettyBytes(q.accountedBytes) }} · 预占 {{ prettyBytes(q.reservedBytes) }} · 可用额度 {{ rootAvailable(q) }}</span>
                <span v-if="diskLocations(policy, q).length" class="bound-cats-text">
                  包含：{{ diskLocations(policy, q).map((l) => categoryShortLabel(l.category)).join(" / ") }}
                </span>
              </div>
            </div>
          </div>

          <div class="category-chips-grid">
            <div v-for="category in categories" :key="category.id" class="category-chip-card">
              <div class="cat-chip-top">
                <div class="cat-chip-label">
                  <component :is="category.icon" :size="15" class="cat-icon" />
                  <strong>{{ category.label }}</strong>
                </div>
                <template v-if="admin">
                  <IsleButton
                    v-if="selectedLocation(policy, category.id)"
                    variant="ghost"
                    size="sm"
                    @click="() => { const loc = selectedLocation(policy, category.id)!; openMigrateModal(policy.userId, loc.rootID, loc.rootGeneration, [category.id]); }"
                  >
                    换目录
                  </IsleButton>
                  <IsleButton v-else variant="tonal" size="sm" :disabled="!roots.length" @click="openAllocModal(policy.userId, category.id)">
                    去分配
                  </IsleButton>
                </template>
              </div>

              <div v-if="selectedLocation(policy, category.id)" class="cat-chip-body">
                <span class="cat-path">{{ rootLabel(selectedLocation(policy, category.id)!) }}</span>
                <span v-if="registeredRoots.some((r) => r.rootID === selectedLocation(policy, category.id)!.rootID && !r.online)" class="cat-offline-warn">
                  离线 · 请检查硬盘连接
                </span>
              </div>
              <div v-else class="cat-chip-empty">尚未分配存储目录</div>
            </div>
          </div>

          <small v-if="policy.enforcement === 'pending'" class="storage-pending-note">
            配额状态：仅统计已接入账本的写入。SMB 和直接写盘的文件暂未计入。
          </small>
        </div>
      </div>
    </IsleCard>

    <DuplicateFilesPanel
      v-if="!mode || mode === 'all' || mode === 'users'"
      :admin="admin"
      :roots="registeredRoots"
    />

    <UserStorageModals
      v-model:show-alloc-modal="showAllocModal"
      v-model:alloc-root-id="allocRootId"
      v-model:alloc-quota-gi-b="allocQuotaGiB"
      v-model:alloc-subdirs="allocSubdirs"
      v-model:show-migrate-modal="showMigrateModal"
      v-model:migrate-source-compound="migrateSourceCompound"
      v-model:migrate-target-root-id="migrateTargetRootId"
      v-model:migrate-mode="migrateMode"
      v-model:migrate-quota-gi-b="migrateQuotaGiB"
      v-model:migrate-password="migratePassword"
      :online-root-options="onlineRootOptions"
      :alloc-categories="allocCategories"
      :alloc-busy="allocBusy"
      :alloc-error="allocError"
      :alloc-unlimited="Boolean(allocTargetPolicy && isUserUnlimited(allocTargetPolicy))"
      :categories="categories"
      :migrate-source-name="rootNameById(migrateSourceRootId)"
      :migrate-target-name="migrateTargetRootId ? rootNameById(migrateTargetRootId) : '待选择新目录'"
      :migrate-source-options="migrateSourceOptions"
      :migrate-target-options="migrateTargetOptions"
      :migrate-categories="migrateCategories"
      :migrate-busy="migrateBusy"
      :migrate-error="migrateError"
      :migrate-status="migrateStatus"
      :pretty-bytes="prettyBytes"
      :migration-phase-label="migrationPhaseLabel"
      @submit-allocation="submitAllocation"
      @start-migration="startMigration"
      @confirm-migration-cleanup="confirmMigrationCleanup"
      @cancel-migration="cancelMigration"
    />
  </div>
</template>

<style scoped src="./UserStoragePanel.css"></style>
