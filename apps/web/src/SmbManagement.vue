<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { Server, RefreshCcw, Copy, Plus, Trash2, AlertTriangle, ShieldCheck } from "lucide-vue-next";
import AppleSelect from "./AppleSelect.vue";
import { describeUserFacingError } from "./userFacingError.js";
import { apiErrorFromResponse } from "./apiFailure.js";

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

const errorMessages: Record<string, string> = {
  invalid_smb_request: "共享名称或目录参数无效（不能包含 /、\\、: 等特殊字符）。",
  smb_share_not_found: "未找到该共享目录，请刷新列表后重试。",
  smb_share_already_exists: "该目录或同名共享点已存在，请勿重复添加。",
  smb_elevation_required: "尚未开启三端免密管理授权。请先在 Mac 管理端「网络与连接 → Mac 文件共享」点击一次「开启免密管理授权」。",
  smb_protected_path_rejected: "安全保护已拦截：不允许共享 .lightisle-* 内部元数据目录、符号链接或系统根目录。",
  smb_personal_guest_forbidden: "此共享覆盖成员私人目录。请选择公共子目录，或在 Mac 上关闭访客访问并确认共享。",
  smb_personal_confirmation_required: "请在 Mac 管理端确认私人目录的系统权限后再共享。",
  smb_root_offline: "所选 NAS 存储盘当前处于离线状态，请先检查硬盘连接。",
  smb_operation_failed: "macOS 文件共享操作未完成，请检查系统共享设置或权限。",
  admin_only: "仅管理员能够管理 Mac 文件共享。",
};

function friendlyError(e: unknown): string {
  if (e instanceof Error && "code" in e && typeof e.code === "string" && errorMessages[e.code]) {
    return errorMessages[e.code];
  }
  return describeUserFacingError(e);
}

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

async function parseResponse(response: Response): Promise<SMBStatus> {
  const body = (await response.json().catch(() => ({}))) as SMBStatus & { error?: string };
  if (!response.ok) {
    const failure = apiErrorFromResponse(response, body);
    throw new Error(errorMessages[body.error ?? ""] ?? friendlyError(failure));
  }
  return body;
}

async function refresh() {
  if (loading.value || busy.value) return;
  loading.value = true;
  error.value = "";
  try {
    const data = await parseResponse(await fetch("/api/v2/admin/smb", { credentials: "same-origin", cache: "no-store" }));
    status.value = data;
    syncRootSelection();
  } catch (e) {
    error.value = friendlyError(e);
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
    status.value = await parseResponse(
      await fetch("/api/v2/admin/smb/service", {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json", "X-LightIsle-Request": "1" },
        body: JSON.stringify({ enabled }),
      })
    );
    notice.value = enabled ? "已开启 macOS SMB 文件共享服务。" : "已关闭 macOS SMB 文件共享服务。";
  } catch (e) {
    error.value = friendlyError(e);
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
    status.value = await parseResponse(
      await fetch("/api/v2/admin/smb/shares", {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json", "X-LightIsle-Request": "1" },
        body: JSON.stringify({
          rootId: currentRoot.value.rootId,
          subpath: selectedSubpath.value,
          smbName: customSMBName.value.trim(),
          readOnly: newReadOnly.value,
          guestAccess: newGuestAccess.value,
          sealed: newSealed.value,
        }),
      })
    );
    customSMBName.value = "";
    notice.value = "已添加 SMB 共享文件夹。";
  } catch (e) {
    error.value = friendlyError(e);
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
    status.value = await parseResponse(
      await fetch("/api/v2/admin/smb/shares/" + encodeURIComponent(share.recordName), {
        method: "PATCH",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json", "X-LightIsle-Request": "1" },
        body: JSON.stringify({
          smbName: share.smbName,
          shared: patch.shared ?? share.shared,
          readOnly: patch.readOnly ?? share.readOnly,
          guestAccess: patch.guestAccess ?? share.guestAccess,
          sealed: patch.sealed ?? share.sealed,
        }),
      })
    );
    notice.value = `已更新「${share.smbName}」共享设置。`;
  } catch (e) {
    error.value = friendlyError(e);
  } finally {
    busy.value = false;
  }
}

