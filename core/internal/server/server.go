package server

import (
	"encoding/json"
	"io/fs"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/backup"
	"github.com/lengsukq/lightisle/core/internal/cinema"
	"github.com/lengsukq/lightisle/core/internal/dav"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/gallery"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/system"
	"github.com/lengsukq/lightisle/core/internal/tasks"
)

type API struct {
	journal   *tasks.Journal
	collector *system.Collector
	webRoot   string
	auth      *auth.Store
	files     files.Access
	gallery   *gallery.Library
	cinema    *cinema.Library
	limiter   *loginLimiter
	backup    *backup.Service
	dav       *dav.Service
	// nil uses the process-wide file verification budget shared by v1/v2.
	fileHashSlots chan struct{}
	// afterLogin lets tests pause login between session issuance and identity
	// lookup to exercise the verified-but-unusable-session path.
	afterLogin  func()
	rootID      string
	rootLease   *roots.Lease
	rootRuntime *rootRuntime
	rootServer  *RootServer
}

func New(webRoot string, store *auth.Store, fileStore files.Access, photoLibrary ...*gallery.Library) http.Handler {
	var photos *gallery.Library
	if len(photoLibrary) > 0 {
		photos = photoLibrary[0]
	}
	return NewWithCinema(webRoot, store, fileStore, photos, nil)
}
func NewWithCinema(webRoot string, store *auth.Store, fileStore files.Access, photos *gallery.Library, films *cinema.Library, backupServices ...*backup.Service) http.Handler {
	return NewWithJournal(webRoot, store, fileStore, photos, films, nil, backupServices...)
}
func NewWithJournal(webRoot string, store *auth.Store, fileStore files.Access, photos *gallery.Library, films *cinema.Library, journal *tasks.Journal, backupServices ...*backup.Service) http.Handler {
	a := &API{collector: &system.Collector{}, webRoot: webRoot, auth: store, files: fileStore, gallery: photos, cinema: films, limiter: newLoginLimiter()}
	a.journal = journal
	if len(backupServices) > 0 {
		a.backup = backupServices[0]
	}
	// WebDAV shares the listener but authenticates with its own credentials.
	// The concrete files manager exposes State(); fakes in tests omit it and
	// DAV then reports the share root as unavailable.
	if rooter, ok := fileStore.(interface{ State() (string, bool) }); ok {
		a.dav = dav.New(store, rooter.State, fileStore.MoveToTrash)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/tasks", a.requireAdmin(a.taskList))
	mux.HandleFunc("GET /api/v1/tasks/history", a.requireAdmin(a.taskHistory))
	mux.HandleFunc("GET /api/v1/audit", a.requireAdmin(a.auditHistory))
	mux.HandleFunc("GET /api/v1/alerts", a.requireAdmin(a.alertList))
	mux.HandleFunc("POST /api/v1/alerts/{code}/acknowledge", a.requireAdmin(a.alertAcknowledge))
	mux.HandleFunc("POST /api/v1/tasks/{kind}/cancel", a.requireAdmin(a.taskCancel))
	mux.HandleFunc("POST /api/v1/tasks/{kind}/retry", a.requireAdmin(a.taskRetry))
	mux.HandleFunc("GET /api/v1/admin/uploads", a.requireAdmin(a.adminUploadList))
	mux.HandleFunc("DELETE /api/v1/admin/uploads/{id}", a.requireAdmin(a.adminUploadCancel))
	mux.HandleFunc("POST /api/v1/admin/uploads/cleanup-expired", a.requireAdmin(a.adminUploadCleanupExpired))
	mux.HandleFunc("GET /api/v1/health", a.health)
	mux.HandleFunc("GET /api/v1/auth/status", a.authStatus)
	mux.HandleFunc("POST /api/v1/auth/login", a.login)
	mux.HandleFunc("POST /api/v1/auth/logout", a.logout)
	mux.HandleFunc("POST /api/v1/auth/password", a.requireLogin(a.changeOwnPassword))
	mux.HandleFunc("GET /api/v1/auth/sessions", a.requireLogin(a.listOwnSessions))
	mux.HandleFunc("DELETE /api/v1/auth/sessions/others", a.requireLogin(a.revokeOtherSessions))
	mux.HandleFunc("DELETE /api/v1/auth/sessions/{id}", a.requireLogin(a.revokeOwnSession))
	mux.HandleFunc("GET /api/v1/auth/me", a.me)
	mux.HandleFunc("GET /api/v1/users", a.requireAdmin(a.users))
	mux.HandleFunc("POST /api/v1/users", a.requireAdmin(a.addUser))
	mux.HandleFunc("PATCH /api/v1/users/{id}", a.requireAdmin(a.changeUser))
	mux.HandleFunc("POST /api/v1/users/{id}/password", a.requireAdmin(a.resetMemberPassword))
	mux.HandleFunc("GET /api/v1/users/{id}/file-grants", a.requireAdmin(a.getFileGrants))
	mux.HandleFunc("PUT /api/v1/users/{id}/file-grants", a.requireAdmin(a.setFileGrant))
	mux.HandleFunc("DELETE /api/v1/users/{id}/file-grants", a.requireAdmin(a.deleteFileGrant))
	mux.HandleFunc("GET /api/v1/system", a.requireLogin(a.system))
	mux.HandleFunc("GET /api/v1/admin/disks", a.requireAdmin(a.diskList))
	mux.HandleFunc("GET /api/v1/admin/disks/{id}/smart", a.requireAdmin(a.diskSmart))
	mux.HandleFunc("POST /api/v1/admin/disks/actions", a.requireAdmin(a.diskAction))
	mux.HandleFunc("GET /api/v1/files", a.requireLogin(a.listFiles))
	mux.HandleFunc("GET /api/v1/files/search", a.requireLogin(a.searchFiles))
	mux.HandleFunc("POST /api/v1/files/operations", a.requireLogin(a.fileOperation))
	mux.HandleFunc("DELETE /api/v1/files/trash/{id}", a.requireAdmin(a.purgeTrash))
	mux.HandleFunc("DELETE /api/v1/files", a.requireLogin(a.trashFile))
	mux.HandleFunc("POST /api/v1/files/folders", a.requireLogin(a.mkdir))
	mux.HandleFunc("GET /api/v1/files/content", a.requireLogin(a.readFile))
	mux.HandleFunc("GET /api/v1/files/sha256", a.requireLogin(a.fileSHA256))
	mux.HandleFunc("HEAD /api/v1/files/content", a.requireLogin(a.readFile))
	mux.HandleFunc("GET /api/v1/files/archive", a.requireLogin(a.downloadFolderArchive))
	mux.HandleFunc("HEAD /api/v1/files/archive", a.requireLogin(a.downloadFolderArchive))
	mux.HandleFunc("PUT /api/v1/files/content", a.requireLogin(a.uploadFile))
	mux.HandleFunc("POST /api/v1/uploads", a.requireLogin(a.beginUpload))
	mux.HandleFunc("GET /api/v1/uploads/{id}", a.requireLogin(a.uploadStatus))
	mux.HandleFunc("PATCH /api/v1/uploads/{id}", a.requireLogin(a.uploadChunk))
	mux.HandleFunc("POST /api/v1/uploads/{id}/complete", a.requireLogin(a.uploadComplete))
	mux.HandleFunc("DELETE /api/v1/uploads/{id}", a.requireLogin(a.uploadAbort))
	mux.HandleFunc("POST /api/v1/files/batch", a.requireLogin(a.fileBatch))
	mux.HandleFunc("GET /api/v1/files/preview", a.requireLogin(a.previewFile))
	mux.HandleFunc("HEAD /api/v1/files/preview", a.requireLogin(a.previewFile))
	mux.HandleFunc("GET /api/v1/files/trash", a.requireLogin(a.listTrash))
	mux.HandleFunc("POST /api/v1/files/trash/{id}/restore", a.requireLogin(a.restoreTrash))
	mux.HandleFunc("GET /api/v1/files/root", a.requireLogin(a.fileRoot))
	mux.HandleFunc("POST /api/v1/file-shares", a.requireLogin(a.createFileShare))
	mux.HandleFunc("GET /api/v1/file-shares", a.requireLogin(a.listFileShares))
	mux.HandleFunc("DELETE /api/v1/file-shares/{id}", a.requireLogin(a.revokeFileShare))
	mux.HandleFunc("GET /api/v1/public/file/{token}", a.downloadSharedFile)
	mux.HandleFunc("HEAD /api/v1/public/file/{token}", a.downloadSharedFile)
	mux.HandleFunc("GET /api/v1/photos", a.requireMedia(a.galleryList))
	mux.HandleFunc("GET /api/v1/photos/status", a.requireMedia(a.galleryStatus))
	mux.HandleFunc("POST /api/v1/photos/scan", a.requireAdmin(a.galleryScan))
	mux.HandleFunc("GET /api/v1/photos/{id}/thumbnail", a.requireMedia(a.galleryThumbnail))
	mux.HandleFunc("POST /api/v1/photos/{id}/favorite", a.requireMedia(a.galleryFavorite))
	mux.HandleFunc("POST /api/v1/photos/{id}/personal-favorite", a.requireMedia(a.galleryPersonalFavorite))
	mux.HandleFunc("GET /api/v1/photos/albums", a.requireMedia(a.galleryAlbums))
	mux.HandleFunc("GET /api/v1/photos/private-albums", a.requireMedia(a.galleryPrivateAlbums))
	mux.HandleFunc("POST /api/v1/photos/private-albums", a.requireMedia(a.galleryCreatePrivateAlbum))
	mux.HandleFunc("PATCH /api/v1/photos/private-albums/{id}", a.requireMedia(a.galleryRenamePrivateAlbum))
	mux.HandleFunc("DELETE /api/v1/photos/private-albums/{id}", a.requireMedia(a.galleryDeletePrivateAlbum))
	mux.HandleFunc("POST /api/v1/photos/private-albums/{id}/items", a.requireMedia(a.galleryAddToPrivateAlbum))
	mux.HandleFunc("DELETE /api/v1/photos/private-albums/{id}/items/{assetID}", a.requireMedia(a.galleryRemoveFromPrivateAlbum))
	// Albums have global names and globally visible mutations, so only the
	// administrator can modify their membership or create new global albums.
	mux.HandleFunc("POST /api/v1/photos/albums", a.requireAdmin(a.galleryCreateAlbum))
	mux.HandleFunc("POST /api/v1/photos/albums/{id}/items", a.requireAdmin(a.galleryAddToAlbum))
	mux.HandleFunc("PATCH /api/v1/photos/albums/{id}", a.requireAdmin(a.galleryRenameAlbum))
	mux.HandleFunc("DELETE /api/v1/photos/albums/{id}", a.requireAdmin(a.galleryDeleteAlbum))
	mux.HandleFunc("DELETE /api/v1/photos/albums/{id}/items/{assetID}", a.requireAdmin(a.galleryRemoveFromAlbum))
	mux.HandleFunc("GET /api/v1/cinema", a.requireMedia(a.cinemaList))
	mux.HandleFunc("GET /api/v1/cinema/status", a.requireMedia(a.cinemaStatus))
	mux.HandleFunc("POST /api/v1/cinema/scan", a.requireAdmin(a.cinemaScan))
	mux.HandleFunc("GET /api/v1/cinema/{id}", a.requireMedia(a.cinemaGet))
	mux.HandleFunc("PATCH /api/v1/cinema/{id}", a.requireAdmin(a.cinemaRename))
	mux.HandleFunc("POST /api/v1/cinema/{id}/metadata/nfo", a.requireAdmin(a.cinemaImportNFO))
	mux.HandleFunc("POST /api/v1/cinema/{id}/metadata/tmdb/search", a.requireAdmin(a.cinemaTMDBSearch))
	mux.HandleFunc("POST /api/v1/cinema/{id}/metadata/tmdb/match", a.requireAdmin(a.cinemaTMDBMatch))
	mux.HandleFunc("POST /api/v1/cinema/{id}/metadata/douban/search", a.requireAdmin(a.cinemaDoubanSearch))
	mux.HandleFunc("POST /api/v1/cinema/{id}/metadata/douban/match", a.requireAdmin(a.cinemaDoubanMatch))
	mux.HandleFunc("GET /api/v1/cinema/{id}/poster", a.requireMedia(a.cinemaPoster))
	mux.HandleFunc("HEAD /api/v1/cinema/{id}/poster", a.requireMedia(a.cinemaPoster))
	mux.HandleFunc("GET /api/v1/cinema/{id}/stream", a.requireMedia(a.cinemaStream))
	mux.HandleFunc("HEAD /api/v1/cinema/{id}/stream", a.requireMedia(a.cinemaStream))
	mux.HandleFunc("GET /api/v1/cinema/{id}/subtitles", a.requireMedia(a.cinemaSubtitle))
	mux.HandleFunc("GET /api/v1/cinema/{id}/progress", a.requireMedia(a.cinemaProgress))
	mux.HandleFunc("PUT /api/v1/cinema/{id}/progress", a.requireMedia(a.cinemaSaveProgress))
	// WebDAV mounts with its own Basic-auth credential model; every method
	// (PROPFIND, PUT, LOCK, ...) matches this unscoped pattern.
	mux.Handle("/dav/", a.davEndpoint())
	mux.HandleFunc("GET /api/v1/dav/credentials", a.requireLogin(a.davCredentials))
	mux.HandleFunc("POST /api/v1/dav/credentials", a.requireLogin(a.davCredentials))
	mux.HandleFunc("DELETE /api/v1/dav/credentials/{id}", a.requireLogin(a.davCredentialDelete))
	mux.HandleFunc("/", a.static)
	return securityHeaders(a.auditMiddleware(mux))
}

// davEndpoint guards the DAV service: a missing service (files manager
// without State, unit-test fakes) is an unavailable endpoint, not a panic.
func (a *API) davEndpoint() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if a.dav == nil {
			jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "share_root_offline"})
			return
		}
		a.dav.ServeHTTP(w, r)
	})
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https://image.tmdb.org; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
		if r.Method != http.MethodGet && r.Method != http.MethodHead && !strings.HasPrefix(r.URL.Path, "/dav/") {
			// WebDAV clients authenticate per request with their own
			// credentials and cannot send the browser CSRF header. The Origin
			// check stays relevant only for cookie-authenticated surfaces.
			if r.Header.Get("X-LightIsle-Request") != "1" {
				http.Error(w, "missing application request header", http.StatusForbidden)
				return
			}
			if origin := r.Header.Get("Origin"); origin != "" && !originMatchesHost(origin, r.Host) {
				http.Error(w, "cross-origin request rejected", http.StatusForbidden)
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

func jsonReply(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Warn("json response failed", "error", err)
	}
}

func (a *API) health(w http.ResponseWriter, _ *http.Request) {
	jsonReply(w, http.StatusOK, map[string]any{
		"status": "ok", "application": "LightIsle",
		"version": "0.1.0-dev", "platform": runtime.GOOS + "/" + runtime.GOARCH,
		"timestamp": time.Now().UTC().Format(time.RFC3339),
	})
}

func (a *API) system(w http.ResponseWriter, _ *http.Request) {
	snapshot, err := a.collector.Collect()
	if err != nil {
		slog.Error("metric collection failed", "error", err)
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "metrics_unavailable"})
		return
	}
	jsonReply(w, http.StatusOK, snapshot)
}

