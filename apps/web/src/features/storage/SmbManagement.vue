<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { requestConfirm } from "../../composables/useConfirmDialog.ts";
import {
  Server,
  RefreshCcw,
  Copy,
  Check,
  Plus,
  Trash2,
  AlertTriangle,
  ShieldCheck,
  Power,
  Users,
  Lock,
} from "lucide-vue-next";
import AppleSelect from "../../components/ui/AppleSelect.vue";
import IsleCard from "../../components/ui/IsleCard.vue";
import IsleButton from "../../components/ui/IsleButton.vue";
import IsleBadge from "../../components/ui/IsleBadge.vue";
import IsleBanner from "../../components/ui/IsleBanner.vue";
import IsleEmpty from "../../components/ui/IsleEmpty.vue";
import IsleModal from "../../components/ui/IsleModal.vue";
import IsleGroupedList from "../../components/ui/IsleGroupedList.vue";
import IsleActionMenu from "../../components/ui/IsleActionMenu.vue";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { copyTextToClipboard } from "../../utils/clipboard.ts";
import { apiRequest } from "../../api/apiClient.ts";
import { TIMINGS_MS } from "../../constants/timings.ts";

type SharePoint = {
  recordName: string;
  smbName: string;
  path: string;
  shared: boolean;
  guestAccess: boolean;
  readOnly: boolean;
  sealed: boolean;
  rootId?: string;
  rootName?: string;
  exposesPersonalDirs: boolean;
  pathExists: boolean;
  syncedInMacOS?: boolean;
  needsRestore?: boolean;
};

type CandidateRoot = {
  rootId: string;
  name: string;
  path: string;
  online: boolean;
  subdirectories: string[];
};

type SMBStatus = {
  serviceEnabled: boolean;
  listening: boolean;
  listeningState?: "listening" | "unknown" | "disabled";
  remoteManageReady: boolean;
  computerName: string;
  localHostName: string;
  bonjourUrl?: string;
  lanUrl?: string;
  shares: SharePoint[];
  candidateRoots: CandidateRoot[];
};

const status = ref<SMBStatus | null>(null);
const loading = ref(false);
const busy = ref(false);
const error = ref("");
const notice = ref("");
const copiedAddr = ref<"" | "bonjour" | "lan">("");

const showAddModal = ref(false);
const addModalError = ref("");
const selectedRootID = ref("");
const selectedSubpath = ref("");
const customSMBName = ref("");
const newReadOnly = ref(false);
const newGuestAccess = ref(false);
const newSealed = ref(false);

const onlineRoots = computed(() => (status.value?.candidateRoots ?? []).filter((r) => r.online));
const rootOptions = computed(() =>
  onlineRoots.value.map((r) => ({ value: r.rootId, label: r.name, hint: r.path })),
);
const currentRoot = computed(() =>
  onlineRoots.value.find((r) => r.rootId === selectedRootID.value) ?? onlineRoots.value[0],
);
const subpathOptions = computed(() => {
  const base = [{ value: "", label: "整块存储根目录（含全部子目录）" }];
  const subs = currentRoot.value?.subdirectories ?? [];
  return [...base, ...subs.map((s) => ({ value: s, label: "子目录：" + s }))];
});
const selectionExposesPersonal = computed(() => {
  if (!currentRoot.value) return false;
  const sub = selectedSubpath.value.trim();
  return sub === "" || sub === "Users" || sub.startsWith("Users/");
});
const hasPendingRestore = computed(() =>
  (status.value?.shares ?? []).some(
    (s) => s.needsRestore || (s.shared && s.pathExists && s.syncedInMacOS === false),
  ),
);
const addressItems = computed(() => {
  if (!status.value) return [];
  const items: Array<{ kind: "bonjour" | "lan"; url: string; label: string; tabular: boolean }> = [];
  if (status.value.bonjourUrl) {
    items.push({ kind: "bonjour", url: status.value.bonjourUrl, label: "主机地址", tabular: false });
  }
  if (status.value.lanUrl) {
    items.push({ kind: "lan", url: status.value.lanUrl, label: "IP 地址", tabular: true });
  }
  return items;
});

