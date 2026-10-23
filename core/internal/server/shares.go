package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"mime"
	"net/http"
	"path"
	"syscall"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

const maxSharedFileBytes = int64(2) << 30

// fileFingerprint binds a link to the same file instance and metadata, so
// replacing its pathname cannot accidentally disclose a different file.
func fileFingerprint(info interface {
	Size() int64
	ModTime() time.Time
	Sys() any
}) (string, bool) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return "", false
	}
	return fmt.Sprintf("%d:%d:%d:%d", stat.Dev, stat.Ino, info.Size(), info.ModTime().UnixNano()), true
}

func (a *API) createFileShare(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 2048)
	defer r.Body.Close()
	var body struct {
		Path  string `json:"path"`
		Hours int    `json:"hours"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil || body.Path == "" || body.Hours < 1 || body.Hours > auth.MaxShareHours {
		jsonReply(w, 400, map[string]string{"error": "invalid_share_request"})
		return
	}
	if !a.allowFile(w, r, body.Path, false) {
		return
	}
	f, info, err := a.files.Read(body.Path)
	if err != nil {
		fileError(w, err)
		return
	}
	closeErr := f.Close()
	if closeErr != nil {
		fileError(w, closeErr)
		return
	}
	if info.Size() < 0 || info.Size() > maxSharedFileBytes {
		jsonReply(w, 413, map[string]string{"error": "file_too_large_to_share"})
		return
	}
	identity, ok := fileFingerprint(info)
	if !ok {
		jsonReply(w, 503, map[string]string{"error": "unsupported_file_identity"})
		return
	}
	var share auth.FileShare
	var capability string
	if a.rootID != "" {
		share, capability, err = a.auth.CreateRootFileShare(r.Context(), token(r), a.rootID, a.rootRuntime.root.Generation, body.Path, identity, time.Now().Add(time.Duration(body.Hours)*time.Hour).Unix())
	} else {
		share, capability, err = a.auth.CreateFileShare(token(r), body.Path, identity, body.Hours)
	}
	switch {
	case err == nil:
		jsonReply(w, 201, map[string]any{"share": share, "token": capability})
	case errors.Is(err, auth.ErrExists):
		jsonReply(w, 409, map[string]string{"error": "too_many_shares"})
	case errors.Is(err, auth.ErrForbidden):
		jsonReply(w, 403, map[string]string{"error": "file_permission_denied"})
	case errors.Is(err, auth.ErrInput):
		jsonReply(w, 400, map[string]string{"error": "invalid_share_request"})
	default:
		jsonReply(w, 500, map[string]string{"error": "share_creation_failed"})
	}
}

func (a *API) listFileShares(w http.ResponseWriter, r *http.Request) {
	var shares []auth.FileShare
	var err error
	if a.rootID != "" {
		shares, err = a.auth.ListRootFileShares(token(r), a.rootID)
	} else {
		shares, err = a.auth.ListFileShares(token(r))
	}
	if err != nil {
		jsonReply(w, 500, map[string]string{"error": "share_list_failed"})
		return
	}
	jsonReply(w, 200, map[string]any{"shares": shares})
}

func (a *API) revokeFileShare(w http.ResponseWriter, r *http.Request) {
	var err error
	if a.rootID != "" {
		err = a.auth.RevokeRootFileShare(r.Context(), token(r), a.rootID, r.PathValue("id"))
	} else {
		err = a.auth.RevokeFileShare(token(r), r.PathValue("id"))
	}
	if errors.Is(err, auth.ErrInput) {
		jsonReply(w, 400, map[string]string{"error": "invalid_share_id"})
		return
	}
	if err != nil {
		jsonReply(w, 500, map[string]string{"error": "share_revoke_failed"})
		return
	}
	jsonReply(w, 200, map[string]bool{"revoked": true})
}

func (a *API) downloadSharedFile(w http.ResponseWriter, r *http.Request) {
	// Invalid, revoked and unauthorized links deliberately share the same 404.
	notFound := func() { http.NotFound(w, r) }
	if a.files == nil || a.auth == nil {
		notFound()
		return
	}
	var access auth.ShareAccess
	var err error
	if a.rootID != "" {
		access, err = a.auth.ResolveRootFileShare(r.PathValue("token"))
		if err != nil || access.RootID != a.rootID || a.rootRuntime == nil || access.RootGeneration != a.rootRuntime.root.Generation || !a.auth.UserCanReadRoot(access.UserID, access.RootID, access.Path) {
			notFound()
			return
		}
	} else {
		access, err = a.auth.ResolveFileShare(r.PathValue("token"))
		if err != nil || !a.auth.UserCanRead(access.UserID, access.Path) {
			notFound()
			return
		}
	}
	if err != nil {
		notFound()
		return
	}
	f, info, err := a.files.Read(access.Path)
	if err != nil {
		notFound()
		return
	}
	defer f.Close()
	identity, ok := fileFingerprint(info)
	if !ok || identity != access.Identity || info.Size() > maxSharedFileBytes {
		notFound()
		return
	}
	// Public downloads have no login session. Attribute the response to the
	// link creator only after ServeContent has determined its actual status.
	// A rejected Range or failed write must not be logged as a success.
	completed := false
	if r.Method == http.MethodGet {
		tracked := &auditWriter{ResponseWriter: w}
		w = tracked
		defer func() {
			outcome := auditOutcome(tracked.status)
			if !completed || tracked.writeErr != nil {
				outcome = "failed"
			}
			a.recordAudit(access.UserID, "public_share_download", "shared_file", outcome)
		}()
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": path.Base(access.Path)}))
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Robots-Tag", "noindex,nofollow,noarchive")
	http.ServeContent(w, r, info.Name(), info.ModTime(), f)
	completed = true
}
