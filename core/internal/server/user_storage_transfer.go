package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strconv"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
)

var (
	errStorageFolderConflict    = errors.New("storage_folder_conflict")
	errMigrationVerifyFailed    = errors.New("storage_migration_verification_failed")
	errStorageRootGenChanged    = errors.New("root_generation_changed")
	errStorageSwitchInvalidMode = errors.New("storage_invalid_switch_mode")
	errStorageSwitchTaskMissing = errors.New("storage_switch_task_not_found")
)

// SwitchUserStorageRequest starts a task or addresses a previously issued task.
type SwitchUserStorageRequest struct {
	TaskID           string   `json:"taskID,omitempty"`
	Categories       []string `json:"categories"`
	SourceRootID     string   `json:"sourceRootID"`
	SourceGeneration uint64   `json:"sourceGeneration"`
	TargetRootID     string   `json:"targetRootID"`
	TargetGeneration uint64   `json:"targetGeneration"`
	TargetQuotaBytes *int64   `json:"targetQuotaBytes,omitempty"`
	Mode             string   `json:"mode"`
	Phase            string   `json:"phase,omitempty"`
}

// SwitchUserStorageResponse reports the outcome of a cross-root copy or migration phase.
type SwitchUserStorageResponse struct {
	TaskID             string             `json:"taskID"`
	Error              string             `json:"error,omitempty"`
	TrashIDs           map[string]string  `json:"trashIDs,omitempty"`
	AffectedShares     int                `json:"affectedShares"`
	Mode               string             `json:"mode"`
	Phase              string             `json:"phase"`
	CopiedFiles        int                `json:"copiedFiles"`
	CopiedBytes        int64              `json:"copiedBytes"`
	VerifiedFiles      int                `json:"verifiedFiles"`
	DeletedSourceFiles int                `json:"deletedSourceFiles"`
	ReadyToCleanup     bool               `json:"readyToCleanup"`
	Policy             auth.StoragePolicy `json:"policy"`
}

func (a *API) switchUserStorageRoot(w http.ResponseWriter, r *http.Request) {
	if a.rootServer == nil || a.rootServer.registry == nil {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "storage_registry_unavailable"})
		return
	}
	userID, ok := storageUserID(w, r)
	if !ok {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	defer r.Body.Close()
	var req SwitchUserStorageRequest
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	var extra any
	if err := decoder.Decode(&req); err != nil || decoder.Decode(&extra) != io.EOF {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "storage_invalid_request"})
		return
	}
	resp, err := a.rootServer.ExecuteSwitchUserStorage(r.Context(), token(r), false, userID, req)
	if err != nil {
		writeSwitchStorageError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, resp)
}

func writeSwitchStorageError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, errStorageSwitchInvalidMode), errors.Is(err, auth.ErrInput):
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "storage_invalid_request"})
	case errors.Is(err, auth.ErrForbidden):
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "storage_permission_denied"})
	case errors.Is(err, errStorageSwitchTaskMissing):
		jsonReply(w, http.StatusNotFound, map[string]string{"error": errStorageSwitchTaskMissing.Error()})
	case errors.Is(err, auth.ErrNotFound):
		jsonReply(w, http.StatusNotFound, map[string]string{"error": "user_not_found"})
	case errors.Is(err, roots.ErrMissing):
		jsonReply(w, http.StatusNotFound, map[string]string{"error": "root_not_found"})
	case errors.Is(err, roots.ErrOffline), errors.Is(err, roots.ErrStale):
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "root_unavailable"})
	case errors.Is(err, errStorageRootGenChanged):
		jsonReply(w, http.StatusConflict, map[string]string{"error": "root_generation_changed"})
	case errors.Is(err, files.ErrRootBusy):
		jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_switch_busy"})
	case errors.Is(err, errStorageFolderConflict):
		jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_folder_conflict"})
	case errors.Is(err, errMigrationVerifyFailed):
		jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_migration_verification_failed"})
	case errors.Is(err, auth.ErrStorageQuotaExceeded):
		jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_quota_exceeded"})
	case errors.Is(err, auth.ErrStorageLedgerConflict):
		jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_accounting_conflict"})
	case errors.Is(err, auth.ErrStorageReassignmentRequiresMigration):
		jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_migration_required"})
	default:
		jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "storage_settings_unavailable"})
	}
}

