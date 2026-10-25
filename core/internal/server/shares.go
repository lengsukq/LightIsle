package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"mime"
	"net/http"
	"os"
	"path"
	"syscall"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

const maxSharedFileBytes = int64(2) << 30

// Reserve a limited download at the point ServeContent commits a successful
// GET (200/206). A HEAD, conditional 304, invalid Range 416 or a file that
// cannot be opened must not consume quota. ConsumeShareDownload is atomic, so
// concurrent responses still cannot exceed the configured limit. Once a
// transfer starts, a client disconnect cannot safely refund its reservation.
type shareDownloadQuotaWriter struct {
	http.ResponseWriter
	charge      func() error
	wroteHeader bool
	denied      bool
}

func (w *shareDownloadQuotaWriter) WriteHeader(status int) {
	if w.wroteHeader {
		return
	}
	w.wroteHeader = true
	if status == http.StatusOK || status == http.StatusPartialContent {
		if err := w.charge(); err != nil {
			w.denied = true
			for _, key := range []string{"Content-Range", "Content-Disposition", "Accept-Ranges", "Last-Modified", "ETag", "Content-Length"} {
				w.Header().Del(key)
			}
			http.Error(w.ResponseWriter, "404 page not found", http.StatusNotFound)
			return
		}
	}
	w.ResponseWriter.WriteHeader(status)
}

func (w *shareDownloadQuotaWriter) Write(p []byte) (int, error) {
	if !w.wroteHeader {
		w.WriteHeader(http.StatusOK)
	}
	if w.denied {
		return len(p), nil // Never send any file bytes after quota denial.
	}
	return w.ResponseWriter.Write(p)
}

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

// dirFingerprint binds a folder link to the directory instance itself. Folder
// contents legitimately change while a link is alive, so only the identity of
// the directory node is captured; deleting and recreating the folder (or a
// different disk at the same path) invalidates the link.
func dirFingerprint(info os.FileInfo) (string, bool) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return "", false
	}
	return fmt.Sprintf("d:%d:%d", stat.Dev, stat.Ino), true
}

