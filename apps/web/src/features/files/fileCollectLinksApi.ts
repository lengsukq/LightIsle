import { ref } from "vue";
import { describeUserFacingError } from "../../api/userFacingError.ts";
import { copyTextToClipboard } from "../../utils/clipboard.ts";

export interface CollectLink {
  id: string;
  rootId: string;
  rootGeneration: number;
  targetPath: string;
  title: string;
  hasPassword: boolean;
  maxFiles: number;
  maxFileBytes: number;
  maxTotalBytes: number;
  uploadedFiles: number;
  uploadedBytes: number;
  allowedExts?: string[];
  createdAt: number;
  expiresAt: number;
}

export interface CollectLinkDraft {
  path: string;
  hours: number;
  title: string;
  password: string;
  maxFiles: number;
  maxFileBytes: number;
  maxTotalBytes: number;
  allowedExtsText: string;
}

export interface CollectLinkDependencies {
  canList: () => boolean;
  context: () => string;
  apiPath: (path: string) => string;
  mediaPath: (path: string) => string;
  read: <T>(path: string) => Promise<T>;
  write: <T>(path: string, body: object) => Promise<T>;
  remove: (path: string) => Promise<void>;
  confirm: (opts: {
    title?: string;
    message: string;
    confirmText?: string;
    variant?: "default" | "danger";
  }) => boolean | Promise<boolean>;
  origin: () => string;
}

export const MAX_COLLECT_HOURS = 720;
export const MAX_COLLECT_FILES = 10_000;
export const MAX_COLLECT_SINGLE_BYTES = 32 * 1024 * 1024 * 1024;
export const MAX_COLLECT_TOTAL_BYTES = 1024 * 1024 * 1024 * 1024;

export const COLLECT_HOUR_OPTIONS = [
  { value: 1, label: "1 小时" },
  { value: 24, label: "1 天" },
  { value: 72, label: "3 天" },
  { value: 168, label: "7 天" },
  { value: 720, label: "30 天" },
];

export const COLLECT_MAX_FILE_SIZE_OPTIONS = [
  { value: 0, label: "不限单文件体积" },
  { value: 50 * 1024 * 1024, label: "50 MiB" },
  { value: 200 * 1024 * 1024, label: "200 MiB" },
  { value: 1024 * 1024 * 1024, label: "1 GiB" },
  { value: 5 * 1024 * 1024 * 1024, label: "5 GiB" },
  { value: MAX_COLLECT_SINGLE_BYTES, label: "32 GiB" },
];

export const COLLECT_MAX_TOTAL_SIZE_OPTIONS = [
  { value: 0, label: "不限总接收体积" },
  { value: 500 * 1024 * 1024, label: "500 MiB" },
  { value: 2 * 1024 * 1024 * 1024, label: "2 GiB" },
  { value: 10 * 1024 * 1024 * 1024, label: "10 GiB" },
  { value: 50 * 1024 * 1024 * 1024, label: "50 GiB" },
  { value: 200 * 1024 * 1024 * 1024, label: "200 GiB" },
];

const EXT_TOKEN_RULE = /^\.[a-z0-9]{1,16}$/;

export function parseAllowedExtensions(raw: string): { exts: string[]; invalid: string[] } {
  const tokens = raw
    .split(/[\s,，;；]+/)
    .map((t) => t.trim().toLowerCase())
    .filter(Boolean);
  const seen = new Set<string>();
  const exts: string[] = [];
  const invalid: string[] = [];
  for (const token of tokens) {
    const normalized = token.startsWith(".") ? token : `.${token}`;
    if (!EXT_TOKEN_RULE.test(normalized)) {
      invalid.push(token);
      continue;
    }
    if (!seen.has(normalized)) {
      seen.add(normalized);
      exts.push(normalized);
    }
  }
  return { exts, invalid };
}