// ExecuteAllocateUserStorage provisions category folders and optional custom
// subdirectories on a target root and records the user's storage allocation.
func (s *RootServer) ExecuteAllocateUserStorage(
	ctx context.Context,
	actorSession string,
	nativeOwner bool,
	userID int64,
	rootID string,
	generation uint64,
	quotaBytes *int64,
	categories []string,
	subdirectories []string,
) (auth.StoragePolicy, error) {
	if s == nil || s.accounts == nil || s.registry == nil {
		return auth.StoragePolicy{}, errors.New("root_services_unavailable")
	}
	var policy auth.StoragePolicy
	var err error
	if nativeOwner {
		policy, err = s.accounts.NativeStoragePolicy(userID)
	} else {
		policy, err = s.accounts.StoragePolicy(actorSession, userID)
	}
	if err != nil {
		return auth.StoragePolicy{}, err
	}
	subdirs, ok := resolvePersonalSubdirectories(userID, policy, rootID, generation, categories, subdirectories)
	if !ok {
		return auth.StoragePolicy{}, auth.ErrInput
	}
	lease, err := s.AcquireRootServices(ctx, rootID)
	if err != nil {
		return auth.StoragePolicy{}, err
	}
	defer lease.Close()
	if lease.Root.Generation != generation || !lease.Lease.Valid(ctx) {
		return auth.StoragePolicy{}, errStorageRootGenChanged
	}
	if err := ensureCategoryFoldersOnStore(lease.Services.Files, userID, policy, rootID, generation, categories); err != nil {
		return auth.StoragePolicy{}, err
	}
	if !lease.Lease.Valid(ctx) {
		return auth.StoragePolicy{}, errStorageRootGenChanged
	}
	if nativeOwner {
		_, err = s.accounts.NativeAllocateUserStorageRoot(userID, rootID, generation, quotaBytes, categories)
	} else {
		_, err = s.accounts.AllocateUserStorageRoot(actorSession, userID, rootID, generation, quotaBytes, categories)
	}
	if err != nil {
		return auth.StoragePolicy{}, err
	}
	for _, relative := range subdirs {
		if err := ensureDirectoryExists(lease.Services.Files, relative); err != nil {
			return auth.StoragePolicy{}, err
		}
	}
	if nativeOwner {
		return s.accounts.NativeStoragePolicy(userID)
	}
	return s.accounts.StoragePolicy(actorSession, userID)
}

func (s *RootServer) fetchStoragePolicy(actorSession string, nativeOwner bool, userID int64) (auth.StoragePolicy, error) {
	if nativeOwner {
		return s.accounts.NativeStoragePolicy(userID)
	}
	return s.accounts.StoragePolicy(actorSession, userID)
}

func (s *RootServer) queueMediaRefreshForCategories(rootID, base string, categories []string) {
	for _, cat := range categories {
		if cat == auth.StoragePhotos || cat == auth.StorageVideos {
			s.QueueMediaRefresh(rootID, base+"/"+cat)
		}
	}
}

func ensureDirectoryExists(store files.Access, relative string) error {
	if err := store.Mkdir(relative); err != nil {
		if !errors.Is(err, os.ErrExist) && !errors.Is(err, files.ErrExists) {
			return err
		}
		info, statErr := store.Stat(relative)
		if statErr != nil || !info.IsDir() {
			return errStorageFolderConflict
		}
	}
	return nil
}

func ensureCategoryFoldersOnStore(store files.Access, userID int64, policy auth.StoragePolicy, rootID string, generation uint64, categories []string) error {
	base := "Users/u" + strconv.FormatInt(userID, 10)
	dirs := []string{"Users", base}
	seen := make(map[string]bool, len(categories))
	unique := make([]string, 0, len(categories))
	for _, c := range categories {
		if !seen[c] {
			seen[c] = true
			unique = append(unique, c)
			dirs = append(dirs, base+"/"+c)
		}
	}
	for _, dir := range dirs {
		if err := ensureDirectoryExists(store, dir); err != nil {
			return err
		}
	}
	for _, category := range unique {
		alreadyAssigned := false
		for _, loc := range policy.Locations {
			if loc.Category == category && loc.RootID == rootID && loc.RootGeneration == generation {
				alreadyAssigned = true
				break
			}
		}
		if !alreadyAssigned {
			page, _, err := store.Page(base+"/"+category, "", 1)
			if err != nil {
				return err
			}
			if len(page) != 0 {
				return errStorageFolderConflict
			}
		}
	}
	return nil
}