function canManageShare(share: SharePoint): boolean {
  const roots = status.value?.candidateRoots ?? [];
  return roots.length === 0 || Boolean(share.rootId);
}

function syncRootSelection() {
  if (!onlineRoots.value.length) {
    selectedRootID.value = "";
    selectedSubpath.value = "";
    return;
  }
  if (!selectedRootID.value || !onlineRoots.value.some((r) => r.rootId === selectedRootID.value)) {
    selectedRootID.value = onlineRoots.value[0].rootId;
    selectedSubpath.value = "";
  }
}

function openAddModal() {
  syncRootSelection();
  customSMBName.value = "";
  newReadOnly.value = false;
  newGuestAccess.value = false;
  newSealed.value = false;
  addModalError.value = "";
  showAddModal.value = true;
}

async function refresh() {
  if (loading.value || busy.value) return;
  loading.value = true;
  error.value = "";
  try {
    const data = await apiRequest<SMBStatus>("/api/v2/admin/smb");
    status.value = data;
    syncRootSelection();
  } catch (e) {
    error.value = describeUserFacingError(e);
  } finally {
    loading.value = false;
  }
}

async function reconcileShares() {
  if (busy.value || !status.value?.remoteManageReady) return;
  busy.value = true;
  error.value = "";
  notice.value = "";
  try {
    const res = await apiRequest<{ status: SMBStatus; restored: number }>(
      "/api/v2/admin/smb/reconcile",
      { method: "POST", json: {} },
    );
    status.value = res.status;
    syncRootSelection();
    notice.value =
      res.restored > 0
        ? `已自动恢复 ${res.restored} 个重连磁盘的 SMB 共享与权限。`
        : "已完成 SMB 共享巡检，所有在线共享权限均已同步。";
  } catch (e) {
    error.value = describeUserFacingError(e);
  } finally {
    busy.value = false;
  }
}

async function toggleService(enabled: boolean) {
  if (busy.value || !status.value?.remoteManageReady) return;
  busy.value = true;
  error.value = "";
  notice.value = "";
  try {
    status.value = await apiRequest<SMBStatus>("/api/v2/admin/smb/service", {
      method: "POST",
      json: { enabled },
    });
    notice.value = enabled ? "已开启 macOS SMB 文件共享服务。" : "已关闭 macOS SMB 文件共享服务。";
  } catch (e) {
    error.value = describeUserFacingError(e);
  } finally {
    busy.value = false;
  }
}

async function addShare() {
  if (busy.value || !status.value?.remoteManageReady || !currentRoot.value) return;
  busy.value = true;
  addModalError.value = "";
  notice.value = "";
  try {
    status.value = await apiRequest<SMBStatus>("/api/v2/admin/smb/shares", {
      method: "POST",
      json: {
        rootId: currentRoot.value.rootId,
        subpath: selectedSubpath.value,
        smbName: customSMBName.value.trim(),
        readOnly: newReadOnly.value,
        guestAccess: newGuestAccess.value,
        sealed: newSealed.value,
      },
    });
    customSMBName.value = "";
    showAddModal.value = false;
    notice.value = "已添加 SMB 共享文件夹。";
  } catch (e) {
    addModalError.value = describeUserFacingError(e);
  } finally {
    busy.value = false;
  }
}

async function updateShare(
  share: SharePoint,
  patch: Partial<Pick<SharePoint, "shared" | "readOnly" | "guestAccess" | "sealed">>,
) {
  if (busy.value || !status.value?.remoteManageReady) return;
  busy.value = true;
  error.value = "";
  notice.value = "";
  try {
    status.value = await apiRequest<SMBStatus>(
      "/api/v2/admin/smb/shares/" + encodeURIComponent(share.recordName),
      {
        method: "PATCH",
        json: {
          smbName: share.smbName,
          shared: patch.shared ?? share.shared,
          readOnly: patch.readOnly ?? share.readOnly,
          guestAccess: patch.guestAccess ?? share.guestAccess,
          sealed: patch.sealed ?? share.sealed,
        },
      },
    );
    notice.value = `已更新「${share.smbName}」共享设置。`;
  } catch (e) {
    error.value = describeUserFacingError(e);
  } finally {
    busy.value = false;
  }
}

