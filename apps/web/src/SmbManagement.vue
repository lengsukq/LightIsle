<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { requestConfirm } from "./useConfirmDialog.ts";
import { Server, RefreshCcw, Copy, Plus, Trash2, AlertTriangle, ShieldCheck } from "lucide-vue-next";
import AppleSelect from "./AppleSelect.vue";
import IsleButton from "./IsleButton.vue";
import IsleBadge from "./IsleBadge.vue";
import IsleBanner from "./IsleBanner.vue";
import IsleEmpty from "./IsleEmpty.vue";
import { describeUserFacingError } from "./userFacingError.ts";
import { apiRequest } from "./apiClient.ts";

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

const selectedRootID = ref("");
const selectedSubpath = ref("");
const customSMBName = ref("");
const newReadOnly = ref(false);
const newGuestAccess = ref(false);
const newSealed = ref(false);

const onlineRoots = computed(() => (status.value?.candidateRoots ?? []).filter((r) => r.online));
const rootOptions = computed(() =>
  onlineRoots.value.map((r) => ({ value: r.rootId, label: r.name, hint: r.path }))
);
const currentRoot = computed(() =>
  onlineRoots.value.find((r) => r.rootId === selectedRootID.value) ?? onlineRoots.value[0]
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
  error.value = "";
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
    notice.value = "已添加 SMB 共享文件夹。";
  } catch (e) {
    error.value = describeUserFacingError(e);
  } finally {
    busy.value = false;
  }
}

async function updateShare(
  share: SharePoint,
  patch: Partial<Pick<SharePoint, "shared" | "readOnly" | "guestAccess" | "sealed">>
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
      {
        method: "DELETE",
      },
    );
    notice.value = `已移除「${share.smbName}」共享。`;
  } catch (e) {
    error.value = describeUserFacingError(e);
  } finally {
    busy.value = false;
  }
}

function copyText(text: string, label: string) {
  navigator.clipboard
    ?.writeText(text)
    .then(() => {
      notice.value = `已复制${label}：${text}`;
    })
    .catch(() => {
      window.prompt(`复制${label}：`, text);
    });
}

onMounted(() => {
  void refresh();
});
</script>

