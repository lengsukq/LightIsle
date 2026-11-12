package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/computerfiles"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
	"golang.org/x/sys/unix"
)

func (a *API) isProtectedComputerPath(clean string) bool {
	if a != nil && a.auth != nil && a.auth.DataDir() != "" {
		return computerfiles.IsProtectedHostPath(clean, a.auth.DataDir())
	}
	return computerfiles.IsProtectedHostPath(clean)
}

func registerComputerFiles(mux *http.ServeMux, a *API) {
	mux.HandleFunc("GET /api/v2/computer-files/status", a.requireLogin(a.computerFileStatus))
	mux.HandleFunc("GET /api/v2/computer-files", a.requireLogin(a.computerFileList))
	mux.HandleFunc("GET /api/v2/computer-files/content", a.requireLogin(a.computerFileContent))
	mux.HandleFunc("HEAD /api/v2/computer-files/content", a.requireLogin(a.computerFileContent))
	mux.HandleFunc("GET /api/v2/computer-files/preview", a.requireLogin(a.computerFilePreview))
	mux.HandleFunc("HEAD /api/v2/computer-files/preview", a.requireLogin(a.computerFilePreview))
	mux.HandleFunc("GET /api/v2/computer-files/archive", a.requireLogin(a.computerFolderArchive))
	mux.HandleFunc("HEAD /api/v2/computer-files/archive", a.requireLogin(a.computerFolderArchive))
	mux.HandleFunc("GET /api/v2/computer-files/grants/{id}", a.requireAdmin(a.getComputerFileGrant))
	mux.HandleFunc("PUT /api/v2/computer-files/grants/{id}", a.requireAdmin(a.setComputerFileGrant))
}

func (a *API) computerFileStatus(w http.ResponseWriter, r *http.Request) {
	user, ok := a.auth.Identity(token(r))
	if !ok {
		jsonReply(w, 401, map[string]string{"error": "authentication_required"})
		return
	}
	grant := auth.ComputerFileGrant{Mode: "all", Folders: []auth.ComputerFolder{}}
	if user.Role != auth.RoleAdmin {
		var err error
		grant, err = a.auth.ComputerFileGrant(user.ID)
		if err != nil {
			jsonReply(w, 503, map[string]string{"error": "computer_access_unavailable"})
			return
		}
	}
	jsonReply(w, 200, map[string]any{"enabled": a.auth.ComputerFilesEnabled(), "mode": grant.Mode})
}