func (a *API) static(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	// API capability probes and misspelled endpoints must never look like a
	// successful SPA response. In particular, single-root servers do not expose
	// /api/v2/roots: clients use its 404 to keep the existing v1 features usable.
	if r.URL.Path == "/api" || strings.HasPrefix(r.URL.Path, "/api/") {
		jsonReply(w, http.StatusNotFound, map[string]string{"error": "api_not_found"})
		return
	}
	if a.webRoot == "" {
		http.Error(w, "LightIsle Web assets missing: build apps/web first", http.StatusServiceUnavailable)
		return
	}
	// Join only a path relative to the static directory. Never allow a
	// URL path to resolve outside the bundled read-only frontend assets.
	clean := filepath.Clean("/" + r.URL.Path)
	relative := strings.TrimPrefix(clean, "/")
	path := filepath.Join(a.webRoot, relative)
	info, err := os.Stat(path)
	if err == nil && info.IsDir() {
		path = filepath.Join(path, "index.html")
	}
	if _, err = os.Stat(path); err != nil {
		// Only SPA routes without file extensions may use index.html.
		if strings.Contains(filepath.Base(r.URL.Path), ".") {
			http.NotFound(w, r)
			return
		}
		path = filepath.Join(a.webRoot, "index.html")
	}
	f, err := os.Open(path)
	if err != nil {
		if errorsIsNotExist(err) {
			http.NotFound(w, r)
			return
		}
		http.Error(w, "file unavailable", http.StatusInternalServerError)
		return
	}
	defer f.Close()
	s, err := f.Stat()
	if err != nil || !s.Mode().IsRegular() {
		http.NotFound(w, r)
		return
	}
	http.ServeContent(w, r, s.Name(), s.ModTime(), f)
}

func errorsIsNotExist(err error) bool   { return os.IsNotExist(err) || errorsIsFSNotExist(err) }
func errorsIsFSNotExist(err error) bool { return err == fs.ErrNotExist }
