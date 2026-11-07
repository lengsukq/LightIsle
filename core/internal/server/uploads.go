package server

import (
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

var fileUploadSlots = make(chan struct{}, 4)

type fileUploadBody struct {
	io.Reader
	controller *http.ResponseController
	refreshAt  time.Time
}

func (b *fileUploadBody) Read(buf []byte) (int, error) {
	now := time.Now()
	if !now.Before(b.refreshAt) {
		_ = b.controller.SetReadDeadline(now.Add(time.Minute))
		b.refreshAt = now.Add(15 * time.Second)
	}
	return b.Reader.Read(buf)
}

// Bound the number of requests that can occupy disk staging and volume
// leases. A slow but progressing transfer can keep renewing its deadline.
func admitFileUpload(w http.ResponseWriter, source io.Reader) (*fileUploadBody, bool) {
	body := &fileUploadBody{Reader: source, controller: http.NewResponseController(w)}
	now := time.Now()
	_ = body.controller.SetReadDeadline(now.Add(time.Minute))
	body.refreshAt = now.Add(15 * time.Second)
	select {
	case fileUploadSlots <- struct{}{}:
		return body, true
	default:
		w.Header().Set("Retry-After", "2")
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "upload_server_busy"})
		return nil, false
	}
}

func uploadStreamError(w http.ResponseWriter, err error) {
	if errors.Is(err, os.ErrDeadlineExceeded) {
		jsonReply(w, http.StatusRequestTimeout, map[string]string{"error": "upload_timed_out"})
		return
	}
	fileError(w, err)
}

