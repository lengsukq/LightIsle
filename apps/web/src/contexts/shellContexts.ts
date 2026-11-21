import type { ComputedRef, InjectionKey, Ref } from "vue";
import type { ManagedAccount } from "../features/settings/useAccountManagement.ts";
import type { LoginSession } from "../features/auth/useAccountSessions.ts";
import type { SharedFileEntry, FileShare } from "../features/files/useFileShares.ts";
import type { FileGrant } from "../features/files/useFileActionsAndGrants.ts";
import type { FileTrashEntry } from "../features/files/useFileTrash.ts";
import type { UploadContinuation } from "../features/files/filePageState.ts";
import type { BackendTask, TaskRun } from "../features/settings/useTaskCenter.ts";
import type { FileSearchKind, FileSearchScope } from "../features/files/fileSearchUtils.ts";
import type { ShellPage, ShellSettingsGroup } from "../utils/shellRouteGuard.ts";
import type { Movie } from "../features/cinema/cinemaTypes.ts";

export type FileViewMode = "list" | "grid";

export interface AuthenticatedUser {
  username: string;
  role: "admin" | "member";
}

export interface SharedRootSummary {
  rootID: string;
  name: string;
  generation: number;
  online: boolean;
  isDefault?: boolean;
}

/**
 * Explicit late-binding bridge that breaks mutual-recursion closures between
 * root-context, auth/session, files, uploads, shares, and task composables in App.vue.
 */
export interface ShellLifecycleBridge {
  isFileDirectoryLoaded: () => boolean;
  isUploadBusy: () => boolean;
  hasActiveUpload: () => boolean;
  cancelAndWaitForUpload: () => Promise<void>;
  resetRootScopedFeatures: () => void;
  loadFiles: (path?: string) => Promise<unknown>;
  refreshTaskCenter: () => Promise<void>;
  loadMyShares: () => Promise<void>;
  clearClientSessionState: (expiredMessage?: string) => void;
  logout: () => Promise<void>;
  openMatchedCinemaFilm: (film: Movie) => void;
  onDirectoryLeave: () => void;
  onExtracted: (name: string) => void;
  isShowingTrash: () => boolean;
}

export function createShellLifecycleBridge(): ShellLifecycleBridge {
  return {
    isFileDirectoryLoaded: () => false,
    isUploadBusy: () => false,
    hasActiveUpload: () => false,
    cancelAndWaitForUpload: async () => {},
    resetRootScopedFeatures: () => {},
    loadFiles: async () => {},
    refreshTaskCenter: async () => {},
    loadMyShares: async () => {},
    clearClientSessionState: () => {},
    logout: async () => {},
    openMatchedCinemaFilm: () => {},
    onDirectoryLeave: () => {},
    onExtracted: () => {},
    isShowingTrash: () => false,
  };
}

