import { ref, watch, type Ref } from "vue";
import { describeUserFacingError } from "./userFacingError.ts";

export type PhotoSearchMode = "all" | "ocr" | "scene" | "person" | "path";
export type PhotoViewMode = "timeline" | "albums" | "people" | "cleanup" | "map";

export interface AIIndexingStatus {
  running: boolean;
  paused: boolean;
  remaining?: number;
  total?: number;
}

export interface PersonSummary {
  id: number;
  name: string;
  photoCount: number;
  faceCount: number;
  coverFaceId?: number;
  coverAssetId?: number;
  hidden: boolean;
}

export interface AssetFaceRef {
  faceId: number;
  personId?: number;
  personName?: string;
  boxX: number;
  boxY: number;
  boxW: number;
  boxH: number;
}

export interface AssetAIDetail {
  assetId: number;
  indexed: boolean;
  status: string;
  ocrText?: string;
  sceneLabels?: string[];
  faces?: AssetFaceRef[];
}

export interface SimilarPhotoCandidate {
  assetId: number;
  path: string;
  name: string;
  size: number;
  takenAt: number;
  width: number;
  height: number;
  sharpness: number;
  qualityScore: number;
  recommended: boolean;
  qualityBadges?: string[];
  canTrash: boolean;
}

export interface SimilarPhotoGroup {
  groupId: string;
  kind: "burst" | "similar";
  takenAt: number;
  recommendedAssetId: number;
  recommendReason: string;
  reclaimableBytes: number;
  items: SimilarPhotoCandidate[];
}

export type DuplicateKeepStrategy = "shortest_path" | "newest" | "oldest";

export interface DuplicateFileItem {
  path: string;
  name: string;
  size: number;
  modified: number;
  identity: string;
  isApfsClone?: boolean;
  isHardlink?: boolean;
  canTrash: boolean;
}

export interface DuplicateFileGroup {
  groupId: string;
  sha256?: string;
  size: number;
  count: number;
  reclaimableBytes: number;
  reclaimablePhysicalBytes: number;
  allApfsClones?: boolean;
  items: DuplicateFileItem[];
}

export const PHOTO_SEARCH_MODES: Array<{ value: PhotoSearchMode; label: string; placeholder: string }> = [
  { value: "all", label: "智能全搜", placeholder: "搜画面语义（海边日落/猫）、图中文字、人物或文件名…" },
  { value: "scene", label: "画面语义", placeholder: "自然语言搜画面，如「海边日落」「猫咪」「美食」…" },
  { value: "ocr", label: "图中搜字", placeholder: "搜截图、发票、合同、证件中的文字…" },
  { value: "person", label: "人物姓名", placeholder: "按已命名的人物搜索，如「宝宝」「妈妈」…" },
  { value: "path", label: "文件名", placeholder: "按文件名或所在目录名称匹配…" },
];

export function appendAISearchParams(
  query: URLSearchParams,
  searchTerm: string,
  searchMode: PhotoSearchMode,
  personId: number,
): void {
  if (personId > 0) {
    query.set("personId", String(personId));
  }
  if (searchTerm.trim() !== "" && searchMode !== "all") {
    query.set("searchMode", searchMode);
  }
}

export function selectRecommendedWasteIds(group: SimilarPhotoGroup): number[] {
  const keepId = group.recommendedAssetId || group.items[0]?.assetId || 0;
  return group.items
    .filter((it) => it.assetId !== keepId && it.canTrash)
    .map((it) => it.assetId);
}

export function chooseDuplicateKeepPath(
  items: DuplicateFileItem[],
  strategy: DuplicateKeepStrategy,
): string {
  if (!items.length) return "";
  const sorted = [...items].sort((a, b) => {
    if (strategy === "newest") {
      if (b.modified !== a.modified) return b.modified - a.modified;
    } else if (strategy === "oldest") {
      if (a.modified !== b.modified) return a.modified - b.modified;
    } else {
      if (a.path.length !== b.path.length) return a.path.length - b.path.length;
    }
    return a.path.localeCompare(b.path);
  });
  return sorted[0]?.path ?? "";
}

