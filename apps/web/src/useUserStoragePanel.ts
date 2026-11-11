import { computed, onMounted, onUnmounted, ref } from "vue";
import { Folder, Image as ImageIcon, Film } from "lucide-vue-next";
import { apiFetch, apiRequest } from "./apiClient.ts";
import { describeUserFacingError } from "./userFacingError.ts";
import type { SwitchTransferState } from "./UserStorageModals.vue";

export type StorageLocation = {
  category: string;
  rootID: string;
  rootGeneration: number;
  relativePath: string;
};

export type RootQuota = {
  rootID: string;
  rootGeneration: number;
  quotaBytes: number | null;
  accountedBytes: number;
  reservedBytes: number;
};

export type StoragePolicy = {
  userId: number;
  role?: string;
  unlimited?: boolean;
  quotaBytes: number | null;
  rootQuotas: RootQuota[];
  locations: StorageLocation[];
  enforcement: string;
  accountedBytes?: number;
  reservedBytes?: number;
  usageComplete?: boolean;
};

export type User = {
  id: number;
  username: string;
  role: "admin" | "member";
  enabled: boolean;
};

export type Root = {
  rootID: string;
  generation: number;
  name: string;
  online: boolean;
  isDefault?: boolean;
  filesystemAvailableBytes?: number;
  filesystemTotalBytes?: number;
};

export type SwitchTransferResponse = SwitchTransferState & {
  policy?: StoragePolicy;
};

export const GiB = 1024 ** 3;

export const STORAGE_CATEGORIES = [
  { id: "files", label: "普通文件与下载", shortLabel: "普通文件", icon: Folder },
  { id: "photos", label: "照片", shortLabel: "照片", icon: ImageIcon },
  { id: "videos", label: "视频", shortLabel: "视频", icon: Film },
];

export function prettyBytes(bytes: number | null | undefined): string {
  if (bytes === null || bytes === undefined) return "不设应用配额";
  return (bytes / GiB).toLocaleString("zh-CN", { maximumFractionDigits: 2 }) + " GiB";
}

export function migrationPhaseLabel(phase?: string): string {
  switch (phase) {
    case "copying":
      return "正在复制旧目录文件到新目录…";
    case "verifying":
      return "正在逐文件核验新目录数据完整性…";
    case "ready_to_cleanup":
      return "复制与核验已完成 · 等待确认回收旧目录源文件";
    case "completed":
      return "迁移已全部完成 · 新目录已生效";
    case "failed":
      return "迁移中断 · 旧目录原文件完好保留";
    case "cancelled":
      return "已取消迁移 · 原目录保持不变";
    default:
      return phase || "准备就绪";
  }
}

export function categoryShortLabel(catId: string): string {
  return STORAGE_CATEGORIES.find((c) => c.id === catId)?.shortLabel ?? catId;
}

