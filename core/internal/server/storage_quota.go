package server

import (
	"errors"
	"net/http"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

// Quota protection is only active for generation-bound personal subtrees.
// Unscoped v2 and unassigned paths remain explicitly pending until every writer
// (WebDAV, downloads, copies, and background media imports) is integrated.
func (a *API) reserveUploadQuota(r *http.Request, path string, size int64) (string, bool, error) {
	if a.rootID == "" || a.auth == nil {
		return "", false, nil
	}
	if a.rootLease == nil || a.rootRuntime == nil || !a.rootLease.Valid(r.Context()) {
		return "", false, auth.ErrStorageUnassigned
	}
	return a.auth.ReserveStorageUpload(token(r), a.rootID, a.rootRuntime.root.Generation, path, size)
}

func storageQuotaError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, auth.ErrStorageQuotaExceeded):
		jsonReply(w, http.StatusInsufficientStorage, map[string]string{"error": "storage_quota_exceeded"})
	case errors.Is(err, auth.ErrStorageUnassigned):
		jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_destination_not_assigned"})
	case errors.Is(err, auth.ErrStorageLedgerConflict):
		jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_accounting_conflict"})
	case errors.Is(err, auth.ErrStorageReservationMissing):
		jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_reservation_missing"})
	case errors.Is(err, auth.ErrForbidden):
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "storage_permission_denied"})
	case errors.Is(err, auth.ErrInput):
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_storage_size"})
	default:
		jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "storage_accounting_unavailable"})
	}
}

func managedStorageName(name string) bool {
	// The common macOS APFS format is case-insensitive. Treat the reserved
	// namespace as private even when a client uses users/ or USERS/.
	return strings.EqualFold(name, "Users") ||
		(len(name) > len("Users/") && name[5] == '/' && strings.EqualFold(name[:5], "Users"))
}