func (a *API) uploader(w http.ResponseWriter, r *http.Request) (files.Access, int64, bool) {
	if a.files == nil {
		a.fileUnavailable(w)
		return nil, 0, false
	}
	user, ok := a.auth.Identity(token(r))
	if !ok {
		jsonReply(w, 401, map[string]string{"error": "authentication_required"})
		return nil, 0, false
	}
	return a.files, user.ID, true
}
func (a *API) uploadAbort(w http.ResponseWriter, r *http.Request) {
	store, owner, ok := a.uploader(w, r)
	if !ok {
		return
	}
	releaseReservation := false
	// Cancelling only removes this owner's staging state. Keep this available
	// after a directory write grant is revoked so the owner can release an
	// upload that can no longer resume.
	var err error
	if a.rootID != "" {
		if guarded, ok := store.(interface {
			AbortUploadWithAccounting(string, int64) (bool, error)
		}); ok {
			releaseReservation, err = guarded.AbortUploadWithAccounting(r.PathValue("id"), owner)
		} else {
			err = store.AbortUpload(r.PathValue("id"), owner)
		}
	} else {
		err = store.AbortUpload(r.PathValue("id"), owner)
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
		if err := a.releaseRemovedUploadReservation(r, r.PathValue("id"), releaseReservation); err != nil {
			jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": errUploadCleanupAccountingUncertain.Error()})
			return
		}
	}
	jsonReply(w, 200, map[string]bool{"cancelled": true})
}
func (a *API) beginUpload(w http.ResponseWriter, r *http.Request) {
	store, owner, ok := a.uploader(w, r)
	if !ok {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 2048)
	defer r.Body.Close()
	var request struct {
		Path       string `json:"path"`
		Size       int64  `json:"size"`
		OnConflict string `json:"onConflict"`
	}
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if d.Decode(&request) != nil {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	if _, err := files.ValidateConflict(request.OnConflict); err != nil || request.OnConflict == files.ConflictSkip {
		// Skip is meaningless for uploads: staging only materializes on
		// completion, so the only meaningful policy is rename or refuse.
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	destination := request.Path
	for attempt := 0; attempt <= 1000; attempt++ {
		if !a.allowFile(w, r, destination, true) {
			return
		}
		id, _, err := a.reserveUploadQuota(r, destination, request.Size)
		if err != nil {
			storageQuotaError(w, err)
			return
		}
		upload, err := store.BeginUpload(destination, request.Size, owner)
		if err == nil {
			if id != "" {
				if err = a.auth.LinkStorageUpload(id, upload.ID); err != nil {
					// The link may have succeeded despite an ambiguous DB error.
					// Only a verified unpublished abort and an exact, still-
					// unlinked reservation allow release.
					guarded, ok := store.(interface {
						AbortUploadWithAccounting(string, int64) (bool, error)
					})
					if !ok {
						jsonReply(w, 503, map[string]string{"error": "upload_begin_uncertain"})
						return
					}
					safe, abortErr := guarded.AbortUploadWithAccounting(upload.ID, owner)
					_, statErr := store.Stat(destination)
					if abortErr != nil || !safe || !errors.Is(statErr, fs.ErrNotExist) ||
						a.rootLease == nil || !a.rootLease.Valid(r.Context()) ||
						a.auth.ReleaseUnlinkedStorageReservation(id, a.rootID, a.rootRuntime.root.Generation, destination, request.Size) != nil {
						jsonReply(w, 503, map[string]string{"error": "upload_begin_uncertain"})
						return
					}
					storageQuotaError(w, err)
					return
				}
			}
			if a.rootID != "" && (a.rootLease == nil || !a.rootLease.Valid(r.Context())) {
				jsonReply(w, 503, map[string]string{"error": "upload_begin_uncertain"})
				return
			}
			jsonReply(w, 201, upload)
			return
		}
		if errors.Is(err, files.ErrUploadBeginUncertain) ||
			(a.rootID != "" && (a.rootLease == nil || !a.rootLease.Valid(r.Context()))) {
			jsonReply(w, 503, map[string]string{"error": "upload_begin_uncertain"})
			return
		}
		if id != "" {
			if a.rootLease == nil || !a.rootLease.Valid(r.Context()) ||
				a.auth.ReleaseUnlinkedStorageReservation(id, a.rootID, a.rootRuntime.root.Generation, destination, request.Size) != nil {
				jsonReply(w, 503, map[string]string{"error": "upload_begin_uncertain"})
				return
			}
		}
		if request.OnConflict != files.ConflictRename || !errors.Is(err, files.ErrExists) {
			fileError(w, err)
			return
		}
		// Derive each candidate from the original path. Otherwise repeated
		// conflicts produce "name (2) (3)" instead of "name (3)".
		next, candidateErr := files.NextRenameCandidate(request.Path, attempt+2)
		if candidateErr != nil {
			fileError(w, candidateErr)
			return
		}
		destination = next
	}
	jsonReply(w, 409, map[string]string{"error": "file_already_exists"})
}
func (a *API) uploadStatus(w http.ResponseWriter, r *http.Request) {
	store, owner, ok := a.uploader(w, r)
	if !ok {
		return
	}
	state, err := store.UploadInfo(r.PathValue("id"), owner)
	if err != nil {
		fileError(w, err)
		return
	}
	if !a.allowFile(w, r, state.Path, true) {
		return
	}
	jsonReply(w, 200, state)
}
func (a *API) uploadChunk(w http.ResponseWriter, r *http.Request) {
	store, owner, ok := a.uploader(w, r)
	if !ok {
		return
	}
	if r.ContentLength < 0 || r.ContentLength > 8<<20 {
		jsonReply(w, 413, map[string]string{"error": "invalid_chunk_size"})
		return
	}
	offset, err := strconv.ParseInt(r.Header.Get("X-Upload-Offset"), 10, 64)
	if err != nil || offset < 0 {
		jsonReply(w, 400, map[string]string{"error": "invalid_offset"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, (8<<20)+1)
	defer r.Body.Close()
	body, admitted := admitFileUpload(w, r.Body)
	if !admitted {
		return
	}
	defer func() { <-fileUploadSlots }()
	current, err := store.UploadInfo(r.PathValue("id"), owner)
	if err != nil {
		fileError(w, err)
		return
	}
	if !a.allowFile(w, r, current.Path, true) {
		return
	}
	if a.rootID != "" && managedStorageName(current.Path) {
		if _, err := a.auth.ReservationForUpload(r.PathValue("id"), token(r)); err != nil {
			storageQuotaError(w, err)
			return
		}
	}
	state, err := store.AppendUpload(r.PathValue("id"), owner, offset, body)
	if errors.Is(err, files.ErrOffset) {
		w.Header().Set("X-Upload-Offset", strconv.FormatInt(state.Offset, 10))
		jsonReply(w, 409, map[string]any{"error": "offset_mismatch", "offset": state.Offset})
		return
	}
	if err != nil {
		uploadStreamError(w, err)
		return
	}
	jsonReply(w, 200, state)
}
func (a *API) uploadComplete(w http.ResponseWriter, r *http.Request) {
	store, owner, ok := a.uploader(w, r)
	if !ok {
		return
	}
	current, err := store.UploadInfo(r.PathValue("id"), owner)
	if err != nil {
		fileError(w, err)
		return
	}
	if !a.allowFile(w, r, current.Path, true) {
		return
	}
	var reservation string
	if a.rootID != "" && managedStorageName(current.Path) {
		reservation, err = a.auth.ReservationForUpload(r.PathValue("id"), token(r))
		if err != nil {
			storageQuotaError(w, err)
			return
		}
	}
	var identity string
	if guarded, ok := store.(interface {
		FinishUploadWithIdentity(string, int64) (string, error)
	}); ok && reservation != "" {
		identity, err = guarded.FinishUploadWithIdentity(r.PathValue("id"), owner)
	} else {
		err = store.FinishUpload(r.PathValue("id"), owner)
	}
	if err != nil {
		fileError(w, err)
		return
	}
	if reservation != "" {
		// A successful staged-file publish is not sufficient proof that the
		// original removable root remained connected through completion.
		// Keep all reserved bytes on an ambiguous detach or generation swap.
		if a.rootLease == nil || !a.rootLease.Valid(r.Context()) {
			jsonReply(w, 500, map[string]string{"error": "storage_accounting_uncertain"})
			return
		}
		if err := a.auth.CommitStorageReservationWithIdentity(reservation, identity); err != nil {
			jsonReply(w, 500, map[string]string{"error": "storage_accounting_uncertain"})
			return
		}
	}
	if a.rootID != "" && (a.rootLease == nil || !a.rootLease.Valid(r.Context())) {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "root_unavailable"})
		return
	}
	if a.rootServer != nil {
		a.rootServer.QueueMediaRefresh(a.rootID, current.Path)
	}
	jsonReply(w, 200, map[string]bool{"completed": true})
}
func (a *API) fileBatch(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 16384)
	defer r.Body.Close()
	var req struct {
		Action string   `json:"action"`
		Paths  []string `json:"paths"`
	}
	if json.NewDecoder(r.Body).Decode(&req) != nil || req.Action != "trash" || len(req.Paths) < 1 || len(req.Paths) > 50 {
		jsonReply(w, 400, map[string]string{"error": "invalid_batch"})
		return
	}
	results := make([]map[string]any, 0, len(req.Paths))
	rootLost := false
	trashChanged := false
	for _, p := range req.Paths {
		if rootLost || (a.rootID != "" && (a.rootLease == nil || !a.rootLease.Valid(r.Context()))) {
			rootLost = true
			results = append(results, map[string]any{"path": p, "success": false, "error": "root_unavailable"})
			continue
		}
		if trashChanged {
			results = append(results, map[string]any{"path": p, "success": false, "error": "operation_not_started"})
			continue
		}
		if len(p) > 1024 {
			results = append(results, map[string]any{"path": p, "success": false, "error": "invalid_path"})
			continue
		}
		if !a.canAccess(token(r), p, true, false) {
			results = append(results, map[string]any{"path": p, "success": false, "error": "file_permission_denied"})
			continue
		}
		err := a.files.MoveToTrash(p)
		if err != nil {
			if a.rootID != "" && (a.rootLease == nil || !a.rootLease.Valid(r.Context())) {
				rootLost = true
				results = append(results, map[string]any{"path": p, "success": false, "error": "storage_operation_uncertain"})
				continue
			}
			if errors.Is(err, files.ErrTrashChanged) {
				trashChanged = true
				results = append(results, map[string]any{"path": p, "success": false, "error": "trash_item_changed"})
				continue
			}
			results = append(results, map[string]any{"path": p, "success": false, "error": "operation_failed"})
			continue
		}
		if a.rootID != "" && (a.rootLease == nil || !a.rootLease.Valid(r.Context())) {
			rootLost = true
			results = append(results, map[string]any{"path": p, "success": false, "error": "storage_operation_uncertain"})
			continue
		}
		if a.rootServer != nil {
			a.rootServer.QueueMediaRefresh(a.rootID, p)
		}
		results = append(results, map[string]any{"path": p, "success": true})
	}
	jsonReply(w, 200, map[string]any{"results": results})
}
