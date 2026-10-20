package server

import (
	"encoding/json"
	"errors"
	"io/fs"
	"net/http"
	"path"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func (a *API) fileUnavailable(w http.ResponseWriter) {
	jsonReply(w, 503, map[string]string{"error": "storage_unavailable"})
}
func (a *API) fileRoot(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	jsonReply(w, 200, map[string]string{"name": a.files.DisplayName()})
}

func (a *API) listTrash(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	entries, err := a.files.TrashList()
	if err != nil {
		fileError(w, err)
		return
	}
	visible := make([]files.TrashEntry, 0, len(entries))
	for _, entry := range entries {
		if a.auth.CanAccess(token(r), entry.OriginalPath, true, false) {
			visible = append(visible, entry)
		}
	}
	jsonReply(w, 200, map[string]any{"entries": visible})
}
func (a *API) restoreTrash(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	entry, err := a.files.TrashInfo(r.PathValue("id"))
	if err != nil {
		fileError(w, err)
		return
	}
	if !a.allowFile(w, r, entry.OriginalPath, true) {
		return
	}
	if err := a.files.Restore(r.PathValue("id")); err != nil {
		fileError(w, err)
		return
	}
	jsonReply(w, 200, map[string]bool{"restored": true})
}
func (a *API) previewFile(w http.ResponseWriter, r *http.Request) {
	if !a.allowFile(w, r, r.URL.Query().Get("path"), false) {
		return
	}
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	f, info, err := a.files.Read(r.URL.Query().Get("path"))
	if err != nil {
		fileError(w, err)
		return
	}
	defer f.Close()
	types := map[string]string{
		".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
		".gif": "image/gif", ".webp": "image/webp",
		".txt": "text/plain; charset=utf-8", ".md": "text/plain; charset=utf-8",
		".json": "text/plain; charset=utf-8", ".log": "text/plain; charset=utf-8",
		".mp4": "video/mp4", ".webm": "video/webm", ".m4v": "video/mp4",
	}
	ext := strings.ToLower(filepath.Ext(info.Name()))
	mediaType, ok := types[ext]
	if !ok || (strings.HasPrefix(mediaType, "text/") && info.Size() > 1024*1024) {
		jsonReply(w, 415, map[string]string{"error": "preview_not_supported"})
		return
	}
	w.Header().Set("Content-Type", mediaType)
	w.Header().Set("Content-Disposition", "inline")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; sandbox")
	http.ServeContent(w, r, info.Name(), info.ModTime(), f)
}
func fileError(w http.ResponseWriter, err error) {
	status := http.StatusBadRequest
	code := "invalid_file_operation"
	switch {
	case errors.Is(err, files.ErrPath):
		code = "path_not_allowed"
		status = 400
	case errors.Is(err, files.ErrType):
		code = "unsupported_file_type"
		status = 400
	case errors.Is(err, fs.ErrNotExist):
		code = "not_found"
		status = 404
	case errors.Is(err, files.ErrExists), errors.Is(err, fs.ErrExist):
		code = "file_already_exists"
		status = 409
	case errors.Is(err, files.ErrSize):
		code = "upload_too_large"
		status = 413
	case errors.Is(err, files.ErrOffline):
		code = "shared_volume_offline"
		status = 503
	case errors.Is(err, files.ErrPublishedSync):
		code = "upload_outcome_uncertain"
		status = http.StatusServiceUnavailable
	case errors.Is(err, files.ErrStorageSync):
		code = "storage_durability_failure"
		status = http.StatusServiceUnavailable
	case errors.Is(err, fs.ErrPermission):
		code = "permission_denied"
		status = 403
	}
	jsonReply(w, status, map[string]string{"error": code})
}
func (a *API) listFiles(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	name := r.URL.Query().Get("path")
	if name == "" {
		name = "."
	}
	if a.auth == nil || !a.auth.CanSee(token(r), name) {
		jsonReply(w, 403, map[string]string{"error": "file_permission_denied"})
		return
	}
	limit := 100
	if raw := r.URL.Query().Get("limit"); raw != "" {
		parsed, e := strconv.Atoi(raw)
		if e != nil || parsed < 1 || parsed > 200 {
			jsonReply(w, 400, map[string]string{"error": "invalid_page_size"})
			return
		}
		limit = parsed
	}
	entries, next, err := a.files.Page(name, r.URL.Query().Get("cursor"), limit)
	if err != nil {
		fileError(w, err)
		return
	}
	visible := make([]files.Entry, 0, len(entries))
	for _, entry := range entries {
		if a.auth.CanSee(token(r), entry.Path) {
			visible = append(visible, entry)
		}
	}
	jsonReply(w, 200, map[string]any{"path": name, "entries": visible, "nextCursor": next})
}
func (a *API) readFile(w http.ResponseWriter, r *http.Request) {
	if !a.allowFile(w, r, r.URL.Query().Get("path"), false) {
		return
	}
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	f, info, err := a.files.Read(r.URL.Query().Get("path"))
	if err != nil {
		fileError(w, err)
		return
	}
	defer f.Close()
	w.Header().Set("Content-Disposition", "attachment")
	w.Header().Set("Content-Type", "application/octet-stream")
	// ServeContent provides Range requests without buffering the full file.
	http.ServeContent(w, r, info.Name(), info.ModTime(), f)
}
func (a *API) mkdir(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 2048)
	defer r.Body.Close()
	var body struct {
		Path string `json:"path"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	if !a.allowFile(w, r, body.Path, true) {
		return
	}
	if err := a.files.Mkdir(body.Path); err != nil {
		fileError(w, err)
		return
	}
	jsonReply(w, 201, map[string]any{"created": true, "path": body.Path})
}
func (a *API) uploadFile(w http.ResponseWriter, r *http.Request) {
	if !a.allowFile(w, r, r.URL.Query().Get("path"), true) {
		return
	}
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	if r.ContentLength > 1024*1024*1024 {
		jsonReply(w, 413, map[string]string{"error": "upload_too_large"})
		return
	}
	// The source is streamed and the store itself caps its input.
	size, err := a.files.Upload(r.URL.Query().Get("path"), r.Body)
	if err != nil {
		fileError(w, err)
		return
	}
	jsonReply(w, 201, map[string]any{"uploaded": true, "size": size})
}
func (a *API) trashFile(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	name := r.URL.Query().Get("path")
	if name == "" || name == "." || path.Clean(name) == "." || strings.HasPrefix(name, ".lightisle-") {
		jsonReply(w, 400, map[string]string{"error": "path_not_allowed"})
		return
	}
	if !a.allowFile(w, r, name, true) {
		return
	}
	if err := a.files.MoveToTrash(name); err != nil {
		fileError(w, err)
		return
	}
	jsonReply(w, 200, map[string]any{"trashed": true})
}
