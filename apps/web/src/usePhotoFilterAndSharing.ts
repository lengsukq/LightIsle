import { computed, ref, type Ref } from "vue";
import { describeRootOperationFailure } from "./rootDiscovery.ts";

export type FolderAlbumShare = {
  id: number;
  memberUserId: number;
  memberUsername: string;
  linkName: string;
  canWrite: boolean;
};

export type FolderAlbum = {
  name: string;
  path: string;
  shared?: boolean;
  ownerUserId?: number;
  ownerUsername?: string;
  memberUserId?: number;
  canWrite?: boolean;
  shares?: FolderAlbumShare[];
};

export type ShareTarget = {
  userId: number;
  username: string;
};

export type PhotoFacets = {
  cameras: string[];
  years: number[];
};

export function usePhotoFilterAndSharing(deps: {
  api: <T>(url: string, method?: string, body?: object, signal?: AbortSignal) => Promise<T>;
  apiPath: (path: string) => string;
  albumBusy: Ref<boolean>;
  message: Ref<string>;
  refreshFolderAlbums: (more?: boolean) => Promise<void>;
  onFilterChanged: () => void;
}) {
  const cameraFilter = ref("");
  const locationFilter = ref<"" | "1" | "0">("");
  const yearFilter = ref(0);
  const facets = ref<PhotoFacets>({ cameras: [], years: [] });
  const shareTargets = ref<ShareTarget[]>([]);
  const sharingAlbum = ref<FolderAlbum | null>(null);
  const shareMemberId = ref(0);
  const shareCanWrite = ref(false);

  const cameraOptions = computed(() => [
    { value: "", label: "全部相机" },
    ...facets.value.cameras.map((cam) => ({ value: cam, label: cam })),
  ]);

  const locationOptions = computed(() => [
    { value: "", label: "全部位置" },
    { value: "1", label: "含定位" },
    { value: "0", label: "无定位" },
  ]);

  const filterYearOptions = computed(() => [
    { value: 0, label: "全部年份" },
    ...facets.value.years.map((yr) => ({ value: yr, label: `${yr} 年` })),
  ]);

  const shareTargetOptions = computed(() => [
    { value: 0, label: "选择家庭成员…" },
    ...shareTargets.value.map((t) => ({ value: t.userId, label: t.username })),
  ]);

  function hasActiveExifFilter() {
    return Boolean(cameraFilter.value || locationFilter.value || yearFilter.value > 0);
  }

  function resetExifFilters() {
    cameraFilter.value = "";
    locationFilter.value = "";
    yearFilter.value = 0;
  }

  function appendExifFilterParams(query: URLSearchParams) {
    if (cameraFilter.value) query.set("camera", cameraFilter.value);
    if (locationFilter.value) query.set("hasLocation", locationFilter.value);
    if (yearFilter.value > 0) {
      const from = Math.floor(new Date(yearFilter.value, 0, 1, 0, 0, 0).getTime() / 1000);
      const to = Math.floor(new Date(yearFilter.value, 11, 31, 23, 59, 59).getTime() / 1000);
      query.set("takenFrom", String(from));
      query.set("takenTo", String(to));
    }
  }

  async function refreshFacets() {
    try {
      const res = await deps.api<PhotoFacets>(deps.apiPath("/api/v2/photos/facets"));
      facets.value = {
        cameras: Array.isArray(res.cameras) ? res.cameras : [],
        years: Array.isArray(res.years) ? res.years : [],
      };
    } catch {
      facets.value = { cameras: [], years: [] };
    }
  }

  function openSharePanel(album: FolderAlbum) {
    if (sharingAlbum.value?.path === album.path) {
      sharingAlbum.value = null;
      return;
    }
    sharingAlbum.value = album;
    shareMemberId.value = shareTargets.value[0]?.userId ?? 0;
    shareCanWrite.value = false;
  }

  async function submitFolderAlbumShare(album: FolderAlbum) {
    if (deps.albumBusy.value || !shareMemberId.value) return;
    deps.albumBusy.value = true;
    deps.message.value = "";
    try {
      await deps.api(
        deps.apiPath(`/api/v2/photos/folder-albums/${encodeURIComponent(album.name)}/shares`),
        "POST",
        { memberUserId: shareMemberId.value, canWrite: shareCanWrite.value },
      );
      await deps.refreshFolderAlbums();
      deps.message.value = `已将相册「${album.name}」共享给所选成员（${shareCanWrite.value ? "可读写，写入计入你的配额" : "只读"}）。`;
    } catch (error) {
      deps.message.value = "共享文件夹相册失败：" + describeRootOperationFailure(error);
    } finally {
      deps.albumBusy.value = false;
    }
  }

  async function removeFolderAlbumShare(album: FolderAlbum, memberUserId: number, ownerUserId?: number) {
    if (deps.albumBusy.value) return;
    deps.albumBusy.value = true;
    deps.message.value = "";
    try {
      const memberSegment = memberUserId > 0 ? String(memberUserId) : "me";
      const qs = ownerUserId ? `?ownerUserId=${encodeURIComponent(String(ownerUserId))}` : "";
      await deps.api(
        deps.apiPath(`/api/v2/photos/folder-albums/${encodeURIComponent(album.name)}/shares/${memberSegment}`) + qs,
        "DELETE",
      );
      await deps.refreshFolderAlbums();
      deps.message.value = album.shared ? `已退出共享相册「${album.name}」。` : `已取消对该成员的相册共享。`;
    } catch (error) {
      deps.message.value = "取消相册共享失败：" + describeRootOperationFailure(error);
    } finally {
      deps.albumBusy.value = false;
    }
  }

  function onExifFilterChange() {
    deps.onFilterChanged();
  }

  return {
    cameraFilter,
    locationFilter,
    yearFilter,
    facets,
    shareTargets,
    sharingAlbum,
    shareMemberId,
    shareCanWrite,
    cameraOptions,
    locationOptions,
    filterYearOptions,
    shareTargetOptions,
    hasActiveExifFilter,
    resetExifFilters,
    appendExifFilterParams,
    refreshFacets,
    openSharePanel,
    submitFolderAlbumShare,
    removeFolderAlbumShare,
    onExifFilterChange,
  };
}