export function usePhotoAISearchAndPeople(options: {
  selected: Ref<{ id: number; type: string } | null>;
  viewMode: Ref<PhotoViewMode>;
  message: Ref<string>;
  api: <T = unknown>(url: string, method?: string, body?: object, signal?: AbortSignal) => Promise<T>;
  apiPath: (path: string) => string;
  onFilterChanged: () => void;
  onStatusRefresh: () => Promise<unknown>;
}) {
  const searchMode = ref<PhotoSearchMode>("all");
  const activePerson = ref<{ id: number; name: string } | null>(null);
  const viewerAIDetail = ref<AssetAIDetail | null>(null);
  const viewerAILoading = ref(false);
  const aiPauseBusy = ref(false);
  let detailAbort: AbortController | null = null;

  function currentSearchPlaceholder(): string {
    return PHOTO_SEARCH_MODES.find((m) => m.value === searchMode.value)?.placeholder ?? "搜索照片…";
  }

  function setSearchMode(mode: PhotoSearchMode, hasActiveQuery: boolean) {
    if (searchMode.value === mode) return;
    searchMode.value = mode;
    if (hasActiveQuery) {
      options.onFilterChanged();
    }
  }

  function filterByPerson(person: { id: number; name: string }) {
    activePerson.value = { id: person.id, name: person.name || `人物 #${person.id}` };
    options.viewMode.value = "timeline";
    options.onFilterChanged();
  }

  function clearPersonFilter() {
    if (!activePerson.value) return;
    activePerson.value = null;
    options.onFilterChanged();
  }

  function resetAIStateForRootChange() {
    searchMode.value = "all";
    activePerson.value = null;
    viewerAIDetail.value = null;
    viewerAILoading.value = false;
    detailAbort?.abort();
    detailAbort = null;
  }

  async function toggleAIPause(currentlyPaused: boolean) {
    if (aiPauseBusy.value) return;
    aiPauseBusy.value = true;
    try {
      await options.api(options.apiPath("/api/v2/photos/ai/pause"), "POST", { paused: !currentlyPaused });
      options.message.value = !currentlyPaused ? "已暂停后台智能识图索引" : "已恢复后台智能识图索引";
      await options.onStatusRefresh();
    } catch (e) {
      options.message.value = "切换智能索引状态失败：" + describeUserFacingError(e);
    } finally {
      aiPauseBusy.value = false;
    }
  }

  watch(
    () => options.selected.value,
    async (asset) => {
      detailAbort?.abort();
      detailAbort = null;
      viewerAIDetail.value = null;
      if (!asset || asset.type !== "photo") {
        viewerAILoading.value = false;
        return;
      }
      const controller = new AbortController();
      detailAbort = controller;
      viewerAILoading.value = true;
      try {
        const res = await options.api<AssetAIDetail>(
          options.apiPath(`/api/v2/photos/${asset.id}/ai`),
          "GET",
          undefined,
          controller.signal,
        );
        if (detailAbort === controller) {
          viewerAIDetail.value = res;
        }
      } catch {
        // Non-blocking: EXIF sidebar still works even if AI detail has not been indexed yet.
      } finally {
        if (detailAbort === controller) {
          viewerAILoading.value = false;
        }
      }
    },
  );

  function disposeAISearch() {
    detailAbort?.abort();
    detailAbort = null;
  }

  return {
    searchMode,
    activePerson,
    viewerAIDetail,
    viewerAILoading,
    aiPauseBusy,
    currentSearchPlaceholder,
    setSearchMode,
    filterByPerson,
    clearPersonFilter,
    resetAIStateForRootChange,
    toggleAIPause,
    disposeAISearch,
  };
}