func computerUserID(r *http.Request) (int64, error) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		return 0, auth.ErrInput
	}
	return id, nil
}
func (a *API) getComputerFileGrant(w http.ResponseWriter, r *http.Request) {
	id, err := computerUserID(r)
	if err != nil {
		jsonReply(w, 400, map[string]string{"error": "invalid_user"})
		return
	}
	user, err := a.auth.GetUser(id)
	if err != nil || user.Role != auth.RoleMember {
		jsonReply(w, 404, map[string]string{"error": "user_not_found"})
		return
	}
	grant, err := a.auth.ComputerFileGrant(id)
	if err != nil {
		jsonReply(w, 503, map[string]string{"error": "computer_access_unavailable"})
		return
	}
	jsonReply(w, 200, grant)
}
func (a *API) setComputerFileGrant(w http.ResponseWriter, r *http.Request) {
	if !a.auth.ComputerFilesEnabled() {
		jsonReply(w, 403, map[string]string{"error": "computer_access_disabled"})
		return
	}
	id, err := computerUserID(r)
	if err != nil {
		jsonReply(w, 400, map[string]string{"error": "invalid_user"})
		return
	}
	var body struct {
		Mode  string   `json:"mode"`
		Paths []string `json:"paths"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 32<<10)
	defer r.Body.Close()
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if d.Decode(&body) != nil || (body.Mode != "none" && body.Mode != "all" && body.Mode != "folders") || len(body.Paths) > 32 || (body.Mode == "folders" && len(body.Paths) == 0) {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	grant := auth.ComputerFileGrant{Mode: body.Mode, Folders: []auth.ComputerFolder{}}
	seen := map[string]bool{}
	if body.Mode == "folders" {
		for _, raw := range body.Paths {
			path, cleanErr := computerfiles.Clean(raw)
			if cleanErr != nil || seen[path] {
				jsonReply(w, 400, map[string]string{"error": "computer_path_invalid"})
				return
			}
			if a.isProtectedComputerPath(path) {
				computerFileError(w, fs.ErrPermission)
				return
			}
			f, openErr := computerfiles.Open(path)
			if openErr != nil {
				computerFileError(w, openErr)
				return
			}
			info, statErr := f.Stat()
			binding, captureErr := storageidentity.Capture(r.Context(), path)
			f.Close()
			if statErr != nil || captureErr != nil || binding.Path != path || !storageidentity.MatchesDirectory(binding, info) {
				computerFileError(w, statErr)
				return
			}
			encoded, _ := json.Marshal(binding)
			seen[path] = true
			grant.Folders = append(grant.Folders, auth.ComputerFolder{Path: path, Identity: string(encoded)})
		}
	}
	if err = a.auth.SetComputerFileGrant(token(r), id, grant); err != nil {
		jsonReply(w, 403, map[string]string{"error": "computer_grant_failed"})
		return
	}
	jsonReply(w, 200, grant)
}

type computerAccess struct {
	a                *API
	session          string
	userID           int64
	role             string
	sessionExpiresAt *atomic.Int64
	verifiedEpoch    *atomic.Uint64
	lastFolderStatNs *atomic.Int64
	mode             string
	folder           auth.ComputerFolder
	openIdentity     string
	binding          storageidentity.Binding
	settingsRevision int64
	grantRevision    int64
}

func (a *API) openComputerFile(r *http.Request, path string) (*os.File, computerAccess, error) {
	epochSnapshot := a.auth.AccessEpoch()
	user, expiresAt, ok := a.auth.IdentityWithExpiry(token(r))
	enabled, revision := a.auth.ComputerFilesState()
	if !ok || !enabled {
		return nil, computerAccess{}, fs.ErrPermission
	}
	clean, err := computerfiles.Clean(path)
	if err != nil {
		return nil, computerAccess{}, err
	}
	if a.isProtectedComputerPath(clean) {
		return nil, computerAccess{}, fs.ErrPermission
	}
	expAtom := &atomic.Int64{}
	expAtom.Store(expiresAt)
	epochAtom := &atomic.Uint64{}
	epochAtom.Store(epochSnapshot)
	folderStatAtom := &atomic.Int64{}
	access := computerAccess{
		a:                a,
		session:          token(r),
		userID:           user.ID,
		role:             user.Role,
		sessionExpiresAt: expAtom,
		verifiedEpoch:    epochAtom,
		lastFolderStatNs: folderStatAtom,
		mode:             "all",
		settingsRevision: revision,
	}
	if user.Role == auth.RoleAdmin {
		f, e := computerfiles.Open(clean)
		return f, access, e
	}
	grant, err := a.auth.ComputerFileGrant(user.ID)
	if err != nil {
		return nil, access, fs.ErrPermission
	}
	access.grantRevision = grant.Revision
	if grant.Mode == "all" {
		f, e := computerfiles.Open(clean)
		return f, access, e
	}
	if grant.Mode == "folders" {
		for _, folder := range grant.Folders {
			if a.isProtectedComputerPath(folder.Path) {
				continue
			}
			rel, e := filepath.Rel(folder.Path, clean)
			if e == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
				access.mode = "folders"
				access.folder = folder
				if json.Unmarshal([]byte(folder.Identity), &access.binding) != nil || access.binding.Path != folder.Path || storageidentity.Verify(r.Context(), access.binding) != nil {
					return nil, access, computerfiles.ErrChanged
				}
				root, e := computerfiles.Open(folder.Path)
				if e != nil {
					return nil, access, e
				}
				info, e := root.Stat()
				if e != nil || !storageidentity.MatchesDirectory(access.binding, info) {
					root.Close()
					return nil, access, computerfiles.ErrChanged
				}
				access.openIdentity, e = computerfiles.Identity(root)
				if e == nil {
					e = storageidentity.Verify(r.Context(), access.binding)
				}
				root.Close()
				if e != nil {
					return nil, access, computerfiles.ErrChanged
				}
				folderStatAtom.Store(time.Now().UnixNano())
				f, e := computerfiles.OpenInGrant(folder.Path, access.openIdentity, clean)
				return f, access, e
			}
		}
	}
	return nil, access, fs.ErrPermission
}

func (x computerAccess) verifyFolderOnDisk(nowNs int64) bool {
	f, e := computerfiles.Open(x.folder.Path)
	if e != nil {
		return false
	}
	defer f.Close()
	id, e := computerfiles.Identity(f)
	info, statErr := f.Stat()
	if e != nil || statErr != nil || id != x.openIdentity || !storageidentity.MatchesDirectory(x.binding, info) {
		return false
	}
	if x.lastFolderStatNs != nil {
		x.lastFolderStatNs.Store(nowNs)
	}
	return true
}

func (x computerAccess) valid() bool {
	if x.a == nil || x.a.auth == nil {
		return false
	}
	now := time.Now()
	curEpoch := x.a.auth.AccessEpoch()
	if curEpoch > 0 && x.verifiedEpoch != nil && x.sessionExpiresAt != nil &&
		x.verifiedEpoch.Load() == curEpoch && now.Unix() < x.sessionExpiresAt.Load() {
		if x.mode == "all" {
			return true
		}
		if x.mode == "folders" {
			if x.lastFolderStatNs != nil && now.UnixNano()-x.lastFolderStatNs.Load() < int64(250*time.Millisecond) {
				return true
			}
			return x.verifyFolderOnDisk(now.UnixNano())
		}
		return false
	}
	user, expiresAt, ok := x.a.auth.IdentityWithExpiry(x.session)
	enabled, revision := x.a.auth.ComputerFilesState()
	if !ok || user.ID != x.userID || !enabled || revision != x.settingsRevision {
		return false
	}
	if user.Role == auth.RoleAdmin {
		if x.mode != "all" {
			return false
		}
		if x.sessionExpiresAt != nil {
			x.sessionExpiresAt.Store(expiresAt)
		}
		if x.verifiedEpoch != nil {
			x.verifiedEpoch.Store(curEpoch)
		}
		return true
	}
	g, err := x.a.auth.ComputerFileGrant(user.ID)
	if err != nil || g.Mode != x.mode || g.Revision != x.grantRevision {
		return false
	}
	if x.mode == "all" {
		if x.sessionExpiresAt != nil {
			x.sessionExpiresAt.Store(expiresAt)
		}
		if x.verifiedEpoch != nil {
			x.verifiedEpoch.Store(curEpoch)
		}
		return true
	}
	for _, folder := range g.Folders {
		if folder == x.folder && !x.a.isProtectedComputerPath(folder.Path) {
			if !x.verifyFolderOnDisk(now.UnixNano()) {
				return false
			}
			if x.sessionExpiresAt != nil {
				x.sessionExpiresAt.Store(expiresAt)
			}
			if x.verifiedEpoch != nil {
				x.verifiedEpoch.Store(curEpoch)
			}
			return true
		}
	}
	return false
}

type computerReader struct {
	f      *os.File
	access computerAccess
}

func (r computerReader) Read(p []byte) (int, error) {
	if !r.access.valid() {
		return 0, fs.ErrPermission
	}
	return r.f.Read(p)
}
func (r computerReader) Seek(offset int64, whence int) (int64, error) {
	if !r.access.valid() {
		return 0, fs.ErrPermission
	}
	return r.f.Seek(offset, whence)
}

func computerFileError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, computerfiles.ErrChanged):
		jsonReply(w, 409, map[string]string{"error": "computer_folder_changed"})
	case errors.Is(err, computerfiles.ErrPath):
		jsonReply(w, 400, map[string]string{"error": "computer_path_invalid"})
	case errors.Is(err, fs.ErrPermission):
		jsonReply(w, 403, map[string]string{"error": "computer_permission_denied"})
	case errors.Is(err, fs.ErrNotExist):
		jsonReply(w, 404, map[string]string{"error": "computer_file_not_found"})
	default:
		jsonReply(w, 403, map[string]string{"error": "computer_file_unavailable"})
	}
}

type computerEntry struct {
	Name string `json:"name"`
	Path string `json:"path"`
	Type string `json:"type"`
	Size int64  `json:"size"`
}

func (a *API) computerFileList(w http.ResponseWriter, r *http.Request) {
	user, ok := a.auth.Identity(token(r))
	if !ok || !a.auth.ComputerFilesEnabled() {
		computerFileError(w, fs.ErrPermission)
		return
	}
	path := r.URL.Query().Get("path")
	if path == "" && user.Role != auth.RoleAdmin {
		grant, err := a.auth.ComputerFileGrant(user.ID)
		if err != nil {
			computerFileError(w, err)
			return
		}
		if grant.Mode == "folders" {
			entries := []computerEntry{}
			for _, folder := range grant.Folders {
				if a.isProtectedComputerPath(folder.Path) {
					continue
				}
				entries = append(entries, computerEntry{Name: folder.Path, Path: folder.Path, Type: "folder"})
			}
			jsonReply(w, 200, map[string]any{"path": "", "entries": entries})
			return
		}
		if grant.Mode != "all" {
			computerFileError(w, fs.ErrPermission)
			return
		}
	}
	if path == "" {
		path = "/"
	}
	f, access, err := a.openComputerFile(r, path)
	if err != nil {
		computerFileError(w, err)
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.IsDir() {
		computerFileError(w, computerfiles.ErrPath)
		return
	}
	offset := 0
	if cursor := r.URL.Query().Get("cursor"); cursor != "" {
		offset, err = strconv.Atoi(cursor)
		if err != nil || offset < 0 || offset > 1000000 {
			computerFileError(w, computerfiles.ErrPath)
			return
		}
	}
	entries := make([]computerEntry, 0, 200)
	consumed := 0
	next := ""
	for {
		dirs, readErr := f.ReadDir(128)
		if readErr != nil && !errors.Is(readErr, io.EOF) {
			computerFileError(w, readErr)
			return
		}
		for _, dir := range dirs {
			consumed++
			if consumed <= offset {
				continue
			}
			var st unix.Stat_t
			if unix.Fstatat(int(f.Fd()), dir.Name(), &st, unix.AT_SYMLINK_NOFOLLOW) != nil {
				continue
			}
			kind := ""
			switch st.Mode & unix.S_IFMT {
			case unix.S_IFDIR:
				kind = "folder"
			case unix.S_IFREG:
				kind = "file"
			}
			if kind == "" {
				continue
			}
			childPath := filepath.Join(path, dir.Name())
			if a.isProtectedComputerPath(childPath) {
				continue
			}
			entries = append(entries, computerEntry{Name: dir.Name(), Path: childPath, Type: kind, Size: st.Size})
			if len(entries) == 200 {
				next = strconv.Itoa(consumed)
				break
			}
		}
		if next != "" || errors.Is(readErr, io.EOF) {
			break
		}
		if !access.valid() {
			computerFileError(w, fs.ErrPermission)
			return
		}
	}
	if !access.valid() {
		computerFileError(w, fs.ErrPermission)
		return
	}
	jsonReply(w, 200, map[string]any{"path": path, "entries": entries, "nextCursor": next})
}
func (a *API) computerFileContent(w http.ResponseWriter, r *http.Request) {
	a.serveComputerFile(w, r, false)
}
func (a *API) computerFilePreview(w http.ResponseWriter, r *http.Request) {
	a.serveComputerFile(w, r, true)
}
func (a *API) serveComputerFile(w http.ResponseWriter, r *http.Request, preview bool) {
	f, access, err := a.openComputerFile(r, r.URL.Query().Get("path"))
	if err != nil {
		computerFileError(w, err)
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !computerfiles.IsRegular(info) {
		computerFileError(w, computerfiles.ErrPath)
		return
	}
	mediaType := "application/octet-stream"
	if preview {
		types := map[string]string{".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png", ".gif": "image/gif", ".webp": "image/webp", ".txt": "text/plain; charset=utf-8", ".md": "text/plain; charset=utf-8", ".json": "text/plain; charset=utf-8", ".log": "text/plain; charset=utf-8", ".mp4": "video/mp4", ".webm": "video/webm", ".m4v": "video/mp4", ".pdf": "application/pdf"}
		var ok bool
		mediaType, ok = types[strings.ToLower(filepath.Ext(info.Name()))]
		if !ok || (strings.HasPrefix(mediaType, "text/") && info.Size() > 1<<20) {
			jsonReply(w, 415, map[string]string{"error": "preview_not_supported"})
			return
		}
		w.Header().Set("Content-Disposition", "inline")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; sandbox")
		w.Header().Set("X-Frame-Options", "SAMEORIGIN")
	} else {
		w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename*=UTF-8''%s", url.PathEscape(info.Name())))
	}
	w.Header().Set("Content-Type", mediaType)
	w.Header().Set("Cache-Control", "no-store")
	http.ServeContent(w, r, info.Name(), info.ModTime(), computerReader{f: f, access: access})
}

var _ io.ReadSeeker = computerReader{}