<template>
  <section class="account-panel smb-panel" style="margin-bottom:20px">
    <div class="account-heading">
      <div>
        <h3><Server :size="18" /> Mac 文件共享 (SMB)</h3>
        <p>由 macOS 原生 smbd 广播局域网共享，访达、Windows 与 Infuse 可直接发现。</p>
      </div>
      <IsleButton variant="ghost" size="sm" :loading="loading" :disabled="busy" @click="refresh">
        <template #icon><RefreshCcw :size="14" /></template> 刷新
      </IsleButton>
    </div>

    <IsleBanner v-if="status && !status.remoteManageReady" type="warning" compact role="status">
      尚未开启免密管理授权。请先在 Mac 管理端「网络与连接 → Mac 文件共享」开启一次授权。
    </IsleBanner>

    <div v-if="status" class="smb-service-bar">
      <div class="smb-service-info">
        <strong>
          SMB 服务状态：
          <IsleBadge :variant="status.serviceEnabled ? 'online' : 'offline'" dot size="sm">
            {{ !status.serviceEnabled ? "未开启" : status.listeningState === "listening" ? "已开启 · 已发现监听" : "已开启 · 监听待确认" }}
          </IsleBadge>
        </strong>
        <small v-if="status.computerName">局域网搜索名：{{ status.computerName }}</small>
      </div>
      <div class="smb-service-actions">
        <IsleButton
          :variant="status.serviceEnabled ? 'ghost' : 'primary'"
          size="sm"
          :disabled="busy || !status.remoteManageReady"
          @click="toggleService(!status.serviceEnabled)"
        >
          {{ status.serviceEnabled ? "关闭 SMB 共享" : "开启 SMB 共享" }}
        </IsleButton>
      </div>
    </div>

    <div v-if="status && (status.bonjourUrl || status.lanUrl)" class="smb-addresses">
      <div v-if="status.bonjourUrl" class="smb-addr-pill">
        <code>{{ status.bonjourUrl }}</code>
        <IsleButton variant="ghost" size="sm" @click="copyText(status.bonjourUrl, '主机地址')">
          <template #icon><Copy :size="13" /></template> 复制
        </IsleButton>
      </div>
      <div v-if="status.lanUrl" class="smb-addr-pill">
        <code>{{ status.lanUrl }}</code>
        <IsleButton variant="ghost" size="sm" @click="copyText(status.lanUrl, 'IP 地址')">
          <template #icon><Copy :size="13" /></template> 复制
        </IsleButton>
      </div>
    </div>

    <IsleBanner v-if="error" type="error" compact role="alert">{{ error }}</IsleBanner>
    <IsleBanner v-if="notice" type="info" compact role="status">{{ notice }}</IsleBanner>

    <div v-if="status" class="smb-add-box">
      <strong>新增 NAS 共享文件夹</strong>
      <div v-if="!onlineRoots.length" class="footnote">暂无在线的 NAS 存储盘，请先在 Mac 管理端登记并连接硬盘。</div>
      <template v-else>
        <div class="smb-add-row">
          <AppleSelect
            :model-value="selectedRootID"
            :options="rootOptions"
            aria-label="选择 NAS 存储盘"
            :disabled="busy || !status.remoteManageReady"
            @update:model-value="(v: string) => { selectedRootID = v; selectedSubpath = ''; }"
          />
          <AppleSelect
            :model-value="selectedSubpath"
            :options="subpathOptions"
            aria-label="选择共享目录范围"
            :disabled="busy || !status.remoteManageReady"
            @update:model-value="(v: string) => { selectedSubpath = v; }"
          />
          <input
            v-model="customSMBName"
            maxlength="64"
            placeholder="自定义共享名称（留空则用文件夹名）"
            :disabled="busy || !status.remoteManageReady"
          />
        </div>
        <p v-if="selectionExposesPersonal" class="smb-personal-warn">
          <AlertTriangle :size="14" />
          注意：共享整块存储根或 Users 目录会使局域网 SMB 用户直接访问成员私人目录，且通过 SMB 写入的文件不计入轻屿配额账本。
        </p>
        <div class="smb-add-flags">
          <label><input v-model="newReadOnly" type="checkbox" :disabled="busy || !status.remoteManageReady" /> 仅只读</label>
          <label><input v-model="newGuestAccess" type="checkbox" :disabled="busy || !status.remoteManageReady" /> 允许访客访问</label>
          <label><input v-model="newSealed" type="checkbox" :disabled="busy || !status.remoteManageReady" /> SMB3 传输加密</label>
          <IsleButton variant="primary" size="sm" :disabled="busy || !status.remoteManageReady" @click="addShare">
            <template #icon><Plus :size="14" /></template> 添加到 SMB 共享
          </IsleButton>
        </div>
      </template>
    </div>

    <div v-if="status" class="smb-shares-list">
      <strong>已共享文件夹 ({{ status.shares.length }})</strong>
      <IsleEmpty v-if="!status.shares.length && !loading" compact description="当前没有配置任何 SMB 共享文件夹。" />
      <div v-for="share in status.shares" :key="share.recordName" class="smb-share-item">
        <div class="smb-share-header">
          <div>
            <strong>
              {{ share.smbName }}
              <IsleBadge v-if="share.rootName" variant="neutral" size="sm">NAS · {{ share.rootName }}</IsleBadge>
              <IsleBadge v-if="!share.pathExists" variant="warning" size="sm">路径离线</IsleBadge>
            </strong>
            <small>{{ share.path }}</small>
            <p v-if="share.exposesPersonalDirs" class="smb-personal-warn">
              <AlertTriangle :size="13" /> 包含 Users 私人目录：SMB 使用 Mac 账号或访客权限，不受轻屿成员隔离与配额账本限制。
            </p>
          </div>
          <IsleButton
            variant="danger"
            size="sm"
            :disabled="busy || !status.remoteManageReady"
            @click="removeShare(share)"
          >
            <template #icon><Trash2 :size="13" /></template> 移除共享
          </IsleButton>
        </div>
        <div class="smb-share-toggles">
          <label>
            <input
              type="checkbox"
              :checked="share.shared"
              :disabled="busy || !status.remoteManageReady"
              @change="updateShare(share, { shared: ($event.target as HTMLInputElement).checked })"
            />
            启用共享
          </label>
          <label>
            <input
              type="checkbox"
              :checked="share.readOnly"
              :disabled="busy || !status.remoteManageReady"
              @change="updateShare(share, { readOnly: ($event.target as HTMLInputElement).checked })"
            />
            仅只读
          </label>
          <label>
            <input
              type="checkbox"
              :checked="share.guestAccess"
              :disabled="busy || !status.remoteManageReady"
              @change="updateShare(share, { guestAccess: ($event.target as HTMLInputElement).checked })"
            />
            允许访客
          </label>
          <label>
            <input
              type="checkbox"
              :checked="share.sealed"
              :disabled="busy || !status.remoteManageReady"
              @change="updateShare(share, { sealed: ($event.target as HTMLInputElement).checked })"
            />
            SMB3 加密
          </label>
        </div>
      </div>
    </div>

    <p class="footnote">
      <ShieldCheck :size="13" /> 移除共享仅取消登记，不删除硬盘文件。首次使用系统账号密码连接需在 macOS「文件共享 → Windows 文件共享」中勾选该账号。
    </p>
  </section>
