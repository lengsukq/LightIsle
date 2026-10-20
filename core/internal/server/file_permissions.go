package server

import (
	"encoding/json"
	"github.com/lengsukq/lightisle/core/internal/auth"
	"net/http"
	"strconv"
)

func (a *API) allowFile(w http.ResponseWriter, r *http.Request, p string, write bool) bool {
	if a.auth != nil && a.auth.CanAccess(token(r), p, write, false) {
		return true
	}
	jsonReply(w, http.StatusForbidden, map[string]string{"error": "file_permission_denied"})
	return false
}
func (a *API) allowMedia(w http.ResponseWriter, r *http.Request) bool {
	_, ok := a.mediaRoots(w, r)
	return ok
}
func (a *API) mediaRoots(w http.ResponseWriter, r *http.Request) ([]string, bool) {
	if a.auth == nil {
		jsonReply(w, 403, map[string]string{"error": "file_permission_denied"})
		return nil, false
	}
	roots, err := a.auth.SearchRoots(token(r), ".")
	if err != nil || len(roots) == 0 {
		jsonReply(w, 403, map[string]string{"error": "file_permission_denied"})
		return nil, false
	}
	return roots, true
}
func (a *API) requireMedia(next http.HandlerFunc) http.HandlerFunc {
	return a.requireLogin(func(w http.ResponseWriter, r *http.Request) {
		if a.allowMedia(w, r) {
			next(w, r)
		}
	})
}
func (a *API) fileGrantUser(w http.ResponseWriter, r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		jsonReply(w, 400, map[string]string{"error": "invalid_user"})
		return 0, false
	}
	return id, true
}
func (a *API) getFileGrants(w http.ResponseWriter, r *http.Request) {
	id, ok := a.fileGrantUser(w, r)
	if !ok {
		return
	}
	gs, err := a.auth.FileGrants(token(r), id)
	if err != nil {
		jsonReply(w, 400, map[string]string{"error": "cannot_list_grants"})
		return
	}
	jsonReply(w, 200, map[string]any{"grants": gs})
}
func (a *API) setFileGrant(w http.ResponseWriter, r *http.Request) {
	id, ok := a.fileGrantUser(w, r)
	if !ok {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 2048)
	defer r.Body.Close()
	var req struct {
		Path     string `json:"path"`
		CanWrite bool   `json:"canWrite"`
	}
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if d.Decode(&req) != nil {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	// Validate existence and directory type before recording access.
	if _, _, err := a.files.Page(req.Path, "", 1); err != nil {
		fileError(w, err)
		return
	}
	if err := a.auth.SetFileGrant(token(r), id, req.Path, req.CanWrite); err != nil {
		code := 400
		if err == auth.ErrForbidden {
			code = 403
		}
		jsonReply(w, code, map[string]string{"error": "invalid_grant"})
		return
	}
	jsonReply(w, 200, map[string]bool{"saved": true})
}
func (a *API) deleteFileGrant(w http.ResponseWriter, r *http.Request) {
	id, ok := a.fileGrantUser(w, r)
	if !ok {
		return
	}
	if err := a.auth.RemoveFileGrant(token(r), id, r.URL.Query().Get("path")); err != nil {
		jsonReply(w, 400, map[string]string{"error": "invalid_grant"})
		return
	}
	jsonReply(w, 200, map[string]bool{"removed": true})
}
