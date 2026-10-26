package server

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

type adminUploadItem struct {
	ID            string `json:"id"`
	OwnerID       int64  `json:"ownerID"`
	OwnerName     string `json:"ownerName"`
	OwnerEnabled  bool   `json:"ownerEnabled"`
	OwnerMissing  bool   `json:"ownerMissing"`
	OwnerCanWrite bool   `json:"ownerCanWrite"`
	Path          string `json:"path"`
	Size          int64  `json:"size"`
	Offset        int64  `json:"offset"`
	Created       int64  `json:"created"`
	Activity      int64  `json:"activity"`
	Published     bool   `json:"published"`
	Orphan        bool   `json:"orphan"`
	PartPresent   bool   `json:"partPresent"`
	PartSize      int64  `json:"partSize"`
	Corrupt       bool   `json:"corrupt"`
}

func (a *API) adminUploadList(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	limit := 20
	if raw := r.URL.Query().Get("limit"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 1 || parsed > 100 {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_page_size"})
			return
		}
		limit = parsed
	}
	after := r.URL.Query().Get("after")
	if after != "" && (len(after) != 32 || strings.Trim(after, "0123456789abcdef") != "") {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_cursor"})
		return
	}
	records, next, err := a.files.ListUploads(after, limit)
	if err != nil {
		fileError(w, err)
		return
	}
	users, err := a.auth.ListUsers(token(r))
	if err != nil {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "upload_owner_lookup_failed"})
		return
	}
	usersByID := make(map[int64]auth.User, len(users))
	for _, user := range users {
		usersByID[user.ID] = user
	}
	items := make([]adminUploadItem, 0, len(records))
	for _, record := range records {
		state := record.State
		item := adminUploadItem{
			ID: state.ID, OwnerID: state.Owner, Path: state.Path,
			Size: state.Size, Offset: state.Offset, Created: state.Created,
			Activity: state.Activity, Published: state.Published,
			Orphan: record.Orphan, PartPresent: record.PartPresent,
			PartSize: record.PartSize, Corrupt: record.Corrupt,
		}
		user, exists := usersByID[state.Owner]
		item.OwnerMissing = !exists
		if exists {
			item.OwnerName = user.Username
			item.OwnerEnabled = user.Enabled
			if a.rootID != "" {
				item.OwnerCanWrite, err = a.auth.UserCanWriteRoot(user.ID, a.rootID, state.Path)
			} else {
				item.OwnerCanWrite, err = a.auth.UserCanWrite(user.ID, state.Path)
			}
			if err != nil {
				jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "upload_permission_lookup_failed"})
				return
			}
		}
		items = append(items, item)
	}
	jsonReply(w, http.StatusOK, map[string]any{"uploads": items, "nextCursor": next})
}

func (a *API) adminUploadCancel(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	// The file-store evaluates publication state under the same mutex used
	// by FinishUpload. Fallback stores can still cancel but cannot release
	// capacity without a trustworthy unpublication result.
	canRelease := false
	var err error
	if a.rootID != "" {
		if guarded, ok := a.files.(interface{ CancelUploadWithAccounting(string) (bool, error) }); ok {
			canRelease, err = guarded.CancelUploadWithAccounting(r.PathValue("id"))
		} else {
			err = a.files.CancelUpload(r.PathValue("id"))
		}
	} else {
		err = a.files.CancelUpload(r.PathValue("id"))
	}
	if err != nil {
		fileError(w, err)
		return
	}
	if a.rootID != "" && canRelease {
		if id, err := a.auth.ReservationForUpload(r.PathValue("id"), token(r)); err == nil {
			if err := a.auth.ReleaseStorageReservation(id); err != nil {
				storageQuotaError(w, err)
				return
			}
		} else if !errors.Is(err, auth.ErrStorageReservationMissing) {
			storageQuotaError(w, err)
			return
		}
	}
	jsonReply(w, http.StatusOK, map[string]bool{"cancelled": true})
}

func (a *API) adminUploadCleanupExpired(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	defer r.Body.Close()
	var request struct {
		InactiveForSeconds int64 `json:"inactiveForSeconds"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil || request.InactiveForSeconds <= 0 {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_expiry_policy"})
		return
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_expiry_policy"})
		return
	}
	switch request.InactiveForSeconds {
	case int64((7 * 24 * time.Hour).Seconds()), int64((30 * 24 * time.Hour).Seconds()), int64((90 * 24 * time.Hour).Seconds()):
	default:
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "unsupported_expiry_period"})
		return
	}
	cutoff := time.Now().Unix() - request.InactiveForSeconds
	removedIDs, skipped, hasMore, err := a.files.CleanupExpiredUploads(cutoff)
	if err != nil {
		fileError(w, err)
		return
	}
	// The file store only returns IDs whose unpublished staging was safely
	// removed. Clear their reservations; never release skipped/uncertain IDs.
	if a.rootID != "" {
		for _, uploadID := range removedIDs {
			reservation, err := a.auth.ReservationForUpload(uploadID, token(r))
			if errors.Is(err, auth.ErrStorageReservationMissing) {
				continue
			}
			if err != nil {
				storageQuotaError(w, err)
				return
			}
			if err := a.auth.ReleaseStorageReservation(reservation); err != nil {
				storageQuotaError(w, err)
				return
			}
		}
	}
	jsonReply(w, http.StatusOK, map[string]any{
		"removed": len(removedIDs), "removedIDs": removedIDs,
		"skipped": skipped, "hasMore": hasMore,
		"inactiveForSeconds": request.InactiveForSeconds,
	})
}