export function useUserStoragePanel(isAdmin: () => boolean) {
  const users = ref<User[]>([]);
  const roots = ref<Root[]>([]);
  const registeredRoots = ref<Root[]>([]);
  const rootsKnown = ref(false);
  const policies = ref<Record<number, StoragePolicy>>({});
  const pending = ref(false);
  const error = ref("");
  const successMessage = ref("");
  const usageChecks = ref<Record<number, string>>({});

  const editingQuotaKey = ref<string | null>(null);
  const editingQuotaGiB = ref<string>("100");
  const savingQuota = ref(false);

  const showAllocModal = ref(false);
  const allocUserId = ref<number>(0);
  const allocRootId = ref<string>("");
  const allocQuotaGiB = ref<string>("100");
  const allocCategories = ref<Record<string, boolean>>({ files: true, photos: true, videos: true });
  const allocSubdirs = ref<string>("");
  const allocBusy = ref(false);
  const allocError = ref<string>("");

  const showMigrateModal = ref(false);
  const migrateUserId = ref<number>(0);
  const migrateSourceRootId = ref<string>("");
  const migrateSourceGen = ref<number>(1);
  const migrateTargetRootId = ref<string>("");
  const migrateCategories = ref<Record<string, boolean>>({ files: true, photos: true, videos: true });
  const migrateMode = ref<"migrate" | "copy" | "empty">("migrate");
  const migrateQuotaGiB = ref<string>("");
  const migratePassword = ref<string>("");
  const migrateBusy = ref(false);
  const migrateError = ref<string>("");
  const migrateStatus = ref<SwitchTransferResponse | null>(null);
  let migratePollTimer: ReturnType<typeof setInterval> | null = null;

  function findRoot(rootID: string): Root | undefined {
    return registeredRoots.value.find((r) => r.rootID === rootID);
  }

  function rootNameById(rootID: string): string {
    return findRoot(rootID)?.name ?? "已移除的原目录 (" + rootID.slice(0, 8) + ")";
  }

  function rootName(q: RootQuota): string {
    return findRoot(q.rootID)?.name ?? "原绑定目录";
  }

  function isActiveRoot(policy: StoragePolicy, q: RootQuota): boolean {
    return (
      policy.locations.some((l) => l.rootID === q.rootID && l.rootGeneration === q.rootGeneration) ||
      registeredRoots.value.some((r) => r.rootID === q.rootID && r.generation === q.rootGeneration)
    );
  }

  function allocatedDiskCount(policy: StoragePolicy): number {
    return new Set([
      ...policy.locations.map((l) => l.rootID),
      ...(policy.rootQuotas ?? []).filter((q) => isActiveRoot(policy, q)).map((q) => q.rootID),
    ]).size;
  }

  function diskLocations(policy: StoragePolicy, q: RootQuota): StorageLocation[] {
    return policy.locations.filter((l) => l.rootID === q.rootID && l.rootGeneration === q.rootGeneration);
  }

  function rootAvailable(q: RootQuota): string {
    return q.quotaBytes === null
      ? "无限制"
      : prettyBytes(Math.max(0, q.quotaBytes - q.accountedBytes - q.reservedBytes));
  }

  function isUserUnlimited(policy: StoragePolicy): boolean {
    return (
      policy.unlimited === true ||
      policy.role === "admin" ||
      users.value.find((u) => u.id === policy.userId)?.role === "admin"
    );
  }

  function boundCountForRoot(rootID: string): number {
    let count = 0;
    for (const policy of Object.values(policies.value)) {
      count += policy.locations.filter((l) => l.rootID === rootID).length;
    }
    return count;
  }

  function firstUserBoundToRoot(rootID: string): { userId: number; gen: number; cats: string[] } | null {
    for (const policy of Object.values(policies.value)) {
      const locs = policy.locations.filter((l) => l.rootID === rootID);
      if (locs.length > 0) {
        return { userId: policy.userId, gen: locs[0]!.rootGeneration, cats: locs.map((l) => l.category) };
      }
    }
    return null;
  }

  function api<T>(path: string, init: RequestInit = {}): Promise<T> {
    return apiRequest<T>(path, init);
  }

  async function load() {
    if (pending.value) return;
    pending.value = true;
    error.value = "";
    try {
      if (isAdmin()) {
        const accounts = await api<{ users: User[] }>("/api/v2/users");
        users.value = accounts.users;
        const discovery = await apiFetch("/api/v2/roots");
        rootsKnown.value = discovery.ok;
        registeredRoots.value = discovery.ok ? ((await discovery.json()) as { roots: Root[] }).roots : [];
        roots.value = registeredRoots.value.filter((r) => r.online);
        const entries = await Promise.all(
          users.value.map(async (u) => [u.id, await api<StoragePolicy>(`/api/v2/users/${u.id}/storage`)] as const)
        );
        policies.value = Object.fromEntries(entries);
      } else {
        const policy = await api<StoragePolicy>("/api/v2/me/storage");
        policies.value = { [policy.userId]: policy };
        try {
          registeredRoots.value = (await api<{ roots: Root[] }>("/api/v2/roots")).roots;
          rootsKnown.value = true;
        } catch {
          registeredRoots.value = [];
          rootsKnown.value = false;
        }
      }
    } catch (e) {
      error.value = "读取存储配置失败：" + describeUserFacingError(e);
    } finally {
      pending.value = false;
    }
  }

  async function checkOnlineUsage(policy: StoragePolicy) {
    const assigned = [...new Set(policy.locations.map((l) => l.rootID))];
    if (!assigned.length) {
      usageChecks.value[policy.userId] = "尚未分配个人目录，暂无可检查的在线目录。";
      return;
    }
    pending.value = true;
    error.value = "";
    try {
      const reports: string[] = [];
      const unavailable: string[] = [];
      for (const rootID of assigned) {
        const root = findRoot(rootID);
        if (!root || !root.online || policy.locations.some((l) => l.rootID === rootID && l.rootGeneration !== root.generation)) {
          unavailable.push(root?.name ?? rootID);
          continue;
        }
        const query = new URLSearchParams({ rootGeneration: String(root.generation) });
        try {
          const result = await api<{ liveBytes: number; entriesChecked: number; ledgerBytes: number; reservedBytes: number }>(
            `/api/v2/roots/${encodeURIComponent(rootID)}/storage/users/${policy.userId}/usage-check?${query}`
          );
          reports.push(
            `${root.name}：在线文件 ${prettyBytes(result.liveBytes)}（${result.entriesChecked} 项），账本已入账 ${prettyBytes(result.ledgerBytes)}，预占 ${prettyBytes(result.reservedBytes)}`
          );
        } catch (e) {
          unavailable.push(`${root.name}（${describeUserFacingError(e)}）`);
        }
      }
      usageChecks.value[policy.userId] =
        (reports.length ? `在线文件现场检查：${reports.join("；")}。` : "没有可用的在线目录检查结果。") +
        (unavailable.length ? ` 未能检查 ${unavailable.join("、")}，结果不完整。` : " 本次在线分类目录均已检查。") +
        " 已入账可能包含回收站，预占可能与现场文件重叠；结果仅供核对，不会自动删账或改动文件。";
    } finally {
      pending.value = false;
    }
  }

  function selectedLocation(p: StoragePolicy, category: string): StorageLocation | undefined {
    return p.locations.find((l) => l.category === category);
  }

  function rootLabel(location: StorageLocation): string {
    if (!rootsKnown.value) return "目录状态暂不可用 · 专属空间（" + location.relativePath + "）";
    const root = findRoot(location.rootID);
    return (root?.name ?? "已移除的原目录") + (root && !root.online ? " · 离线" : "") + " · " + location.relativePath;
  }

  function startEditQuota(userId: number, q: RootQuota) {
    editingQuotaKey.value = `${userId}:${q.rootID}:${q.rootGeneration}`;
    const gib = q.quotaBytes && q.quotaBytes > 0 ? Math.max(1, Math.round(q.quotaBytes / GiB)) : 100;
    editingQuotaGiB.value = String(gib);
  }

  async function saveQuota(userId: number, q: RootQuota) {
    const gib = Number(editingQuotaGiB.value.trim());
    if (!Number.isFinite(gib) || gib <= 0) {
      error.value = "请输入大于 0 的整数配额（GiB）。";
      return;
    }
    savingQuota.value = true;
    error.value = "";
    try {
      const quotaBytes = Math.round(gib * GiB);
      const updated = await api<StoragePolicy>(
        `/api/v2/users/${userId}/storage/roots/${encodeURIComponent(q.rootID)}/quota`,
        { method: "PUT", body: JSON.stringify({ rootGeneration: q.rootGeneration, quotaBytes }) }
      );
      policies.value[userId] = updated;
      editingQuotaKey.value = null;
      successMessage.value = "目录配额已保存。";
    } catch (e) {
      error.value = "保存配额失败：" + describeUserFacingError(e);
    } finally {
      savingQuota.value = false;
    }
  }

  async function abandonRemovedRoot(userId: number, q: RootQuota) {
    pending.value = true;
    error.value = "";
    try {
      const updated = await api<StoragePolicy>(
        `/api/v2/storage/users/${userId}/roots/${encodeURIComponent(q.rootID)}/abandon`,
        { method: "POST", body: JSON.stringify({ rootGeneration: q.rootGeneration }) }
      );
      policies.value[userId] = updated;
      successMessage.value = "已放弃旧目录历史绑定记录（原硬盘文件未被删除）。";
    } catch (e) {
      error.value = "放弃旧目录绑定失败：" + describeUserFacingError(e);
    } finally {
      pending.value = false;
    }
  }

  const onlineRootOptions = computed(() =>
    roots.value.map((r) => ({
      value: r.rootID,
      label: `${r.name}${r.isDefault ? " · 默认主目录" : ""}`,
      hint: r.filesystemAvailableBytes !== undefined ? `可用 ${prettyBytes(r.filesystemAvailableBytes)}` : "在线可读写",
    }))
  );

  const allocTargetPolicy = computed(() => policies.value[allocUserId.value]);

  function openAllocModal(userId: number, preferredCategory?: string) {
    allocUserId.value = userId;
    const defaultOnline = roots.value.find((r) => r.isDefault) ?? roots.value[0];
    allocRootId.value = defaultOnline?.rootID ?? "";
    allocQuotaGiB.value = "100";
    allocCategories.value = preferredCategory
      ? { files: preferredCategory === "files", photos: preferredCategory === "photos", videos: preferredCategory === "videos" }
      : { files: true, photos: true, videos: true };
    allocSubdirs.value = "";
    allocError.value = "";
    showAllocModal.value = true;
  }

  async function submitAllocation() {
    if (!allocRootId.value) {
      allocError.value = "请选择要分配的在线存储目录。";
      return;
    }
    const targetRoot = findRoot(allocRootId.value);
    if (!targetRoot || !targetRoot.online) {
      allocError.value = "所选存储目录当前不在线，请先在 Mac 管理端检查硬盘连接与读写权限。";
      return;
    }
    const selectedCats = Object.entries(allocCategories.value).filter(([, checked]) => checked).map(([cat]) => cat);
    if (selectedCats.length === 0) {
      allocError.value = "请至少勾选一项要创建的分类目录（文件 / 照片 / 视频）。";
      return;
    }
    const unlimited = allocTargetPolicy.value ? isUserUnlimited(allocTargetPolicy.value) : false;
    let quotaBytes: number | null = null;
    if (!unlimited) {
      const gib = Number(allocQuotaGiB.value.trim());
      if (!Number.isFinite(gib) || gib <= 0) {
        allocError.value = "请填写大于 0 的目录配额（GiB）。";
        return;
      }
      quotaBytes = Math.round(gib * GiB);
    }
    const subdirectories = allocSubdirs.value.split(",").map((s) => s.trim()).filter(Boolean);

    allocBusy.value = true;
    allocError.value = "";
    try {
      const updated = await api<StoragePolicy>(
        `/api/v2/roots/${encodeURIComponent(targetRoot.rootID)}/users/${allocUserId.value}/storage`,
        {
          method: "POST",
          headers: { "X-LightIsle-Root-Generation": String(targetRoot.generation) },
          body: JSON.stringify({ quotaBytes, categories: selectedCats, subdirectories }),
        }
      );
      policies.value[allocUserId.value] = updated;
      showAllocModal.value = false;
      successMessage.value = `已为用户分配「${targetRoot.name}」存储目录。`;
    } catch (e) {
      allocError.value = describeUserFacingError(e);
    } finally {
      allocBusy.value = false;
    }
  }

  const migrateTargetOptions = computed(() =>
    roots.value
      .filter((r) => r.rootID !== migrateSourceRootId.value)
      .map((r) => ({
        value: r.rootID,
        label: `${r.name}${r.isDefault ? " · 默认主目录" : ""}`,
        hint: r.filesystemAvailableBytes !== undefined ? `可用 ${prettyBytes(r.filesystemAvailableBytes)}` : "在线可读写",
      }))
  );

  const migrateSourceOptions = computed(() => {
    const p = policies.value[migrateUserId.value];
    if (!p) return [];
    const seen = new Map<string, { rootID: string; gen: number; label: string }>();
    for (const loc of p.locations) {
      const key = `${loc.rootID}:${loc.rootGeneration}`;
      if (!seen.has(key)) {
        seen.set(key, { rootID: loc.rootID, gen: loc.rootGeneration, label: `${rootNameById(loc.rootID)}（代次 #${loc.rootGeneration}）` });
      }
    }
    return [...seen.values()].map((item) => ({ value: `${item.rootID}:${item.gen}`, label: item.label }));
  });

  function syncMigrateCategoriesForSource() {
    const p = policies.value[migrateUserId.value];
    if (!p) return;
    const bound = new Set(
      p.locations.filter((l) => l.rootID === migrateSourceRootId.value && l.rootGeneration === migrateSourceGen.value).map((l) => l.category)
    );
    migrateCategories.value = { files: bound.has("files"), photos: bound.has("photos"), videos: bound.has("videos") };
  }

  const migrateSourceCompound = computed({
    get: () => `${migrateSourceRootId.value}:${migrateSourceGen.value}`,
    set: (val: string) => {
      const [rid, genStr] = val.split(":");
      if (rid) {
        migrateSourceRootId.value = rid;
        migrateSourceGen.value = Number(genStr) || 1;
        syncMigrateCategoriesForSource();
        if (migrateTargetRootId.value === rid) {
          migrateTargetRootId.value = String(migrateTargetOptions.value[0]?.value ?? "");
        }
      }
    },
  });

  function stopMigratePoll() {
    if (migratePollTimer) {
      clearInterval(migratePollTimer);
      migratePollTimer = null;
    }
  }

  function startMigratePoll() {
    stopMigratePoll();
    migratePollTimer = setInterval(() => void pollMigrateStatusOnce(), 1200);
  }

  async function pollMigrateStatusOnce() {
    if (!migrateUserId.value) return;
    try {
      const res = await api<SwitchTransferResponse>(
        `/api/v2/users/${migrateUserId.value}/storage/switch-root`,
        { method: "POST", body: JSON.stringify({ phase: "status" }) }
      );
      migrateStatus.value = res;
      if (res.policy) policies.value[migrateUserId.value] = res.policy;
      if (res.phase === "copying" || res.phase === "verifying" || res.phase === "cleaning") {
        if (!migratePollTimer) startMigratePoll();
      } else {
        stopMigratePoll();
      }
    } catch {
      stopMigratePoll();
    }
  }

  function openMigrateModal(userId: number, sourceRootId?: string, sourceGen?: number, initialCats?: string[]) {
    stopMigratePoll();
    migrateUserId.value = userId;
    const p = policies.value[userId];
    const firstLoc = p?.locations[0];
    migrateSourceRootId.value = sourceRootId ?? firstLoc?.rootID ?? "";
    migrateSourceGen.value = sourceGen ?? firstLoc?.rootGeneration ?? 1;

    if (initialCats && initialCats.length > 0) {
      const set = new Set(initialCats);
      migrateCategories.value = { files: set.has("files"), photos: set.has("photos"), videos: set.has("videos") };
    } else {
      syncMigrateCategoriesForSource();
    }

    const candidateTarget =
      roots.value.find((r) => r.rootID !== migrateSourceRootId.value && r.isDefault) ??
      roots.value.find((r) => r.rootID !== migrateSourceRootId.value);
    migrateTargetRootId.value = candidateTarget?.rootID ?? "";
    migrateMode.value = "migrate";
    migrateQuotaGiB.value = "";
    migratePassword.value = "";
    migrateError.value = "";
    migrateStatus.value = null;
    showMigrateModal.value = true;
    void pollMigrateStatusOnce();
  }

  async function startMigration() {
    if (!migrateSourceRootId.value) {
      migrateError.value = "请选择要迁出的旧目录。";
      return;
    }
    if (!migrateTargetRootId.value) {
      migrateError.value = "请选择要迁入的新目录。若尚无其他目录，请先在 Mac 管理端添加新存储目录。";
      return;
    }
    const targetRoot = findRoot(migrateTargetRootId.value);
    if (!targetRoot || !targetRoot.online) {
      migrateError.value = "目标新目录不在线，请检查硬盘连接与整盘读写权限。";
      return;
    }
    const cats = Object.entries(migrateCategories.value).filter(([, checked]) => checked).map(([cat]) => cat);
    if (cats.length === 0) {
      migrateError.value = "请至少勾选一项要迁移的分类目录。";
      return;
    }
    if (!migratePassword.value.trim()) {
      migrateError.value = "请输入当前管理员登录密码以确认目录迁移。";
      return;
    }

    let quotaBytes: number | undefined;
    if (migrateQuotaGiB.value.trim()) {
      const gib = Number(migrateQuotaGiB.value.trim());
      if (!Number.isFinite(gib) || gib <= 0) {
        migrateError.value = "目标目录配额需为大于 0 的数字（GiB），留空则沿用原配额。";
        return;
      }
      quotaBytes = Math.round(gib * GiB);
    }

    migrateBusy.value = true;
    migrateError.value = "";
    try {
      const res = await api<SwitchTransferResponse>(
        `/api/v2/users/${migrateUserId.value}/storage/switch-root`,
        {
          method: "POST",
          body: JSON.stringify({
            sourceRootID: migrateSourceRootId.value,
            sourceGeneration: migrateSourceGen.value,
            targetRootID: targetRoot.rootID,
            targetGeneration: targetRoot.generation,
            categories: cats,
            mode: migrateMode.value,
            phase: "copy_and_verify",
            quotaBytes,
            confirmationPassword: migratePassword.value,
          }),
        }
      );
      migrateStatus.value = res;
      if (res.policy) policies.value[migrateUserId.value] = res.policy;
      if (res.phase === "copying" || res.phase === "verifying") {
        startMigratePoll();
      } else if (res.phase === "completed") {
        successMessage.value = `已完成向「${targetRoot.name}」的目录迁移。`;
      }
    } catch (e) {
      migrateError.value = describeUserFacingError(e);
    } finally {
      migrateBusy.value = false;
    }
  }

  async function confirmMigrationCleanup() {
    const targetRoot = findRoot(migrateStatus.value?.targetRootID || migrateTargetRootId.value);
    if (!migratePassword.value.trim()) {
      migrateError.value = "请填写管理员登录密码以确认将旧目录源文件移入回收站。";
      return;
    }
    migrateBusy.value = true;
    migrateError.value = "";
    try {
      const res = await api<SwitchTransferResponse>(
        `/api/v2/users/${migrateUserId.value}/storage/switch-root`,
        {
          method: "POST",
          body: JSON.stringify({
            sourceRootID: migrateStatus.value?.sourceRootID || migrateSourceRootId.value,
            sourceGeneration: migrateStatus.value?.sourceGeneration || migrateSourceGen.value,
            targetRootID: migrateStatus.value?.targetRootID || targetRoot?.rootID || migrateTargetRootId.value,
            targetGeneration: migrateStatus.value?.targetGeneration || targetRoot?.generation || 1,
            categories: migrateStatus.value?.categories || [],
            mode: "migrate",
            phase: "confirm_cleanup",
            confirmationPassword: migratePassword.value,
          }),
        }
      );
      migrateStatus.value = res;
      if (res.policy) policies.value[migrateUserId.value] = res.policy;
      successMessage.value = "新目录已正式启用，旧目录原文件已安全移入该盘回收站。";
    } catch (e) {
      migrateError.value = describeUserFacingError(e);
    } finally {
      migrateBusy.value = false;
    }
  }

  async function cancelMigration() {
    migrateBusy.value = true;
    migrateError.value = "";
    try {
      const res = await api<SwitchTransferResponse>(
        `/api/v2/users/${migrateUserId.value}/storage/switch-root`,
        { method: "POST", body: JSON.stringify({ phase: "cancel" }) }
      );
      migrateStatus.value = res;
      stopMigratePoll();
    } catch (e) {
      migrateError.value = describeUserFacingError(e);
    } finally {
      migrateBusy.value = false;
    }
  }

  onMounted(load);
  onUnmounted(stopMigratePoll);

  return {
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
  };
}
