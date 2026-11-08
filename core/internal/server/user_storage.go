package server

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path"
	"strconv"
	"strings"

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

func (a *API) abandonRemovedStorageRoot(w http.ResponseWriter, r *http.Request) {
	if a.rootServer == nil || a.rootServer.registry == nil {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "storage_registry_unavailable"})
		return
	}
	userID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	rootID := r.PathValue("rootID")
	if err != nil || userID <= 0 || rootID == "" {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "storage_invalid_request"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	defer r.Body.Close()
	var request struct {
		Generation uint64 `json:"generation"`
		Confirm    bool   `json:"confirm"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	var extra any
	if decoder.Decode(&request) != nil || decoder.Decode(&extra) != io.EOF || !request.Confirm || request.Generation == 0 {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "storage_reset_confirmation_required"})
		return
	}
	for _, root := range a.rootServer.registry.List() {
		if root.ID == rootID {
			jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_remove_root_first"})
			return
		}
	}
	if err := a.auth.AbandonUserStorageRoot(token(r), userID, rootID, request.Generation); err != nil {
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
	case errors.Is(err, auth.ErrStorageUnassigned):
		jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_destination_not_assigned"})
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
	// Old app versions must not turn a removed global quota back on.
	jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_quota_is_per_disk_upgrade_client"})
}

func (a *API) setUserStorageRootQuota(w http.ResponseWriter, r *http.Request) {
	id, ok := storageUserID(w, r)
	if !ok {
		return
	}
	rootID := r.PathValue("rootID")
	r.Body = http.MaxBytesReader(w, r.Body, 256)
	defer r.Body.Close()
	var payload struct {
		QuotaBytes *int64  `json:"quotaBytes"`
		Generation *uint64 `json:"generation"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	var extra any
	if decoder.Decode(&payload) != nil || payload.QuotaBytes == nil || payload.Generation == nil || decoder.Decode(&extra) != io.EOF {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	if err := a.auth.SetUserStorageRootQuota(token(r), id, rootID, *payload.Generation, *payload.QuotaBytes); err != nil {
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
	var payload struct {
		QuotaBytes *int64 `json:"quotaBytes"`
	}
	if r.Body != nil {
		r.Body = http.MaxBytesReader(w, r.Body, 1024)
		defer r.Body.Close()
		decoder := json.NewDecoder(r.Body)
		decoder.DisallowUnknownFields()
		var extra any
		if err := decoder.Decode(&payload); err != nil && !errors.Is(err, io.EOF) {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "storage_invalid_request"})
			return
		} else if err == nil && decoder.Decode(&extra) != io.EOF {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "storage_invalid_request"})
			return
		}
	}
	policy, err := a.auth.StoragePolicy(token(r), userID)
	if err != nil {
		storagePolicyError(w, err)
		return
	}
	if !a.ensureUserCategoryFolders(w, userID, policy, []string{category}) {
		return
	}
	if !a.rootLease.Valid(r.Context()) {
		jsonReply(w, http.StatusConflict, map[string]string{"error": "root_generation_changed"})
		return
	}
	location, err := a.auth.AssignUserStorageWithQuota(token(r), userID, category,
		a.rootID, a.rootRuntime.root.Generation, payload.QuotaBytes)
	if err != nil {
		storagePolicyError(w, err)
		return
	}
	updatedPolicy, err := a.auth.StoragePolicy(token(r), userID)
	if err != nil {
		storagePolicyError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"location": location, "policy": updatedPolicy, "enforcement": "pending"})
}