export function validateCollectLinkDraft(draft: CollectLinkDraft): string | null {
  const target = draft.path.trim();
  if (!target || target === ".") {
    return "请选择一个具体的可写子文件夹作为收集目标。";
  }
  if (!Number.isInteger(draft.hours) || draft.hours < 1 || draft.hours > MAX_COLLECT_HOURS) {
    return `有效期必须在 1 至 ${MAX_COLLECT_HOURS} 小时之间。`;
  }
  const titleLen = Array.from(draft.title.trim()).length;
  if (titleLen > 120) {
    return "收集箱标题不能超过 120 个字符。";
  }
  if (draft.password.length > 0) {
    const runeCount = Array.from(draft.password).length;
    const byteLen = new TextEncoder().encode(draft.password).length;
    if (runeCount < 4 || byteLen > 128) {
      return "访问口令应为 4 至 128 字节，也可以留空不设口令。";
    }
  }
  if (!Number.isInteger(draft.maxFiles) || draft.maxFiles < 0 || draft.maxFiles > MAX_COLLECT_FILES) {
    return `最大接收文件数必须在 0 至 ${MAX_COLLECT_FILES} 之间，0 表示不限。`;
  }
  if (!Number.isFinite(draft.maxFileBytes) || draft.maxFileBytes < 0 || draft.maxFileBytes > MAX_COLLECT_SINGLE_BYTES) {
    return "单文件体积上限不能超过 32 GiB。";
  }
  if (!Number.isFinite(draft.maxTotalBytes) || draft.maxTotalBytes < 0 || draft.maxTotalBytes > MAX_COLLECT_TOTAL_BYTES) {
    return "总接收容量上限超出限制。";
  }
  if (draft.maxFileBytes > 0 && draft.maxTotalBytes > 0 && draft.maxFileBytes > draft.maxTotalBytes) {
    return "单文件上限不能大于总容量上限。";
  }
  const { exts, invalid } = parseAllowedExtensions(draft.allowedExtsText);
  if (invalid.length > 0) {
    return `扩展名格式无效：${invalid.slice(0, 3).join("、")}（示例：.jpg .png .mp4）。`;
  }
  if (exts.length > 32) {
    return "最多设置 32 个允许上传的扩展名。";
  }
  return null;
}

export function buildCollectPublicUrl(origin: string, publicPath: string, fallbackMediaPath: string, token: string): string {
  const cleanOrigin = origin.replace(/\/+$/, "");
  if (publicPath && publicPath.startsWith("/")) {
    return cleanOrigin + publicPath;
  }
  return cleanOrigin + fallbackMediaPath.replace(/\/+$/, "") + "/" + encodeURIComponent(token);
}

export function describeCollectLinkError(error: unknown, fallbackPrefix = "操作失败："): string {
  const code = error instanceof Error ? error.message : "";
  const map: Record<string, string> = {
    too_many_collect_links: "当前目录收集链接数量已达上限（50 个），请撤销不再使用的链接后重试。",
    collect_target_must_be_folder: "收集链接只能绑定到文件夹，不能绑定到单个文件。",
    invalid_collect_link_request: "收集链接参数无效，请检查标题、有效期、口令和配额上限。",
    unsupported_file_identity: "无法确认目标文件夹身份，请刷新文件列表后重试。",
    file_permission_denied: "没有该文件夹的写入权限，无法创建收集链接。",
    invalid_collect_link_id: "收集链接标识无效，请刷新列表后重试。",
    collect_link_creation_failed: "创建收集链接失败，请稍后重试。",
    collect_link_list_failed: "读取收集链接列表失败，请稍后重试。",
    collect_link_revoke_failed: "撤销收集链接失败，请稍后重试。",
  };
  return map[code] ?? fallbackPrefix + describeUserFacingError(error);
}

