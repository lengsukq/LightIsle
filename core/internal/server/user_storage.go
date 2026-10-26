package server

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strconv"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

func storageUserID(w http.ResponseWriter, r *http.Request) (int64, bool) {
	userID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || userID <= 0 {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_user"})
		return 0, false
	}
	return userID, true
}

// Home NAS recovery is intentionally manual: the owner removes an unusable
// physical root in Mac settings, then explicitly abandons the corresponding
// category binding to create a fresh empty space. An offline-but-still-
// registered disk must NOT be treated as lost automatically.
func (a *API) abandonRemovedStorageCategory(w http.ResponseWriter, r *http.Request) {
	if a.rootServer == nil || a.rootServer.registry == nil {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "storage_registry_unavailable"})
		return
	}
	userID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	category := r.PathValue("category")
	if err != nil || userID <= 0 || (category != auth.StorageFiles && category != auth.StoragePhotos && category != auth.StorageVideos) {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_storage_category"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	defer r.Body.Close()
	var request struct {
		RootID     string `json:"rootID"`
		Generation uint64 `json:"generation"`
		Confirm    bool   `json:"confirm"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	var extra any
	if decoder.Decode(&request) != nil || decoder.Decode(&extra) != io.EOF || !request.Confirm {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "storage_reset_confirmation_required"})
		return
	}
	for _, root := range a.rootServer.registry.List() {
		if root.ID == request.RootID {
			jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_remove_root_first"})
			return
		}
	}
	if err := a.auth.AbandonUserStorageLocation(token(r), userID, category, request.RootID, request.Generation); err != nil {
		storagePolicyError(w, err)
		return
	}
	policy, err := a.auth.StoragePolicy(token(r), userID)
	if err != nil {
		storagePolicyError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, policy)
}

// Expose uncertain reservations without ever guessing that an offline disk
// is empty. This is inventory only: administrators cannot blindly release
// reservations from this endpoint.
func (a *API) userStoragePendingReservations(w http.ResponseWriter, r *http.Request) {
	id, ok := storageUserID(w, r)
	if !ok {
		return
	}
	limit := 50
	if raw := r.URL.Query().Get("limit"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 1 || parsed > 100 {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_page_size"})
			return
		}
		limit = parsed
	}
	reservations, next, err := a.auth.StoragePendingReservations(token(r), id, r.URL.Query().Get("after"), limit)
	if err != nil {
		storagePolicyError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"reservations": reservations, "nextCursor": next, "verification": "required"})
}

func storagePolicyError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, auth.ErrForbidden):
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "storage_permission_denied"})
	case errors.Is(err, auth.ErrInput):
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "storage_invalid_request"})
	case errors.Is(err, auth.ErrNotFound):
		jsonReply(w, http.StatusNotFound, map[string]string{"error": "user_not_found"})
	case errors.Is(err, auth.ErrStorageReassignmentRequiresMigration):
		jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_migration_required"})
	default:
		jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "storage_settings_unavailable"})
	}
}

// This endpoint deliberately reports "enforcement":"pending": writing the
// desired limit to SQLite does not pretend the backend yet enforces it.
func (a *API) userStoragePolicy(w http.ResponseWriter, r *http.Request) {
	id, ok := storageUserID(w, r)
	if !ok {
		return
	}
	policy, err := a.auth.StoragePolicy(token(r), id)
	if err != nil {
		storagePolicyError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, policy)
}

func (a *API) ownStoragePolicy(w http.ResponseWriter, r *http.Request) {
	user, ok := a.auth.Identity(token(r))
	if !ok {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return
	}
	policy, err := a.auth.StoragePolicy(token(r), user.ID)
	if err != nil {
		storagePolicyError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, policy)
}

func (a *API) setUserStorageQuota(w http.ResponseWriter, r *http.Request) {
	id, ok := storageUserID(w, r)
	if !ok {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 256)
	defer r.Body.Close()
	var payload struct {
		QuotaBytes *int64 `json:"quotaBytes"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	var extra any
	if decoder.Decode(&payload) != nil || payload.QuotaBytes == nil || decoder.Decode(&extra) != io.EOF {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	if err := a.auth.SetUserStorageQuota(token(r), id, *payload.QuotaBytes); err != nil {
		storagePolicyError(w, err)
		return
	}
	policy, err := a.auth.StoragePolicy(token(r), id)
	if err != nil {
		storagePolicyError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, policy)
}

// Assign a future private directory on a verified, generation-pinned root.
// The storage model is not yet mounted in legacy API writes or client routes.
// Neither disk contents nor member ACLs are modified by this request.
func (a *API) assignUserStorageRoot(w http.ResponseWriter, r *http.Request) {
	if a.rootLease == nil || a.rootRuntime == nil ||
		!a.rootLease.Valid(r.Context()) || a.rootID == "" {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "root_unavailable"})
		return
	}
	userID, err := strconv.ParseInt(r.PathValue("userID"), 10, 64)
	if err != nil || userID <= 0 {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_user"})
		return
	}
	category := r.PathValue("category")
	if category != auth.StorageFiles && category != auth.StoragePhotos && category != auth.StorageVideos {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "storage_invalid_request"})
		return
	}
	policy, err := a.auth.StoragePolicy(token(r), userID)
	if err != nil {
		storagePolicyError(w, err)
		return
	}
	// Only create directories through the already pinned, root-scoped files
	// manager. Existing objects are checked with Store.Stat, which rejects
	// symlinks/special files. No absolute user-controlled paths are accepted.
	base := "Users/u" + strconv.FormatInt(userID, 10)
	for _, relative := range []string{"Users", base, base + "/" + category} {
		if err := a.files.Mkdir(relative); err != nil {
			if !errors.Is(err, os.ErrExist) {
				fileError(w, err)
				return
			}
			info, statErr := a.files.Stat(relative)
			if statErr != nil || !info.IsDir() {
				jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_folder_conflict"})
				return
			}
		}
	}
	// Rebuilding a home is an explicit NEW empty space, not an implicit
	// adoption of old disk contents. Re-registering a former physical folder
	// with a new root ID must not make unaccounted prior bytes available.
	// Identical existing assignments remain idempotent after normal uploads.
	alreadyAssigned := false
	for _, location := range policy.Locations {
		if location.Category == category && location.RootID == a.rootID && location.RootGeneration == a.rootRuntime.root.Generation {
			alreadyAssigned = true
			break
		}
	}
	if !alreadyAssigned {
		page, _, err := a.files.Page(base+"/"+category, "", 1)
		if err != nil {
			fileError(w, err)
			return
		}
		if len(page) != 0 {
			jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_folder_not_empty"})
			return
		}
	}
	if !a.rootLease.Valid(r.Context()) {
		jsonReply(w, http.StatusConflict, map[string]string{"error": "root_generation_changed"})
		return
	}
	location, err := a.auth.AssignUserStorage(token(r), userID, category,
		a.rootID, a.rootRuntime.root.Generation)
	if err != nil {
		storagePolicyError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"location": location, "enforcement": "pending"})
}