func (a *API) createFileShare(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 2048)
	defer r.Body.Close()
	var body struct {
		Path         string `json:"path"`
		Hours        int    `json:"hours"`
		Password     string `json:"password"`
		MaxDownloads int    `json:"maxDownloads"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil || body.Path == "" || body.Hours < 1 || body.Hours > auth.MaxShareHours {
		jsonReply(w, 400, map[string]string{"error": "invalid_share_request"})
		return
	}
	policy, policyErr := auth.SharePolicy{Password: body.Password, MaxDownloads: body.MaxDownloads}.Normalize()
	if policyErr != nil {
		jsonReply(w, 400, map[string]string{"error": "invalid_share_request"})
		return
	}
	if !a.allowFile(w, r, body.Path, false) {
		return
	}
	info, err := a.files.Stat(body.Path)
	if err != nil {
		fileError(w, err)
		return
	}
	kind := auth.ShareKindFile
	var identity string
	if info.IsDir() {
		kind = auth.ShareKindDir
		var ok bool
		identity, ok = dirFingerprint(info)
		if !ok {
			jsonReply(w, 503, map[string]string{"error": "unsupported_file_identity"})
			return
		}
		// A link is only published for a folder the owner can actually list.
		if _, listErr := a.files.List(body.Path); listErr != nil {
			fileError(w, listErr)
			return
		}
	} else {
		f, fileDetail, readErr := a.files.Read(body.Path)
		if readErr != nil {
			fileError(w, readErr)
			return
		}
		closeErr := f.Close()
		if closeErr != nil {
			fileError(w, closeErr)
			return
		}
		if fileDetail.Size() < 0 || fileDetail.Size() > maxSharedFileBytes {
			jsonReply(w, 413, map[string]string{"error": "file_too_large_to_share"})
			return
		}
		var ok bool
		identity, ok = fileFingerprint(fileDetail)
		if !ok {
			jsonReply(w, 503, map[string]string{"error": "unsupported_file_identity"})
			return
		}
	}
	var share auth.FileShare
	var capability string
	if a.rootID != "" {
		share, capability, err = a.auth.CreateRootFileShare(r.Context(), token(r), a.rootID, a.rootRuntime.root.Generation, body.Path, identity, kind, time.Now().Add(time.Duration(body.Hours)*time.Hour).Unix(), policy)
	} else {
		share, capability, err = a.auth.CreateFileShare(token(r), body.Path, identity, kind, body.Hours, policy)
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
	// An exhausted link reads as gone for every interaction (form included);
	// the atomic charge below stays the authority against concurrent racing.
	if access.MaxDownloads > 0 && access.DownloadCount >= access.MaxDownloads {
		notFound()
		return
	}
	// Password-protected links require a verified grant cookie before any
	// byte leaves the server. The cookie is minted by the POST form endpoint.
	if len(access.PasswordHash) > 0 && !a.shareGrants.verify(shareGrantValue(r), access.Digest) {
		if r.Method == http.MethodPost {
			a.handleSharePassword(w, r, access, r.PathValue("token"))
			return
		}
		sharePasswordChallenge(w, http.StatusUnauthorized, r.URL.Path,
			sharePasswordMeta(access.ExpiresAt, shareRemaining(access)), "")
		return
	}
	if r.Method == http.MethodPost {
		// A POST that reaches this point already presented a valid grant.
		http.Redirect(w, r, r.URL.Path, http.StatusSeeOther)
		return
	}
	if access.Kind == auth.ShareKindDir {
		a.serveSharedFolder(w, r, access)
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
		if access.MaxDownloads > 0 {
			w = &shareDownloadQuotaWriter{ResponseWriter: w, charge: func() error {
				if a.rootID != "" {
					return a.auth.ConsumeRootShareDownload(access.Digest)
				}
				return a.auth.ConsumeShareDownload(access.Digest)
			}}
		}
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": path.Base(access.Path)}))
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Robots-Tag", "noindex,nofollow,noarchive")
	http.ServeContent(w, r, info.Name(), info.ModTime(), f)
	completed = true
}

// serveSharedFolder streams a folder link as one bounded, streamed ZIP. The
// password gate, quota accounting and audit attribution are shared with the
// single-file path; per-entry authorization is rechecked against the link
// owner's grants on every request so a revoked subdirectory is omitted, not
// disclosed. Content changes between plan and stream abort the response
// rather than emitting a silently truncated archive.
func (a *API) serveSharedFolder(w http.ResponseWriter, r *http.Request, access auth.ShareAccess) {
	notFound := func() { http.NotFound(w, r) }
	info, err := a.files.Stat(access.Path)
	if err != nil || !info.IsDir() {
		notFound()
		return
	}
	identity, ok := dirFingerprint(info)
	if !ok || identity != access.Identity {
		notFound()
		return
	}
	plan, err := a.shareArchivePlan(access, access.Path)
	if err != nil {
		if errors.Is(err, errArchiveLimit) {
			// The link itself is valid; only its export exceeds the bounded
			// archive limits. Plain text, no path or size details leak.
			http.Error(w, "此文件夹超出单链接打包下载的限制，请分目录分享。", http.StatusRequestEntityTooLarge)
			return
		}
		notFound()
		return
	}
	// Every file must still be a readable regular file of the planned size
	// before the 200 starts; a mid-stream change aborts below instead.
	for _, item := range plan {
		if item.directory {
			continue
		}
		f, fileDetail, openErr := a.files.Read(item.path)
		if openErr != nil {
			notFound()
			return
		}
		closeErr := f.Close()
		if closeErr != nil || fileDetail.Size() != item.size {
			http.Error(w, "文件夹内容刚刚发生变化，请重试。", http.StatusConflict)
			return
		}
	}
	if r.Method == http.MethodGet {
		tracked := &auditWriter{ResponseWriter: w}
		w = tracked
		defer func() {
			outcome := auditOutcome(tracked.status)
			if tracked.status != http.StatusOK || tracked.writeErr != nil {
				outcome = "failed"
			}
			a.recordAudit(access.UserID, "public_share_download", "shared_folder", outcome)
		}()
		if access.MaxDownloads > 0 {
			w = &shareDownloadQuotaWriter{ResponseWriter: w, charge: func() error {
				if a.rootID != "" {
					return a.auth.ConsumeRootShareDownload(access.Digest)
				}
				return a.auth.ConsumeShareDownload(access.Digest)
			}}
		}
	}
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": path.Base(access.Path) + ".zip"}))
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Robots-Tag", "noindex,nofollow,noarchive")
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	if err := a.writeFolderZip(w, r, plan, a.shareEntryCheck(access)); err != nil {
		// Never finalize an incomplete ZIP as a successful 200 body.
		panic(http.ErrAbortHandler)
	}
}

// shareEntryCheck re-evaluates the link owner's per-path read authorization
// for every entry streamed out of a folder link.
func (a *API) shareEntryCheck(access auth.ShareAccess) func(string) bool {
	return func(p string) bool {
		if a.rootID != "" {
			return a.auth.UserCanReadRoot(access.UserID, access.RootID, p)
		}
		return a.auth.UserCanRead(access.UserID, p)
	}
}
