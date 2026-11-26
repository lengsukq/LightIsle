<script setup lang="ts">
import { defineAsyncComponent, inject } from "vue";
import { FILE_EXTRAS_CTX } from "./fileExtrasContext.ts";
import type { SharedFileEntry } from "./useFileShares.ts";

const CollectLinkModal = defineAsyncComponent(() => import("./CollectLinkModal.vue"));
const FileInsightsModal = defineAsyncComponent(() => import("./FileInsightsModal.vue"));
const FileMarkdownEditorModal = defineAsyncComponent(() => import("./FileMarkdownEditorModal.vue"));
const FileOfficePreviewModal = defineAsyncComponent(() => import("./FileOfficePreviewModal.vue"));
const FileComicEpubReaderModal = defineAsyncComponent(() => import("./FileComicEpubReaderModal.vue"));

const props = defineProps<{
  filesPath: string;
  extracting: boolean;
  canWriteEntry: (entry: SharedFileEntry) => boolean;
  scopedApiPath: (path: string) => string;
  scopedMediaPath: (path: string) => string;
  rootFetch: (endpoint: string, init?: RequestInit) => Promise<Response>;
  jsonGet: <T>(endpoint: string) => Promise<T>;
  jsonWrite: <T>(endpoint: string, method: "PUT", body?: object) => Promise<T>;
  isAbortError: (error: unknown) => boolean;
}>();

const emit = defineEmits<{
  saved: [];
  download: [file: SharedFileEntry];
  extractZip: [file: SharedFileEntry];
}>();

const fileExtras = inject(FILE_EXTRAS_CTX);
</script>

<template>
  <template v-if="fileExtras">
    <CollectLinkModal
      v-if="fileExtras.collectModalOpen.value"
      :open="fileExtras.collectModalOpen.value"
      v-model:tab="fileExtras.collectModalTab.value"
      :folder="fileExtras.collectTargetFolder.value"
      :links="fileExtras.collectLinks.value"
      :links-loading="fileExtras.collectLinksLoading.value"
      :links-error="fileExtras.collectLinksError.value"
      :creating="fileExtras.collectCreating.value"
      :create-error="fileExtras.collectCreateError.value"
      :created-url="fileExtras.collectCreatedUrl.value"
      :created-link="fileExtras.collectCreatedLink.value"
      :copied-status="fileExtras.collectCopiedStatus.value"
      :revoking-id="fileExtras.collectRevokingId.value"
      @submit="fileExtras.createCollectLink($event)"
      @copy="fileExtras.copyCollectCreatedUrl($event)"
      @revoke="fileExtras.revokeCollectLink($event)"
      @refresh="fileExtras.loadCollectLinks(true)"
      @reset-created="fileExtras.clearCollectCreated()"
      @close="fileExtras.closeCollectModal()"
    />
    <FileInsightsModal
      v-if="fileExtras.insightsModalOpen.value"
      :open="fileExtras.insightsModalOpen.value"
      :mode="fileExtras.insightsMode.value"
      :scope-path="fileExtras.insightsScopePath.value"
      :current-folder-path="props.filesPath"
      :min-bytes="fileExtras.insightsMinBytes.value"
      :recent-days="fileExtras.insightsRecentDays.value"
      :result="fileExtras.insightsResult.value"
      :loading="fileExtras.insightsLoading.value"
      :error="fileExtras.insightsError.value"
      :trashing-path="fileExtras.insightsTrashingPath.value"
      @reload="fileExtras.loadInsights($event)"
      @open-folder="fileExtras.openInsightFolder($event)"
      @preview="fileExtras.previewInsightItem($event)"
      @trash="fileExtras.trashInsightItem($event)"
      @close="fileExtras.closeInsightsModal()"
    />
    <FileMarkdownEditorModal
      v-if="fileExtras.markdownEditorFile.value"
      :file="fileExtras.markdownEditorFile.value"
      :scoped-api-path="props.scopedApiPath"
      :root-fetch="props.rootFetch"
      :is-abort-error="props.isAbortError"
      @saved="emit('saved')"
      @download="emit('download', $event)"
      @close="fileExtras.markdownEditorFile.value = null"
    />
    <FileOfficePreviewModal
      v-if="fileExtras.officePreviewFile.value"
      :file="fileExtras.officePreviewFile.value"
      :can-write="Boolean(fileExtras.officePreviewFile.value && props.canWriteEntry(fileExtras.officePreviewFile.value))"
      :scoped-api-path="props.scopedApiPath"
      :root-fetch="props.rootFetch"
      :is-abort-error="props.isAbortError"
      @download="emit('download', $event)"
      @edit-as-text="fileExtras.openAsTextEditor($event)"
      @close="fileExtras.officePreviewFile.value = null"
    />
    <FileComicEpubReaderModal
      v-if="fileExtras.comicEpubFile.value"
      :file="fileExtras.comicEpubFile.value"
      :can-write="Boolean(fileExtras.comicEpubFile.value && props.canWriteEntry(fileExtras.comicEpubFile.value))"
      :extracting="props.extracting"
      :scoped-api-path="props.scopedApiPath"
      :scoped-media-path="props.scopedMediaPath"
      :root-fetch="props.rootFetch"
      :json-get="props.jsonGet"
      :json-write="props.jsonWrite"
      :is-abort-error="props.isAbortError"
      @download="emit('download', $event)"
      @extract-zip="emit('extractZip', $event)"
      @close="fileExtras.comicEpubFile.value = null"
    />
  </template>
</template>