async function removeShare(share: SharePoint) {
  if (busy.value || !status.value?.remoteManageReady) return;
  if (
    !(await requestConfirm({
      title: "移除 SMB 共享",
      message: `确认移除 SMB 共享「${share.smbName}」？\n路径：${share.path}\n\n此操作仅取消 SMB 局域网共享登记，绝不会删除硬盘上的任何原始文件。`,
      confirmText: "移除登记",
      variant: "danger",
    }))
  )
    return;
  busy.value = true;
  error.value = "";
  notice.value = "";
  try {
    status.value = await apiRequest<SMBStatus>(
      "/api/v2/admin/smb/shares/" + encodeURIComponent(share.recordName),
      { method: "DELETE" },
    );
    notice.value = `已移除「${share.smbName}」共享。`;
  } catch (e) {
    error.value = describeUserFacingError(e);
  } finally {
    busy.value = false;
  }
}

async function copyText(text: string, label: string, kind: "bonjour" | "lan") {
  if (await copyTextToClipboard(text)) {
    copiedAddr.value = kind;
    notice.value = `已复制${label}：${text}`;
    window.setTimeout(() => {
      if (copiedAddr.value === kind) copiedAddr.value = "";
    }, TIMINGS_MS.COPIED_FEEDBACK);
  } else {
    notice.value = `浏览器限制自动复制，请手动选择复制${label}：${text}`;
  }
}

onMounted(() => {
  void refresh();
});
</script>

