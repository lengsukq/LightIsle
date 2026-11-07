package server

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

func (a *API) adminUnknownUploadList(w http.ResponseWriter, r *http.Request) {
	store, ok := a.files.(interface {
		ListUnknownUploadEntries(context.Context, string, int) ([]string, string, error)
	})
	if !ok {
		a.fileUnavailable(w)
		return
	}
	limit := 20
	if raw := r.URL.Query().Get("limit"); raw != "" {
		var err error
		limit, err = strconv.Atoi(raw)
		if err != nil || limit < 1 || limit > 100 {
			jsonReply(w, 400, map[string]string{"error": "invalid_page_size"})
			return
		}
	}
	var after string
	if raw := r.URL.Query().Get("after"); raw != "" {
		if len(raw) > 1400 {
			jsonReply(w, 400, map[string]string{"error": "invalid_cursor"})
			return
		}
		data, err := base64.RawURLEncoding.DecodeString(raw)
		if err != nil || len(data) == 0 || len(data) > 1024 {
			jsonReply(w, 400, map[string]string{"error": "invalid_cursor"})
			return
		}
		after = string(data)
	}
	names, next, err := store.ListUnknownUploadEntries(r.Context(), after, limit)
	if errors.Is(err, files.ErrScanDirectoryChanged) {
		jsonReply(w, 409, map[string]string{"error": "scan_directory_changed"})
		return
	}
	if err != nil {
		fileError(w, err)
		return
	}
	if a.rootLease != nil && !a.rootLease.Valid(r.Context()) {
		jsonReply(w, 503, map[string]string{"error": "root_unavailable"})
		return
	}
	items := make([]map[string]string, 0, len(names))
	for _, name := range names {
		item := map[string]string{"name": name}
		if !utf8.ValidString(name) {
			item["name"] = "无法显示的文件名"
			item["nameBytes"] = base64.RawURLEncoding.EncodeToString([]byte(name))
		}
		items = append(items, item)
	}
	jsonReply(w, 200, map[string]any{
		"items": items, "nextCursor": base64.RawURLEncoding.EncodeToString([]byte(next)),
		"directory": ".lightisle-parts",
	})
}

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
		if a.rootID != "" && (a.rootLease == nil || !a.rootLease.Valid(r.Context())) {
			jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": errUploadCleanupAccountingUncertain.Error()})
			return
		}
		fileError(w, err)
		return
	}
	if a.rootID != "" {
		if err := a.releaseRemovedUploadReservation(r, r.PathValue("id"), canRelease); err != nil {
			jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": errUploadCleanupAccountingUncertain.Error()})
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
		if a.rootID != "" && (len(removedIDs) > 0 || a.rootLease == nil || !a.rootLease.Valid(r.Context())) {
			jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": errUploadCleanupAccountingUncertain.Error()})
			return
		}
		fileError(w, err)
		return
	}
	// The file store returns only staging it checked as unpublished. Recheck
	// the root and destination before releasing each exact reservation.
	pendingReservations := 0
	if a.rootID != "" {
		for _, uploadID := range removedIDs {
			if err := a.releaseRemovedUploadReservation(r, uploadID, true); err != nil {
				pendingReservations++
			}
		}
		if a.rootLease == nil || !a.rootLease.Valid(r.Context()) {
			jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": errUploadCleanupAccountingUncertain.Error()})
			return
		}
	}
	jsonReply(w, http.StatusOK, map[string]any{
		"removed": len(removedIDs), "removedIDs": removedIDs,
		"skipped": skipped, "hasMore": hasMore, "pendingReservations": pendingReservations,
		"inactiveForSeconds": request.InactiveForSeconds,
	})
}
