package server

import (
	"net/http"
	"strconv"
)

// CheckStorageLiveUsage is an explicit, read-only administrator action. It
// scans only currently mounted, generation-verified personal directories.
// It never overwrites the durable quota ledger: items in trash, uncertain
// upload reservations and concurrent writers require separate accounting.
func (a *API) checkStorageLiveUsage(w http.ResponseWriter, r *http.Request) {
	if a.files == nil || a.rootRuntime == nil || a.rootLease == nil ||
		!a.rootLease.Valid(r.Context()) {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "storage_root_unavailable"})
		return
	}
	userID, err := strconv.ParseInt(r.PathValue("userID"), 10, 64)
	if err != nil || userID <= 0 {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_user"})
		return
	}
	policy, err := a.auth.StoragePolicy(token(r), userID)
	if err != nil {
		storagePolicyError(w, err)
		return
	}
	var bytes int64
	var count int64
	const maxEntries = 100000
	categories := make(map[string]int64)
	for _, location := range policy.Locations {
		if location.RootID != a.rootID || location.RootGeneration != a.rootRuntime.root.Generation {
			continue
		}
		pending := []string{location.RelativePath}
		for len(pending) > 0 {
			if !a.rootLease.Valid(r.Context()) {
				jsonReply(w, http.StatusConflict, map[string]string{"error": "root_generation_changed"})
				return
			}
			if count >= maxEntries || len(pending) > maxEntries {
				jsonReply(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "storage_scan_too_many_files"})
				return
			}
			dir := pending[len(pending)-1]
			pending = pending[:len(pending)-1]
			cursor := ""
			for {
				rows, next, err := a.files.Page(dir, cursor, 200)
				if err != nil {
					jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_scan_incomplete"})
					return
				}
				for _, entry := range rows {
					count++
					if count > maxEntries {
						jsonReply(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "storage_scan_too_many_files"})
						return
					}
					switch entry.Type {
					case "folder":
						pending = append(pending, entry.Path)
					case "file":
						if entry.Size < 0 || bytes > 1<<60-entry.Size {
							jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_scan_invalid_file"})
							return
						}
						bytes += entry.Size
						categories[location.Category] += entry.Size
					default:
						jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_scan_special_file"})
						return
					}
				}
				if next == "" {
					break
				}
				if next == cursor {
					jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_scan_incomplete"})
					return
				}
				cursor = next
			}
		}
	}
	if !a.rootLease.Valid(r.Context()) || r.Context().Err() != nil {
		jsonReply(w, http.StatusConflict, map[string]string{"error": "root_generation_changed"})
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{
		"rootID": a.rootID, "rootGeneration": a.rootRuntime.root.Generation,
		"userId": userID, "liveBytes": bytes, "entriesChecked": count, "categories": categories,
		"scope": "online_live_files_only", "ledgerBytes": policy.AccountedBytes,
		"reservedBytes": policy.ReservedBytes, "note": "trash_and_pending_reservations_excluded",
	})
}