<template>
  <IsleCard
    class="smb-panel"
    title="Mac 文件共享 (SMB)"
    subtitle="由 macOS 原生 smbd 广播局域网共享，访达、Windows 与 Infuse 可直接发现。"
  >
    <template #icon><Server :size="18" /></template>
    <template #actions>
      <IsleButton
        v-if="hasPendingRestore && status?.remoteManageReady"
        variant="primary"
        size="sm"
        :loading="busy"
        @click="reconcileShares"
      >
        恢复共享权限
      </IsleButton>
      <IsleButton
        v-if="status"
        variant="tonal"
        size="sm"
        :disabled="busy || !status.remoteManageReady || !onlineRoots.length"
        @click="openAddModal"
      >
        <template #icon><Plus :size="14" /></template>
        添加 SMB 共享
      </IsleButton>
      <button
        type="button"
        class="storage-header-refresh"
        :disabled="loading || busy"
        aria-label="刷新 SMB 状态"
        title="刷新 SMB 状态"
        @click="refresh"
      >
        <RefreshCcw :size="14" :class="{ 'is-spinning': loading }" />
      </button>
    </template>

    <div class="smb-body">
      <p v-if="loading && !status" class="smb-loading-hint" role="status">正在读取 Mac 文件共享状态…</p>
      <IsleBanner v-if="status && !status.remoteManageReady" type="warning" compact role="status">
        尚未开启免密管理授权。请先在 Mac 管理端「网络与连接 → Mac 文件共享」开启一次授权。
      </IsleBanner>

      <IsleGroupedList v-if="status" variant="item" flush>
        <div class="smb-service-row">
          <div class="smb-service-info">
            <strong>
              SMB 服务状态
              <IsleBadge :variant="status.serviceEnabled ? 'online' : 'offline'" dot size="sm">
                {{ !status.serviceEnabled ? "未开启" : status.listeningState === "listening" ? "已开启 · 已发现监听" : "已开启 · 监听待确认" }}
              </IsleBadge>
            </strong>
            <small v-if="status.computerName">局域网搜索名：{{ status.computerName }}</small>
          </div>
          <IsleButton
            :variant="status.serviceEnabled ? 'glass' : 'primary'"
            size="sm"
            :disabled="busy || !status.remoteManageReady"
            @click="toggleService(!status.serviceEnabled)"
          >
            {{ status.serviceEnabled ? "关闭 SMB 共享" : "开启 SMB 共享" }}
          </IsleButton>
        </div>

        <div v-if="addressItems.length" class="smb-addresses">
          <div v-for="addr in addressItems" :key="addr.kind" class="smb-addr-pill">
            <code :class="{ 'smb-tabular': addr.tabular }">{{ addr.url }}</code>
            <IsleButton
              variant="tonal"
              size="sm"
              :class="{ 'is-copied': copiedAddr === addr.kind }"
              @click="copyText(addr.url, addr.label, addr.kind)"
            >
              <template #icon>
                <Transition name="isle-copy-swap" mode="out-in">
                  <Check v-if="copiedAddr === addr.kind" key="ok" :size="12" />
                  <Copy v-else key="copy" :size="12" />
                </Transition>
              </template>
              {{ copiedAddr === addr.kind ? "已复制" : "复制" }}
            </IsleButton>
          </div>
        </div>
      </IsleGroupedList>

      <IsleBanner v-if="error" type="error" compact role="alert">
        {{ error }}
        <template v-if="!status" #action>
          <IsleButton variant="glass" size="sm" :loading="loading" @click="refresh">重试</IsleButton>
        </template>
      </IsleBanner>
      <IsleBanner v-if="notice" type="info" compact closable role="status" :message="notice" @close="notice = ''" />

      <IsleGroupedList
        v-if="status"
        title="已共享文件夹"
        :subtitle="`${status.shares.length} 个 SMB 共享点`"
        variant="item"
        flush
      >
        <IsleEmpty
          v-if="!status.shares.length && !loading"
          compact
          description="当前没有配置任何 SMB 共享文件夹。"
        >
          <template #action>
            <IsleButton
              v-if="status.remoteManageReady && onlineRoots.length"
              variant="tonal"
              size="sm"
              :disabled="busy"
              @click="openAddModal"
            >
              <template #icon><Plus :size="14" /></template>
              添加 SMB 共享
            </IsleButton>
          </template>
        </IsleEmpty>

        <TransitionGroup v-else name="isle-list" tag="div" class="smb-shares-group">
          <div v-for="share in status.shares" :key="share.recordName" class="smb-share-item">
            <div class="smb-share-header">
              <div class="smb-share-main">
                <strong class="smb-share-title">
                  <span>{{ share.smbName }}</span>
                  <IsleBadge v-if="share.rootName" variant="neutral" size="sm">NAS · {{ share.rootName }}</IsleBadge>
                  <IsleBadge v-else-if="!canManageShare(share)" variant="neutral" size="sm">本机其他共享</IsleBadge>
                  <IsleBadge v-if="!share.pathExists" variant="warning" size="sm">磁盘离线 · 重连后自动恢复</IsleBadge>
                  <IsleBadge
                    v-else-if="share.needsRestore || (share.shared && share.syncedInMacOS === false)"
                    variant="warning"
                    size="sm"
                  >
                    待恢复系统共享权限
                  </IsleBadge>
                </strong>
                <small class="smb-share-path">{{ share.path }}</small>
                <div class="smb-share-pills">
                  <IsleBadge :variant="share.shared ? 'online' : 'offline'" dot size="sm">
                    {{ share.shared ? "共享已启用" : "已暂停共享" }}
                  </IsleBadge>
                  <IsleBadge :variant="share.readOnly ? 'neutral' : 'accent'" size="sm">
                    {{ share.readOnly ? "仅只读" : "可读写" }}
                  </IsleBadge>
                  <IsleBadge v-if="share.guestAccess" variant="warning" size="sm">允许访客</IsleBadge>
                  <IsleBadge v-if="share.sealed" variant="neutral" size="sm">SMB3 加密</IsleBadge>
                </div>
                <p v-if="share.exposesPersonalDirs" class="smb-personal-warn">
                  <AlertTriangle :size="13" /> 包含 Users 私人目录：SMB 使用 Mac 账号或访客权限，不受轻屿成员隔离与配额账本限制。
                </p>
              </div>

              <div class="smb-share-actions">
                <template v-if="canManageShare(share)">
                  <IsleButton variant="glass" size="sm" :disabled="busy || !status.remoteManageReady" @click="updateShare(share, { readOnly: !share.readOnly })">
                    {{ share.readOnly ? "设为可读写" : "设为只读" }}
                  </IsleButton>
                  <IsleActionMenu :aria-label="'更多共享操作：' + share.smbName">
                    <button type="button" role="menuitem" :disabled="busy || !status.remoteManageReady" @click="updateShare(share, { shared: !share.shared })">
                      <Power :size="14" />{{ share.shared ? "暂停共享" : "启用共享" }}
                    </button>
                    <button type="button" role="menuitem" :disabled="busy || !status.remoteManageReady" @click="updateShare(share, { guestAccess: !share.guestAccess })">
                      <Users :size="14" />{{ share.guestAccess ? "关闭访客访问" : "允许访客访问" }}
                    </button>
                    <button type="button" role="menuitem" :disabled="busy || !status.remoteManageReady" @click="updateShare(share, { sealed: !share.sealed })">
                      <Lock :size="14" />{{ share.sealed ? "关闭 SMB3 加密" : "开启 SMB3 加密" }}
                    </button>
                    <button type="button" role="menuitem" class="danger" :disabled="busy || !status.remoteManageReady" @click="removeShare(share)">
                      <Trash2 :size="14" />移除共享
                    </button>
                  </IsleActionMenu>
                </template>
                <span v-else class="smb-readonly-note">仅 Mac 端可管理</span>
              </div>
            </div>
          </div>
        </TransitionGroup>
      </IsleGroupedList>
    </div>

    <template #footer>
      <div class="smb-footer-note">
        <ShieldCheck :size="14" />
        <span>移除共享仅取消登记，不删除硬盘文件。首次使用系统账号密码连接需在 macOS「文件共享 → Windows 文件共享」中勾选该账号。</span>
      </div>
    </template>

    <IsleModal
      v-model="showAddModal"
      title="添加 SMB 共享文件夹"
      description="选择要通过 macOS 原生 smbd 向局域网发布的目录与访问权限。"
      size="md"
      :close-on-backdrop="!busy"
      :close-on-esc="!busy"
      :show-close="!busy"
    >
      <div class="smb-modal-form">
        <IsleBanner v-if="addModalError" type="error" compact :message="addModalError" />

        <IsleEmpty
          v-if="!onlineRoots.length"
          compact
          title="暂无在线的 NAS 存储盘"
          description="请先在 Mac 管理端「存储 → 存储位置」登记并连接硬盘。"
        />

        <template v-else>
          <div class="smb-modal-field">
            <label class="smb-field-label">1. 选择 NAS 存储盘</label>
            <AppleSelect
              :model-value="selectedRootID"
              :options="rootOptions"
              aria-label="选择 NAS 存储盘"
              block
              :disabled="busy || !status?.remoteManageReady"
              @update:model-value="(v: string) => { selectedRootID = v; selectedSubpath = ''; }"
            />
          </div>

          <div class="smb-modal-field">
            <label class="smb-field-label">2. 选择共享目录范围</label>
            <AppleSelect
              :model-value="selectedSubpath"
              :options="subpathOptions"
              aria-label="选择共享目录范围"
              block
              :disabled="busy || !status?.remoteManageReady"
              @update:model-value="(v: string) => { selectedSubpath = v; }"
            />
          </div>

          <div class="smb-modal-field">
            <label class="smb-field-label">3. 自定义共享名称（选填）</label>
            <input
              v-model="customSMBName"
              class="smb-modal-input"
              maxlength="64"
              placeholder="留空则默认使用文件夹名称"
              :disabled="busy || !status?.remoteManageReady"
            />
          </div>

          <IsleBanner v-if="selectionExposesPersonal" type="warning" compact>
            共享整块存储根或 Users 目录会使局域网 SMB 用户直接访问成员私人目录，且通过 SMB 写入的文件暂不计入轻屿配额账本。
          </IsleBanner>

          <div class="smb-modal-flags">
            <label class="smb-flag-pill">
              <input v-model="newReadOnly" type="checkbox" class="isle-checkbox" :disabled="busy || !status?.remoteManageReady" />
              <span>仅只读</span>
            </label>
            <label class="smb-flag-pill">
              <input v-model="newGuestAccess" type="checkbox" class="isle-checkbox" :disabled="busy || !status?.remoteManageReady" />
              <span>允许访客访问</span>
            </label>
            <label class="smb-flag-pill">
              <input v-model="newSealed" type="checkbox" class="isle-checkbox" :disabled="busy || !status?.remoteManageReady" />
              <span>SMB3 传输加密</span>
            </label>
          </div>
        </template>
      </div>

      <template #footer>
        <IsleButton variant="glass" :disabled="busy" @click="showAddModal = false">取消</IsleButton>
        <IsleButton
          variant="primary"
          :loading="busy"
          :disabled="!onlineRoots.length || !status?.remoteManageReady"
          @click="addShare"
        >
          <template #icon><Plus :size="14" /></template>
          添加到 SMB 共享
        </IsleButton>
      </template>
    </IsleModal>
  </IsleCard>
