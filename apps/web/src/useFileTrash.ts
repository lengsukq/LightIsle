import { ref } from "vue";

export type FileTrashEntry = {
  id: string;
  name: string;
  originalPath: string;
  deletedAt: string;
};

type FileTrashDependencies = {
  epoch: () => number;
  path: (path: string) => string;
  read: <T>(path: string) => Promise<T>;
  write: (path: string) => Promise<unknown>;
  remove: (path: string) => Promise<void>;
  refreshFiles: () => Promise<unknown>;
  isAbort: (error: unknown) => boolean;
  errorLabel: (error: unknown) => string;
  confirm: (message: string) => boolean | Promise<boolean>;
};

/// One root-scoped home for trash list, retention, restore and permanent purge.
/// All late responses are discarded after a root change or account logout.
export function useFileTrash(deps: FileTrashDependencies) {
  const trashItems = ref<FileTrashEntry[]>([]);
  const trashRetention = ref<{ enabled: boolean; days: number } | null>(null);
  const trashLoading = ref(false);
  const trashBusy = ref(false);
  const trashError = ref("");
  const trashNotice = ref("");
  const showingTrash = ref(false);
  let generation = 0;

  function reset() {
    generation++;
    trashItems.value = [];
    trashRetention.value = null;
    trashLoading.value = false;
    trashBusy.value = false;
    trashError.value = "";
    trashNotice.value = "";
    showingTrash.value = false;
  }

  function current(request: number, rootEpoch: number) {
    return generation === request && deps.epoch() === rootEpoch;
  }

  async function loadTrash() {
    const request = ++generation;
    const epoch = deps.epoch();
    trashLoading.value = true;
    trashError.value = "";
    try {
      const result = await deps.read<{ entries: FileTrashEntry[] }>(
        deps.path("/api/v2/files/trash"),
      );
      if (!current(request, epoch)) return;
      trashItems.value = [...result.entries].sort(
        (a, b) => b.deletedAt.localeCompare(a.deletedAt),
      );
      void deps.read<{ enabled: boolean; days: number }>(
        deps.path("/api/v2/trash/retention"),
      ).then(value => {
        if (current(request, epoch)) trashRetention.value = value;
      }).catch(() => {});
    } catch (error) {
      if (current(request, epoch) && !deps.isAbort(error)) {
        trashError.value = "读取回收站失败：" + deps.errorLabel(error);
      }
    } finally {
      if (generation === request) {
        trashLoading.value = false;
        if (epoch !== deps.epoch()) {
          trashError.value = "共享目录已变化，请重新加载回收站。";
        }
      }
    }
  }

  async function openTrash() {
    showingTrash.value = !showingTrash.value;
    if (showingTrash.value) {
      await loadTrash();
    } else {
      generation++;
      trashLoading.value = false;
      trashNotice.value = "";
    }
  }

  async function restoreTrash(entry: FileTrashEntry) {
    if (trashBusy.value) return;
    const epoch = deps.epoch();
    const request = generation;
    trashBusy.value = true;
    trashError.value = "";
    trashNotice.value = "";
    try {
      await deps.write(deps.path("/api/v2/files/trash/" +
        encodeURIComponent(entry.id) + "/restore"));
      if (!current(request, epoch)) return;
      await loadTrash();
      if (deps.epoch() === epoch) await deps.refreshFiles();
      if (current(request, epoch)) trashNotice.value = "已恢复「" + entry.name + "」到原位置。";
    } catch (error) {
      if (current(request, epoch) && !deps.isAbort(error)) {
        trashError.value = "未能确认恢复结果：" + deps.errorLabel(error);
      }
    } finally {
      trashBusy.value = false;
    }
  }

  async function purgeTrashItem(entry: FileTrashEntry) {
    if (trashBusy.value) return;
    const epoch = deps.epoch();
    if (!(await deps.confirm(`永久删除“${entry.name}”？此操作无法撤销。`))) return;
    if (epoch !== deps.epoch()) return;
    const request = generation;
    trashBusy.value = true;
    trashError.value = "";
    trashNotice.value = "";
    try {
      await deps.remove(deps.path("/api/v2/files/trash/" +
        encodeURIComponent(entry.id)));
      if (current(request, epoch)) {
        await loadTrash();
        if (current(request, epoch)) trashNotice.value = "已永久删除「" + entry.name + "」。";
      }
    } catch (error) {
      if (current(request, epoch) && !deps.isAbort(error)) {
        trashError.value = "未能确认永久删除结果：" + deps.errorLabel(error);
      }
    } finally {
      trashBusy.value = false;
    }
  }

  return {
    trashItems, trashRetention, trashLoading, trashBusy, trashError, trashNotice, showingTrash,
    loadTrash, openTrash, restoreTrash, purgeTrashItem, reset,
  };
}
