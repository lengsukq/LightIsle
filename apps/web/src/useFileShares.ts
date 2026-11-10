import { ref } from "vue";
import { describeUserFacingError } from "./userFacingError.js";

export type SharedFileEntry = {
  name: string;
  path: string;
  type: "folder" | "file";
  size: number;
  modified: string;
  canWrite?: boolean;
};
export type FileShare = {
  id: string;
  path: string;
  createdAt: number;
  expiresAt: number;
  kind?: string;
  hasPassword?: boolean;
  maxDownloads?: number;
  downloadCount?: number;
};

export type FileShareDependencies = {
  canList: () => boolean;
  context: () => string;
  apiPath: (path: string) => string;
  mediaPath: (path: string) => string;
  read: <T>(path: string) => Promise<T>;
  write: <T>(path: string, body: object) => Promise<T>;
  remove: (path: string) => Promise<void>;
  confirm: (message: string) => boolean | Promise<boolean>;
  origin: () => string;
};

/** All link state belongs to the selected account and physical volume.
 * After a root switch or logout, pending responses may never resurrect links.
 */
export function useFileShares(deps: FileShareDependencies) {
  const sharingFile = ref<SharedFileEntry | null>(null);
  const shareHours = ref(24);
  const sharePassword = ref("");
  const shareMaxDownloads = ref(0);
  const shareCreating = ref(false);
  const shareCreatedLink = ref("");
  const shareError = ref("");
  const shareCopied = ref("");
  const shareLinkInput = ref<HTMLInputElement | null>(null);
  const activeShares = ref<FileShare[]>([]);
  const sharesLoading = ref(false);
  const sharesError = ref("");
  const sharesLoaded = ref(false);
  let contextGeneration = 0;
  let listGeneration = 0;
  let createGeneration = 0;

  function reset() {
    contextGeneration++;
    listGeneration++;
    createGeneration++;
    sharingFile.value = null;
    shareHours.value = 24;
    sharePassword.value = "";
    shareMaxDownloads.value = 0;
    shareCreating.value = false;
    shareCreatedLink.value = "";
    shareError.value = "";
    shareCreating.value = false;
    shareCopied.value = "";
    activeShares.value = [];
    sharesLoading.value = false;
    sharesError.value = "";
    sharesLoaded.value = false;
  }

  function openShareDialog(item: SharedFileEntry) {
    if (item.type !== "file" && item.type !== "folder") return;
    createGeneration++;
    sharingFile.value = item;
    shareHours.value = 24;
    sharePassword.value = "";
    shareMaxDownloads.value = 0;
    shareError.value = "";
    shareCreatedLink.value = "";
    shareCopied.value = "";
  }

  async function loadMyShares() {
    if (!deps.canList() || sharesLoading.value) return;
    const request = ++listGeneration;
    const scope = contextGeneration;
    const context = deps.context();
    sharesLoading.value = true;
    sharesError.value = "";
    try {
      const result = await deps.read<{ shares: FileShare[] }>(deps.apiPath("/api/v2/file-shares"));
      if (request !== listGeneration || scope !== contextGeneration ||
          context !== deps.context() || !deps.canList()) return;
      activeShares.value = result.shares;
      sharesLoaded.value = true;
    } catch (error) {
      if (request === listGeneration && scope === contextGeneration && context === deps.context()) {
        sharesError.value = "读取分享列表失败：" + describeUserFacingError(error);
      }
    } finally {
      if (request === listGeneration && scope === contextGeneration) sharesLoading.value = false;
    }
  }

  async function createFileShare() {
    const item = sharingFile.value;
    if (!item || !deps.canList() || shareCreating.value) return;
    if (sharePassword.value.length > 0 &&
        (Array.from(sharePassword.value).length < 4 || new TextEncoder().encode(sharePassword.value).length > 128)) {
      shareError.value = "访问密码应为 4 至 128 字节，也可以留空不设置密码。";
      return;
    }
    if (!Number.isInteger(shareMaxDownloads.value) || shareMaxDownloads.value < 0 || shareMaxDownloads.value > 100000) {
      shareError.value = "最大下载次数必须在 0 至 100000 之间，0 表示不限制。";
      return;
    }
    const request = ++createGeneration;
    const scope = contextGeneration;
    const context = deps.context();
    shareCreating.value = true;
    shareError.value = "";
    shareCopied.value = "";
    try {
      const result = await deps.write<{ token: string; share: FileShare }>(
        deps.apiPath("/api/v2/file-shares"),
        {
          path: item.path, hours: shareHours.value,
          password: sharePassword.value, maxDownloads: shareMaxDownloads.value,
        },
      );
      if (request !== createGeneration || scope !== contextGeneration ||
          context !== deps.context() || !deps.canList()) return;
      shareCreatedLink.value = deps.origin() + deps.mediaPath(
        "/api/v2/public/file/" + encodeURIComponent(result.token),
      );
      await loadMyShares();
    } catch (error) {
      if (request !== createGeneration || scope !== contextGeneration ||
          context !== deps.context()) return;
      const code = error instanceof Error ? error.message : "request_failed";
      const labels: Record<string, string> = {
        too_many_shares: "当前账号已经创建 100 个有效链接，请撤销旧链接后重试。",
        file_too_large_to_share: "单文件超过 2 GiB，暂不能创建分享。",
        unsupported_file_identity: "无法确认所选对象的身份，请刷新文件列表后重试。",
        file_permission_denied: "你已失去此文件的读取权限。",
        invalid_share_request: "分享参数无效，请检查密码长度和下载次数。",
      };
      shareError.value = labels[code] ?? ("无法创建分享：" + code);
    } finally {
      if (request === createGeneration && scope === contextGeneration) shareCreating.value = false;
    }
  }

  async function copyShareLink() {
    if (!shareCreatedLink.value) return;
    try {
      await navigator.clipboard.writeText(shareCreatedLink.value);
      shareCopied.value = "已复制";
    } catch {
      shareLinkInput.value?.select();
      shareCopied.value = "已选中链接，请手动复制";
    }
  }

  async function revokeFileShare(share: FileShare) {
    const context = deps.context();
    if (!(await deps.confirm("停止分享“" + share.path + "”？已经发出的下载链接将立即失效。"))) return;
    if (context !== deps.context() || !deps.canList()) return;
    try {
      await deps.remove(deps.apiPath("/api/v2/file-shares/" + encodeURIComponent(share.id)));
      if (context !== deps.context() || !deps.canList()) return;
      await loadMyShares();
      if (sharingFile.value?.path === share.path) shareCreatedLink.value = "";
    } catch (error) {
      if (context === deps.context()) {
        sharesError.value = "撤销分享失败：" + describeUserFacingError(error);
      }
    }
  }

  return {
    sharingFile, shareHours, sharePassword, shareMaxDownloads, shareCreating,
    shareCreatedLink, shareError, shareCopied, shareLinkInput, activeShares,
    sharesLoading, sharesError, sharesLoaded, openShareDialog,
    loadMyShares, createFileShare, copyShareLink, revokeFileShare, reset,
  };
}
