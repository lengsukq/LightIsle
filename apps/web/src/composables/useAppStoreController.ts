import { ref, type Ref } from "vue";
import { describeUserFacingError } from "../api/userFacingError.ts";
import { requestConfirm } from "./useConfirmDialog.ts";
import type { createAppsCenterClient } from "../features/apps/appsCenterApi.ts";
import type {
  AppStoreConfigPayload,
  AppStorePluginItem,
  AppStoreSnapshot,
} from "../types/appsCenter.ts";

export function useAppStoreController(deps: {
  apiClient: ReturnType<typeof createAppsCenterClient>;
  selectedInstallLocationId: Ref<string>;
  applyAppsPayload: (payload: Record<string, unknown>) => void;
  error: Ref<string>;
  notice: Ref<string>;
}) {
  const store = ref<AppStoreSnapshot | null>(null);
  const storeLoading = ref(false);
  const storeActionPluginId = ref("");
  const storeError = ref("");
  let autoRefreshAttempted = false;

  function applyStoreFromPayload(payload: Record<string, unknown>) {
    if (payload.store && typeof payload.store === "object") {
      store.value = payload.store as AppStoreSnapshot;
      if (store.value.error) {
        storeError.value = store.value.error;
      } else if (store.value.source === "remote" || store.value.source === "cache") {
        storeError.value = "";
      }
    }
  }

  function maybeAutoRefreshStore(isAdmin: boolean) {
    if (!isAdmin || autoRefreshAttempted || storeLoading.value) return;
    if (store.value && store.value.source !== "empty") return;
    autoRefreshAttempted = true;
    void refreshStore(true);
  }

  async function refreshStore(silent = false) {
    if (storeLoading.value) return;
    storeLoading.value = true;
    storeError.value = "";
    if (!silent) {
      deps.error.value = "";
      deps.notice.value = "";
    }
    try {
      const res = await deps.apiClient.refreshStore();
      deps.applyAppsPayload(res);
      applyStoreFromPayload(res);
      if (res.error || res.store?.error) {
        storeError.value = String(res.message || res.store?.error || "暂时无法连接在线插件商店。");
      } else if (!silent) {
        const count = res.store?.plugins?.length ?? 0;
        deps.notice.value = `已从 Git 在线商店同步最新目录（共 ${count} 款插件）。`;
      }
    } catch (e) {
      storeError.value = "同步在线商店失败：" + describeUserFacingError(e);
    } finally {
      storeLoading.value = false;
    }
  }

  async function saveStoreConfig(payload: AppStoreConfigPayload) {
    if (storeLoading.value) return;
    storeLoading.value = true;
    storeError.value = "";
    deps.error.value = "";
    deps.notice.value = "";
    try {
      const res = await deps.apiClient.updateStoreConfig(payload);
      deps.applyAppsPayload(res);
      applyStoreFromPayload(res);
      if (res.warning || res.store?.error) {
        storeError.value = String(res.warning || res.store?.error);
        deps.notice.value = payload.resetDefault
          ? "已恢复官方默认商店源，但当前拉取目录失败，请检查网络。"
          : "已保存商店源设置，但拉取目录暂未成功，请检查地址或镜像。";
      } else {
        deps.notice.value = payload.resetDefault
          ? "已恢复官方 Git 插件商店并同步最新目录。"
          : "已保存商店源设置并同步最新插件目录。";
      }
    } catch (e) {
      storeError.value = "保存商店源设置失败：" + describeUserFacingError(e);
    } finally {
      storeLoading.value = false;
    }
  }

  async function installStorePlugin(plugin: AppStorePluginItem) {
    if (storeActionPluginId.value) return;
    storeActionPluginId.value = plugin.id;
    deps.error.value = "";
    deps.notice.value = "";
    try {
      const res = await deps.apiClient.installStorePlugin(
        plugin.id,
        deps.selectedInstallLocationId.value || undefined,
      );
      deps.applyAppsPayload(res);
      applyStoreFromPayload(res);
      const pending = Boolean(res.app?.pendingActivation);
      deps.notice.value = pending
        ? `已下载并校验「${plugin.name}」(v${plugin.version})，请在已安装列表中点击「确认激活」后使用。`
        : `已从在线商店下载并安装「${plugin.name}」(v${plugin.version})，SHA-256 校验通过。`;
    } catch (e) {
      deps.error.value = `下载安装「${plugin.name}」失败：` + describeUserFacingError(e);
    } finally {
      storeActionPluginId.value = "";
    }
  }

  async function upgradeStorePlugin(plugin: AppStorePluginItem) {
    if (storeActionPluginId.value) return;
    const fromVer = plugin.installedVersion ? `v${plugin.installedVersion}` : "当前版本";
    const ok = await requestConfirm({
      title: `更新「${plugin.name}」`,
      message: `确认从 ${fromVer} 升级到 v${plugin.version}？\n系统会校验 SHA-256 并安全替换插件代码，您的家庭业务数据、KV 存储与成员权限配置将完整保留。`,
      confirmText: `更新到 v${plugin.version}`,
    });
    if (!ok) return;
    storeActionPluginId.value = plugin.id;
    deps.error.value = "";
    deps.notice.value = "";
    try {
      const res = await deps.apiClient.upgradeStorePlugin(plugin.id);
      deps.applyAppsPayload(res);
      applyStoreFromPayload(res);
      deps.notice.value = `已将「${plugin.name}」无损升级至 v${plugin.version}，业务数据已保留。`;
    } catch (e) {
      deps.error.value = `升级「${plugin.name}」失败：` + describeUserFacingError(e);
    } finally {
      storeActionPluginId.value = "";
    }
  }

  return {
    store,
    storeLoading,
    storeActionPluginId,
    storeError,
    applyStoreFromPayload,
    maybeAutoRefreshStore,
    refreshStore,
    saveStoreConfig,
    installStorePlugin,
    upgradeStorePlugin,
  };
}