export interface FilesViewContext {
  active: Ref<ShellPage>;
  user: Ref<AuthenticatedUser | null>;
  filesPath: Ref<string>;
  currentFolderCanWrite: Ref<boolean>;
  fileDirectoryLoaded: Ref<boolean>;
  sharedRootName: Ref<string>;
  fileEntries: Ref<SharedFileEntry[]>;
  fileNextCursor: Ref<string>;
  fileSortKey: Ref<"name" | "mtime" | "size">;
  fileSortDirection: Ref<"asc" | "desc">;
  failedThumbnails: Ref<Set<string>>;
  fileSearch: Ref<string>;
  lastExecutedQuery: Ref<string>;
  fileSearchKind: Ref<FileSearchKind>;
  fileSearchScope: Ref<FileSearchScope>;
  searchFolderBase: Ref<string>;
  searchViaSpotlight: Ref<boolean>;
  searchingFiles: Ref<boolean>;
  searchTruncated: Ref<boolean>;
  recentSearches: Ref<string[]>;
  revealedFilePath: Ref<string>;
  revealingFilePath: Ref<string>;
  checkedFiles: Ref<string[]>;
  filesLoading: Ref<boolean>;
  extracting: Ref<boolean>;
  filesError: Ref<string>;
  fileViewMode: Ref<FileViewMode>;
  createFolderOpen: Ref<boolean>;
  newFolderName: Ref<string>;
  fileActionBusy: Ref<boolean>;
  fileOperationNotice: Ref<string>;
  trashTarget: Ref<SharedFileEntry | null>;
  showDuplicatesModal: Ref<boolean>;
  selectedFilesAllWritable: ComputedRef<boolean>;
  selectedPathsFallback: Ref<string>;
  pathSegments: ComputedRef<Array<{ name: string; path: string }>>;
  showingTrash: Ref<boolean>;
  trashItems: Ref<FileTrashEntry[]>;
  trashRetention: Ref<{ enabled: boolean; days: number } | null>;
  trashRetentionError: Ref<string>;
  trashLoading: Ref<boolean>;
  trashBusy: Ref<boolean>;
  trashError: Ref<string>;
  trashNotice: Ref<string>;
  selectedUpload: Ref<HTMLInputElement | null>;
  uploadPercent: Ref<number>;
  uploadStage: Ref<"idle" | "hashing" | "uploading" | "done" | "error" | "cancelled">;
  uploadCurrent: Ref<number>;
  uploadTotal: Ref<number>;
  uploadFileName: Ref<string>;
  uploadSize: Ref<number>;
  uploadTransferred: Ref<number>;
  uploadDropActive: Ref<boolean>;
  uploadAutoRenameConflicts: Ref<boolean>;
  uploadCompleted: Ref<number>;
  uploadResult: Ref<string>;
  uploadFailure: Ref<string>;
  uploadBusy: Ref<boolean>;
  uploadContinuation: Ref<UploadContinuation | null>;
  canContinueUploads: ComputedRef<boolean>;
  bytes: (n: number) => string;
  setFileViewMode: (mode: FileViewMode) => void;
  loadFiles: (path?: string, append?: boolean) => Promise<unknown>;
  runFileSearch: () => Promise<unknown> | void;
  selectSearchKind: (kind: FileSearchKind) => void;
  setSearchScope: (scope: FileSearchScope) => void;
  applyRecentSearch: (q: string) => void;
  deleteRecentSearch: (q: string) => void;
  clearRecentSearches: () => void;
  clearFileSearch: () => Promise<unknown> | void;
  revealEntryFolder: (entry: SharedFileEntry) => Promise<string | null>;
  extractZip: (entry: SharedFileEntry) => Promise<unknown> | void;
  loadTrash: () => Promise<unknown> | void;
  openTrash: () => Promise<unknown> | void;
  restoreTrash: (entry: FileTrashEntry) => Promise<unknown> | void;
  purgeTrashItem: (entry: FileTrashEntry) => Promise<unknown> | void;
  chooseUploadFiles: () => void;
  startUpload: (event: Event) => Promise<unknown> | void;
  dragOverUpload: (event: DragEvent) => void;
  dragLeaveUpload: (event: DragEvent) => void;
  dropUpload: (event: DragEvent) => Promise<unknown> | void;
  cancelCurrentUpload: () => Promise<unknown> | void;
  continueIncompleteUploads: () => Promise<unknown> | void;
  closeUploadActivity: () => void;
  thumbnailKey: (entry: SharedFileEntry) => string;
  thumbnailEligible: (entry: SharedFileEntry) => boolean;
  fileThumbnailURL: (entry: SharedFileEntry) => string;
  closeFileMenu: (event: Event) => void;
  markThumbnailFailure: (entry: SharedFileEntry) => void;
  canWriteEntry: (entry: SharedFileEntry) => boolean;
  operateFile: (entry: SharedFileEntry, action: "rename" | "copy" | "move") => void;
  operateBatchMove: () => void;
  previewFile: (entry: SharedFileEntry) => Promise<void>;
  goUp: () => void;
  makeFolder: () => Promise<boolean>;
  batchTrash: () => Promise<void>;
  downloadFile: (entry: SharedFileEntry) => void;
  batchDownloadSelected: () => Promise<void>;
  selectFallbackPaths: (event: FocusEvent) => void;
  copySelectedPaths: () => Promise<void>;
  openShareDialog: (entry: SharedFileEntry) => void;
  jumpToSettingsGroup: (group: ShellSettingsGroup) => void;
}