</template>

<style scoped>
.smb-body { display: flex; flex-direction: column; gap: 13px; }
.smb-loading-hint { margin: 0; font-size: 12.5px; color: var(--text-secondary); }
.smb-tabular { font-variant-numeric: tabular-nums; }
.smb-service-row { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 12px 16px; flex-wrap: wrap; }
.smb-service-info strong { display: inline-flex; align-items: center; gap: 8px; font-size: 13px; }
.smb-service-info small { display: block; margin-top: 2px; font-size: 11.5px; color: var(--text-secondary); }
.smb-addresses { display: flex; gap: 8px; flex-wrap: wrap; padding: 10px 16px; }
.smb-addr-pill {
  display: inline-flex; align-items: center; gap: 8px; padding: 4px 8px 4px 10px;
  border-radius: 10px; border: 1px solid var(--fluid-card-border); background: var(--fluid-card-fill);
  font-size: 12px; max-width: 100%;
}
.smb-addr-pill code { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; overflow-wrap: anywhere; }
.smb-shares-group { display: flex; flex-direction: column; min-width: 0; }
.smb-share-item { display: flex; flex-direction: column; gap: 6px; padding: 12px 16px; }
.smb-share-item + .smb-share-item { border-top: 1px solid var(--fluid-divider, rgba(20, 19, 17, 0.06)); }
.smb-share-header { display: flex; align-items: flex-start; justify-content: space-between; gap: 10px; flex-wrap: wrap; }
.smb-share-main { min-width: 0; flex: 1 1 220px; display: flex; flex-direction: column; gap: 5px; overflow-wrap: anywhere; }
.smb-share-title { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; font-size: 13.5px; }
.smb-share-path {
  display: block; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-size: 11px; color: var(--text-secondary); overflow-wrap: anywhere;
}
.smb-share-pills { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
.smb-share-actions { display: flex; align-items: center; gap: 6px; flex-shrink: 0; }
.smb-readonly-note { font-size: 11.5px; color: var(--text-tertiary); }
.smb-personal-warn { display: flex; align-items: flex-start; gap: 5px; margin: 2px 0 0; font-size: 11.5px; color: var(--warning, #d97706); }
.smb-personal-warn svg { flex-shrink: 0; margin-top: 2px; }
.smb-footer-note { display: flex; align-items: center; gap: 7px; width: 100%; font-size: 11.5px; color: var(--text-secondary); }
.smb-footer-note svg { flex-shrink: 0; color: var(--accent-primary); }
.smb-modal-form { display: flex; flex-direction: column; gap: 12px; }
.smb-modal-field { display: flex; flex-direction: column; gap: 5px; }
.smb-field-label { font-size: 12px; font-weight: 600; color: var(--text-primary); }
.smb-modal-input {
  height: 34px; border: 1px solid var(--fluid-card-border); border-radius: 9px; padding: 0 11px;
  background: var(--fluid-card-item-fill); color: var(--text-primary); font-size: 12.5px; outline: none;
  transition: border-color 160ms ease;
}
.smb-modal-input:focus { border-color: var(--accent-primary, #0e6b74); }
.smb-modal-flags { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.smb-flag-pill {
  display: inline-flex; align-items: center; gap: 6px; padding: 5px 10px;
  border-radius: 999px; border: 1px solid var(--fluid-card-border);
  background: var(--fluid-card-item-fill); font-size: 12px; cursor: pointer;
}
@media (prefers-reduced-motion: reduce) {
  .smb-modal-input { transition: none; }
}
</style>