async function removeShare(share: SharePoint) {
  if (busy.value || !status.value?.remoteManageReady) return;
  if (
    !window.confirm(
      `确认移除 SMB 共享「${share.smbName}」？\n路径：${share.path}\n\n此操作仅取消 SMB 局域网共享登记，绝不会删除硬盘上的任何原始文件。`
    )
  )
    return;
  busy.value = true;
  error.value = "";
  notice.value = "";
  try {
    status.value = await parseResponse(
      await fetch("/api/v2/admin/smb/shares/" + encodeURIComponent(share.recordName), {
        method: "DELETE",
        credentials: "same-origin",
        headers: { "X-LightIsle-Request": "1" },
      })
    );
    notice.value = `已移除「${share.smbName}」共享。`;
  } catch (e) {
    error.value = friendlyError(e);
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
        <p>由 macOS 原生 smbd 广播局域网共享 · 访达「网络」、Windows、手机「文件」App 及 Infuse/VLC 可直接搜到 · 管理员专用</p>
      </div>
      <button type="button" class="refresh" :disabled="loading || busy" @click="refresh">
        <RefreshCcw :size="14" /> {{ loading ? "加载中…" : "刷新" }}
      </button>
    </div>

    <div v-if="status && !status.remoteManageReady" class="smb-elevation-banner" role="status">
      <AlertTriangle :size="16" />
      <span>尚未开启三端免密管理授权。请先在 Mac 管理端「网络与连接 → Mac 文件共享」点击一次「开启免密管理授权」，即可在网页和手机端直接开关服务与管理共享目录。</span>
    </div>

    <div v-if="status" class="smb-service-bar">
      <div class="smb-service-info">
        <strong>
          SMB 服务状态：
          <span :class="status.serviceEnabled ? 'smb-badge-on' : 'smb-badge-off'">
            {{ !status.serviceEnabled ? "未开启" : status.listeningState === "listening" ? "已开启 · 已发现监听" : "已开启 · 监听待确认" }}
          </span>
        </strong>
        <small v-if="status.computerName">局域网搜索名：{{ status.computerName }}</small>
      </div>
      <div class="smb-service-actions">
        <button
          type="button"
          class="account-action"
          :disabled="busy || !status.remoteManageReady"
          @click="toggleService(!status.serviceEnabled)"
        >
          {{ status.serviceEnabled ? "关闭 SMB 共享" : "开启 SMB 共享" }}
        </button>
      </div>
    </div>

    <div v-if="status && (status.bonjourUrl || status.lanUrl)" class="smb-addresses">
      <div v-if="status.bonjourUrl" class="smb-addr-pill">
        <code>{{ status.bonjourUrl }}</code>
        <button type="button" @click="copyText(status.bonjourUrl, '主机地址')"><Copy :size="13" /> 复制</button>
      </div>
      <div v-if="status.lanUrl" class="smb-addr-pill">
        <code>{{ status.lanUrl }}</code>
        <button type="button" @click="copyText(status.lanUrl, 'IP 地址')"><Copy :size="13" /> 复制</button>
      </div>
    </div>

    <p v-if="error" role="alert" class="form-error">{{ error }}</p>
    <p v-if="notice" role="status" class="footnote">{{ notice }}</p>

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
          <button type="button" class="smb-add-btn" :disabled="busy || !status.remoteManageReady" @click="addShare">
            <Plus :size="14" /> 添加到 SMB 共享
          </button>
        </div>
      </template>
    </div>

    <div v-if="status" class="smb-shares-list">
      <strong>已共享文件夹 ({{ status.shares.length }})</strong>
      <div v-if="!status.shares.length && !loading" class="footnote">当前没有配置任何 SMB 共享文件夹。</div>
      <div v-for="share in status.shares" :key="share.recordName" class="smb-share-item">
        <div class="smb-share-header">
          <div>
            <strong>
              {{ share.smbName }}
              <span v-if="share.rootName" class="share-flag">NAS · {{ share.rootName }}</span>
              <span v-if="!share.pathExists" class="share-flag">路径离线</span>
            </strong>
            <small>{{ share.path }}</small>
            <p v-if="share.exposesPersonalDirs" class="smb-personal-warn">
              <AlertTriangle :size="13" /> 包含 Users 私人目录：SMB 使用 Mac 账号或访客权限，不受轻屿成员隔离与配额账本限制。
            </p>
          </div>
          <button
            type="button"
            class="account-action"
            :disabled="busy || !status.remoteManageReady"
            @click="removeShare(share)"
          >
            <Trash2 :size="13" /> 移除共享
          </button>
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
      <ShieldCheck :size="13" /> 移除共享仅从 macOS 共享列表取消登记，不会删除硬盘原文件。首次使用某 Mac 系统账号密码连接 SMB 时，需在 Mac「系统设置 → 通用 → 共享 → 文件共享 → Windows 文件共享」中勾选该账号。
    </p>
  </section>
</template>

<style scoped>
.smb-panel{display:grid;gap:14px}
.smb-panel .account-heading h3{display:flex;align-items:center;gap:9px;margin:0}
.smb-panel .account-heading p{margin:6px 0 0;font-size:12px;color:var(--text-secondary)}
.smb-elevation-banner{display:flex;align-items:center;gap:10px;padding:11px 14px;border-radius:12px;background:color-mix(in srgb,#f59e0b 12%,transparent);border:1px solid color-mix(in srgb,#f59e0b 35%,transparent);font-size:12px;color:var(--text-primary)}
.smb-service-bar{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:12px 14px;border-radius:14px;border:1px solid var(--fluid-card-border);background:var(--fluid-card-item-fill);flex-wrap:wrap}
.smb-service-info strong{display:block;font-size:13px}
.smb-service-info small{font-size:11px;color:var(--text-secondary)}
.smb-badge-on{color:#16a34a;font-weight:700}
.smb-badge-off{color:var(--text-secondary)}
.smb-addresses{display:flex;gap:10px;flex-wrap:wrap}
.smb-addr-pill{display:inline-flex;align-items:center;gap:8px;padding:6px 10px;border-radius:10px;border:1px solid var(--fluid-card-border);background:var(--fluid-card-fill);font-size:12px}
.smb-addr-pill code{font-family:ui-monospace,monospace}
.smb-addr-pill button{display:inline-flex;align-items:center;gap:4px;border:none;background:transparent;color:var(--accent-primary);font-size:12px;font-weight:600;cursor:pointer}
.smb-add-box{display:grid;gap:10px;padding:14px;border-radius:14px;border:1px solid var(--fluid-card-border);background:var(--fluid-card-item-fill)}
.smb-add-row{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:10px;align-items:center}
.smb-add-row input{border:1px solid var(--fluid-card-border);border-radius:10px;padding:8px 12px;background:var(--fluid-card-fill);color:var(--text-primary);font-size:13px}
.smb-add-flags{display:flex;align-items:center;gap:14px;flex-wrap:wrap;font-size:12px}
.smb-add-flags label,.smb-share-toggles label{display:inline-flex;align-items:center;gap:6px;cursor:pointer}
.smb-add-btn{margin-left:auto;display:inline-flex;align-items:center;gap:6px;border:none;border-radius:10px;padding:8px 14px;background:var(--accent-primary);color:#fff;font-size:12px;font-weight:650;cursor:pointer}
.smb-add-btn:disabled{opacity:.5;cursor:not-allowed}
.smb-shares-list{display:grid;gap:10px}
.smb-share-item{display:grid;gap:10px;padding:12px 14px;border-radius:14px;border:1px solid var(--fluid-card-border);background:var(--fluid-card-item-fill)}
.smb-share-header{display:flex;align-items:flex-start;justify-content:space-between;gap:10px}
.smb-share-header strong{display:block;font-size:13px}
.smb-share-header small{font-family:ui-monospace,monospace;font-size:11px;color:var(--text-secondary)}
.smb-share-toggles{display:flex;align-items:center;gap:16px;flex-wrap:wrap;font-size:12px;color:var(--text-secondary)}
.smb-personal-warn{display:flex;align-items:center;gap:6px;margin:4px 0 0;font-size:11px;color:#d97706}
</style>