export interface SettingsViewContext {
  active: Ref<ShellPage>;
  settingsGroup: Ref<ShellSettingsGroup>;
  user: Ref<AuthenticatedUser | null>;
  sharedRoots: Ref<SharedRootSummary[]>;
  selectedRootID: Ref<string>;
  selectedRoot: ComputedRef<SharedRootSummary | null>;
  selectedRootGeneration: ComputedRef<number>;
  multiRootMode: ComputedRef<boolean>;
  rootViewKey: ComputedRef<string>;
  rootDiscoveryState: Ref<"unknown" | "multi" | "error">;
  rootDiscoveryError: Ref<string>;
  rootFeatureContextReady: ComputedRef<boolean>;
  accounts: Ref<ManagedAccount[]>;
  userError: Ref<string>;
  currentPassword: Ref<string>;
  nextPassword: Ref<string>;
  repeatPassword: Ref<string>;
  passwordBusy: Ref<boolean>;
  passwordError: Ref<string>;
  newUsername: Ref<string>;
  newPassword: Ref<string>;
  creatingUser: Ref<boolean>;
  createUserError: Ref<string>;
  createUserNotice: Ref<string>;
  lastCreatedMember: Ref<{ id: number; username: string } | null>;
  clearLastCreatedMember: () => void;
  memberActionBusy: Ref<boolean>;
  memberActionError: Ref<string>;
  memberActionNotice: Ref<string>;
  resetTargetUser: Ref<ManagedAccount | null>;
  resetMemberNewPassword: Ref<string>;
  resetMemberRepeatPassword: Ref<string>;
  resetMemberBusy: Ref<boolean>;
  resetMemberError: Ref<string>;
  loadAccounts: () => Promise<void>;
  createMemberAccount: () => Promise<void>;
  toggleMemberEnabled: (account: ManagedAccount) => Promise<void>;
  openResetMemberPassword: (account: ManagedAccount) => void;
  closeResetMemberPassword: () => void;
  submitResetMemberPassword: () => Promise<void>;
  changeOwnPassword: () => Promise<void>;
  grantUser: Ref<ManagedAccount | null>;
  grants: Ref<FileGrant[]>;
  grantError: Ref<string>;
  grantNotice: Ref<string>;
  grantPathInput: Ref<string>;
  grantCanWrite: Ref<boolean>;
  grantBusy: Ref<boolean>;
  editGrants: (account: ManagedAccount) => Promise<void>;
  saveGrant: () => Promise<void>;
  toggleGrantWrite: (grant: FileGrant) => Promise<void>;
  removeGrant: (path: string) => Promise<void>;
  loginSessions: Ref<LoginSession[]>;
  sessionsLoading: Ref<boolean>;
  sessionsLoaded: Ref<boolean>;
  sessionsTruncated: Ref<boolean>;
  sessionsError: Ref<string>;
  sessionsMessage: Ref<string>;
  loadLoginSessions: () => Promise<void>;
  revokeLoginSession: (target: LoginSession | "others") => Promise<void>;
  activeShares: Ref<FileShare[]>;
  sharesLoading: Ref<boolean>;
  sharesError: Ref<string>;
  sharesLoaded: Ref<boolean>;
  loadMyShares: () => Promise<void>;
  revokeFileShare: (share: FileShare) => Promise<void>;
  tasks: Ref<BackendTask[]>;
  taskError: Ref<string>;
  taskHistory: Ref<TaskRun[]>;
  taskHistoryError: Ref<string>;
  taskHistoryLoading: Ref<boolean>;
  taskHistoryNextCursor: Ref<string>;
  refreshTaskCenter: () => Promise<void>;
  taskControl: (task: BackendTask, action: "cancel" | "retry") => Promise<void>;
  startMediaTask: (kind: "gallery" | "cinema") => void;
  reloadTaskHistory: (reset: boolean) => Promise<void>;
  advancedDiagnosticsOpen: Ref<boolean>;
  automationDisclosureOpen: Ref<boolean>;
  pendingMediaOpen: Ref<boolean>;
  adminPendingMediaOpen: Ref<boolean>;
  togglePendingMedia: (admin: boolean, event: Event) => void;
  toggleAdvanced: (kind: "diagnostics" | "automation", event: Event) => void;
  logout: () => Promise<void>;
}

export const FILES_VIEW_CTX: InjectionKey<FilesViewContext> = Symbol("lightisle-files-view");
export const SETTINGS_VIEW_CTX: InjectionKey<SettingsViewContext> = Symbol("lightisle-settings-view");
