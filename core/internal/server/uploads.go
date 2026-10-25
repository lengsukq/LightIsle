package server

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	"github.com/lengsukq/lightisle/core/internal/files"
)

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
	// Cancelling only removes this owner's staging state. Keep this available
	// after a directory write grant is revoked so the owner can release an
	// upload that can no longer resume.
	if err := store.AbortUpload(r.PathValue("id"), owner); err != nil {
		fileError(w, err)
		return
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
		upload, err := store.BeginUpload(destination, request.Size, owner)
		if err == nil {
			jsonReply(w, 201, upload)
			return
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
	current, err := store.UploadInfo(r.PathValue("id"), owner)
	if err != nil {
		fileError(w, err)
		return
	}
	if !a.allowFile(w, r, current.Path, true) {
		return
	}
	state, err := store.AppendUpload(r.PathValue("id"), owner, offset, r.Body)
	if errors.Is(err, files.ErrOffset) {
		w.Header().Set("X-Upload-Offset", strconv.FormatInt(state.Offset, 10))
		jsonReply(w, 409, map[string]any{"error": "offset_mismatch", "offset": state.Offset})
		return
	}
	if err != nil {
		fileError(w, err)
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
	if err := store.FinishUpload(r.PathValue("id"), owner); err != nil {
		fileError(w, err)
		return
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
	for _, p := range req.Paths {
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
			results = append(results, map[string]any{"path": p, "success": false, "error": "operation_failed"})
			continue
		}
		results = append(results, map[string]any{"path": p, "success": true})
	}
	jsonReply(w, 200, map[string]any{"results": results})
}