export function useCollectLinks(deps: CollectLinkDependencies) {
  const collectLinks = ref<CollectLink[]>([]);
  const linksLoading = ref(false);
  const linksLoaded = ref(false);
  const linksError = ref("");
  const creating = ref(false);
  const createError = ref("");
  const createdUrl = ref("");
  const createdLink = ref<CollectLink | null>(null);
  const copiedStatus = ref("");
  const revokingId = ref("");

  let contextGeneration = 0;
  let listGeneration = 0;
  let createGeneration = 0;

  function reset() {
    contextGeneration += 1;
    listGeneration += 1;
    createGeneration += 1;
    collectLinks.value = [];
    linksLoading.value = false;
    linksLoaded.value = false;
    linksError.value = "";
    creating.value = false;
    createError.value = "";
    createdUrl.value = "";
    createdLink.value = null;
    copiedStatus.value = "";
    revokingId.value = "";
  }

  function clearCreated() {
    createGeneration += 1;
    createError.value = "";
    createdUrl.value = "";
    createdLink.value = null;
    copiedStatus.value = "";
  }

  async function loadCollectLinks(force = false) {
    if (!deps.canList()) return;
    if (linksLoading.value && !force) return;
    const req = ++listGeneration;
    const scope = contextGeneration;
    const ctx = deps.context();
    linksLoading.value = true;
    linksError.value = "";
    try {
      const res = await deps.read<{ links: CollectLink[] }>(deps.apiPath("/api/v2/collect-links"));
      if (req !== listGeneration || scope !== contextGeneration || ctx !== deps.context() || !deps.canList()) {
        return;
      }
      collectLinks.value = Array.isArray(res?.links) ? res.links : [];
      linksLoaded.value = true;
    } catch (error) {
      if (req === listGeneration && scope === contextGeneration && ctx === deps.context()) {
        linksError.value = describeCollectLinkError(error, "读取收集链接失败：");
      }
    } finally {
      if (req === listGeneration && scope === contextGeneration) {
        linksLoading.value = false;
      }
    }
  }

  async function createCollectLink(draft: CollectLinkDraft): Promise<boolean> {
    if (!deps.canList() || creating.value) return false;
    const validationError = validateCollectLinkDraft(draft);
    if (validationError) {
      createError.value = validationError;
      return false;
    }
    const { exts } = parseAllowedExtensions(draft.allowedExtsText);
    const req = ++createGeneration;
    const scope = contextGeneration;
    const ctx = deps.context();
    creating.value = true;
    createError.value = "";
    copiedStatus.value = "";
    try {
      const payload: Record<string, unknown> = {
        path: draft.path.trim(),
        hours: draft.hours,
      };
      if (draft.title.trim()) payload.title = draft.title.trim();
      if (draft.password) payload.password = draft.password;
      if (draft.maxFiles > 0) payload.maxFiles = draft.maxFiles;
      if (draft.maxFileBytes > 0) payload.maxFileBytes = Math.trunc(draft.maxFileBytes);
      if (draft.maxTotalBytes > 0) payload.maxTotalBytes = Math.trunc(draft.maxTotalBytes);
      if (exts.length > 0) payload.allowedExts = exts;

      const res = await deps.write<{ link: CollectLink; token: string; publicPath: string }>(
        deps.apiPath("/api/v2/collect-links"),
        payload,
      );
      if (req !== createGeneration || scope !== contextGeneration || ctx !== deps.context() || !deps.canList()) {
        return false;
      }
      createdLink.value = res.link;
      createdUrl.value = buildCollectPublicUrl(
        deps.origin(),
        res.publicPath,
        deps.mediaPath("/api/v2/public/collect"),
        res.token,
      );
      await loadCollectLinks(true);
      return true;
    } catch (error) {
      if (req === createGeneration && scope === contextGeneration && ctx === deps.context()) {
        createError.value = describeCollectLinkError(error, "无法创建收集链接：");
      }
      return false;
    } finally {
      if (req === createGeneration && scope === contextGeneration) {
        creating.value = false;
      }
    }
  }

  async function copyCreatedUrl(inputEl?: HTMLInputElement | null) {
    if (!createdUrl.value) return;
    if (await copyTextToClipboard(createdUrl.value)) {
      copiedStatus.value = "已复制";
    } else {
      inputEl?.select();
      copiedStatus.value = "已选中链接，请手动复制";
    }
  }

  async function revokeCollectLink(link: CollectLink): Promise<boolean> {
    if (!deps.canList() || revokingId.value) return false;
    const scope = contextGeneration;
    const ctx = deps.context();
    const ok = await deps.confirm({
      title: "撤销文件收集链接",
      message: `撤销「${link.title || link.targetPath}」后，亲友将无法再通过该链接投递文件，已收到的文件会保留在文件夹内。`,
      confirmText: "确认撤销",
      variant: "danger",
    });
    if (!ok || scope !== contextGeneration || ctx !== deps.context() || !deps.canList()) {
      return false;
    }
    revokingId.value = link.id;
    linksError.value = "";
    try {
      await deps.remove(deps.apiPath("/api/v2/collect-links/" + encodeURIComponent(link.id)));
      if (scope !== contextGeneration || ctx !== deps.context() || !deps.canList()) return false;
      if (createdLink.value?.id === link.id) {
        createdUrl.value = "";
        createdLink.value = null;
      }
      await loadCollectLinks(true);
      return true;
    } catch (error) {
      if (scope === contextGeneration && ctx === deps.context()) {
        linksError.value = describeCollectLinkError(error, "撤销收集链接失败：");
      }
      return false;
    } finally {
      if (revokingId.value === link.id) revokingId.value = "";
    }
  }

  return {
    collectLinks,
    linksLoading,
    linksLoaded,
    linksError,
    creating,
    createError,
    createdUrl,
    createdLink,
    copiedStatus,
    revokingId,
    loadCollectLinks,
    createCollectLink,
    copyCreatedUrl,
    revokeCollectLink,
    clearCreated,
    reset,
  };
}