</template>

<style scoped>
.smb-panel{display:grid;gap:14px}
.smb-panel .account-heading h3{display:flex;align-items:center;gap:9px;margin:0}
.smb-panel .account-heading p{margin:6px 0 0;font-size:12px;color:var(--text-secondary)}
.smb-elevation-banner{display:flex;align-items:center;gap:10px;padding:11px 14px;border-radius:12px;background:color-mix(in srgb,#f59e0b 12%,transparent);border:1px solid color-mix(in srgb,#f59e0b 35%,transparent);font-size:12px;color:var(--text-primary)}
.smb-service-bar{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:12px 0;border-bottom:1px solid var(--stroke-subtle);flex-wrap:wrap}
.smb-service-info strong{display:block;font-size:13px}
.smb-service-info small{font-size:11px;color:var(--text-secondary)}
.smb-badge-on{color:#16a34a;font-weight:700}
.smb-badge-off{color:var(--text-secondary)}
.smb-addresses{display:flex;gap:10px;flex-wrap:wrap}
.smb-addr-pill{display:inline-flex;align-items:center;gap:8px;padding:5px 10px;border-radius:8px;border:1px solid var(--stroke-subtle);background:var(--surface-base);font-size:12px;max-width:100%}
.smb-addr-pill code{font-family:ui-monospace,monospace;overflow-wrap:anywhere}
.smb-addr-pill button{display:inline-flex;align-items:center;gap:4px;border:none;background:transparent;color:var(--accent-primary);font-size:12px;font-weight:600;cursor:pointer}
.smb-add-box{display:grid;gap:10px;padding:14px;border-radius:var(--radius-sm);border:1px solid var(--stroke-subtle);background:var(--surface-base)}
.smb-add-row{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,180px),1fr));gap:10px;align-items:center}
.smb-add-row input{border:1px solid var(--stroke-subtle);border-radius:9px;padding:8px 12px;background:var(--surface-raised);color:var(--text-primary);font-size:13px}
.smb-add-flags{display:flex;align-items:center;gap:14px;flex-wrap:wrap;font-size:12px}
.smb-add-flags label,.smb-share-toggles label{display:inline-flex;align-items:center;gap:6px;cursor:pointer}
.smb-add-btn{margin-left:auto;display:inline-flex;align-items:center;gap:6px;border:none;border-radius:9px;padding:7px 14px;background:var(--accent-primary);color:#fff;font-size:12px;font-weight:650;cursor:pointer}
.smb-add-btn:disabled{opacity:.5;cursor:not-allowed}
.smb-shares-list{display:grid;gap:2px;margin-top:6px}
.smb-share-item{display:grid;gap:10px;padding:12px 0;border-bottom:1px solid var(--stroke-subtle)}
.smb-share-item:last-child{border-bottom:none}
.smb-share-header{display:flex;align-items:flex-start;justify-content:space-between;gap:10px;flex-wrap:wrap}
.smb-share-header strong{display:block;font-size:13px}
.smb-share-header small{font-family:ui-monospace,monospace;font-size:11px;color:var(--text-secondary);overflow-wrap:anywhere}
.smb-share-toggles{display:flex;align-items:center;gap:16px;flex-wrap:wrap;font-size:12px;color:var(--text-secondary)}
.smb-personal-warn{display:flex;align-items:center;gap:6px;margin:4px 0 0;font-size:11px;color:#d97706}
</style>
