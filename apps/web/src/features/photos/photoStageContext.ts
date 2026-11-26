import type { InjectionKey, Ref } from "vue";
import type { BatchAsset } from "./usePhotoBatchActions.ts";
import type { SmartMemoryItem } from "./usePhotoMemories.ts";

export type FolderCoverLoadState = "idle" | "loading" | "done" | "empty" | "error";

export interface PhotoStageExtensionContext {
  mediaPath: (path: string) => string;
  folderCovers: Ref<Record<string, number>>;
  folderCoverStatus: Ref<Record<string, FolderCoverLoadState>>;
  requestFolderCover: (albumPath: string) => void;
  openSmartMemory: (memory: SmartMemoryItem) => void;
  downloadAsset: (asset: BatchAsset) => void;
  toggleZoomAtPointer: (event?: MouseEvent | PointerEvent) => void;
}

export const PHOTO_STAGE_EXT_CTX: InjectionKey<PhotoStageExtensionContext> = Symbol(
  "lightisle-photo-stage-ext",
);