// allocateUserStorageSpace configures a member's space and quota on a verified
// physical root and optionally initializes one or more category directories
// and custom subdirectories in the same workflow.
func (a *API) allocateUserStorageSpace(w http.ResponseWriter, r *http.Request) {
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
	var payload struct {
		QuotaBytes     *int64   `json:"quotaBytes"`
		Categories     []string `json:"categories"`
		Subdirectories []string `json:"subdirectories"`
	}
	if r.Body != nil {
		r.Body = http.MaxBytesReader(w, r.Body, 4096)
		defer r.Body.Close()
		decoder := json.NewDecoder(r.Body)
		decoder.DisallowUnknownFields()
		var extra any
		if err := decoder.Decode(&payload); err != nil && !errors.Is(err, io.EOF) {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "storage_invalid_request"})
			return
		} else if err == nil && decoder.Decode(&extra) != io.EOF {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "storage_invalid_request"})
			return
		}
	}
	for _, category := range payload.Categories {
		if category != auth.StorageFiles && category != auth.StoragePhotos && category != auth.StorageVideos {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "storage_invalid_request"})
			return
		}
	}
	policy, err := a.auth.StoragePolicy(token(r), userID)
	if err != nil {
		storagePolicyError(w, err)
		return
	}
	subdirs, ok := resolvePersonalSubdirectories(userID, policy, a.rootID, a.rootRuntime.root.Generation, payload.Categories, payload.Subdirectories)
	if !ok {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "storage_invalid_request"})
		return
	}
	if !a.ensureUserCategoryFolders(w, userID, policy, payload.Categories) {
		return
	}
	if !a.rootLease.Valid(r.Context()) {
		jsonReply(w, http.StatusConflict, map[string]string{"error": "root_generation_changed"})
		return
	}
	if _, err := a.auth.AllocateUserStorageRoot(token(r), userID,
		a.rootID, a.rootRuntime.root.Generation, payload.QuotaBytes, payload.Categories); err != nil {
		storagePolicyError(w, err)
		return
	}
	for _, relative := range subdirs {
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
	updated, err := a.auth.StoragePolicy(token(r), userID)
	if err != nil {
		storagePolicyError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, updated)
}

func (a *API) ensureUserCategoryFolders(w http.ResponseWriter, userID int64, policy auth.StoragePolicy, categories []string) bool {
	base := "Users/u" + strconv.FormatInt(userID, 10)
	dirs := []string{"Users", base}
	seen := make(map[string]bool, len(categories))
	var uniqueCategories []string
	for _, category := range categories {
		if !seen[category] {
			seen[category] = true
			uniqueCategories = append(uniqueCategories, category)
			dirs = append(dirs, base+"/"+category)
		}
	}
	for _, relative := range dirs {
		if err := a.files.Mkdir(relative); err != nil {
			if !errors.Is(err, os.ErrExist) {
				fileError(w, err)
				return false
			}
			info, statErr := a.files.Stat(relative)
			if statErr != nil || !info.IsDir() {
				jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_folder_conflict"})
				return false
			}
		}
	}
	for _, category := range uniqueCategories {
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
				return false
			}
			if len(page) != 0 {
				jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_folder_not_empty"})
				return false
			}
		}
	}
	return true
}

func resolvePersonalSubdirectories(userID int64, policy auth.StoragePolicy, rootID string, generation uint64, requestedCategories, rawSubdirs []string) ([]string, bool) {
	if len(rawSubdirs) == 0 {
		return nil, true
	}
	if len(rawSubdirs) > 20 {
		return nil, false
	}
	activeCategories := make(map[string]bool, 3)
	var defaultCategory string
	for _, loc := range policy.Locations {
		if loc.RootID == rootID && loc.RootGeneration == generation {
			activeCategories[loc.Category] = true
			if defaultCategory == "" {
				defaultCategory = loc.Category
			}
		}
	}
	for _, c := range requestedCategories {
		activeCategories[c] = true
		if defaultCategory == "" || c == auth.StorageFiles {
			defaultCategory = c
		}
	}
	base := "Users/u" + strconv.FormatInt(userID, 10)
	out := make([]string, 0, len(rawSubdirs))
	for _, raw := range rawSubdirs {
		trimmed := strings.TrimSpace(raw)
		if trimmed == "" || strings.HasPrefix(trimmed, "/") || path.Clean(trimmed) != trimmed {
			return nil, false
		}
		parts := strings.Split(trimmed, "/")
		category := defaultCategory
		subParts := parts
		if parts[0] == auth.StorageFiles || parts[0] == auth.StoragePhotos || parts[0] == auth.StorageVideos {
			if len(parts) < 2 {
				return nil, false
			}
			category = parts[0]
			subParts = parts[1:]
		}
		if category == "" || !activeCategories[category] {
			return nil, false
		}
		cur := base + "/" + category
		for _, segment := range subParts {
			if segment == "" || segment == "." || segment == ".." || strings.HasPrefix(segment, ".") || len(segment) > 120 {
				return nil, false
			}
			cur += "/" + segment
			out = append(out, cur)
		}
	}
	return out, true
}
