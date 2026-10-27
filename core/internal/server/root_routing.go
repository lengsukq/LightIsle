package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/backup"
	"github.com/lengsukq/lightisle/core/internal/cinema"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/gallery"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/tasks"
)

// RootServices is the isolated set of long-lived services for one registered
// root generation. The factory must bind Files and both media libraries to the
// supplied lease, and keep all mutable indexes/caches under that root's own
// application-data directory. Backup is held for local-only task/status use;
// this server deliberately exposes no backup trigger through v2.
type RootServices struct {
	Files   files.Access
	Gallery *gallery.Library
	Cinema  *cinema.Library
	Journal *tasks.Journal
	Backup  *backup.Service
	Close   func() error
}

// ErrRootMaintenanceBusy means a user/manual scan already owns a media
// library. The scheduler must retry instead of interrupting that operation.
var ErrRootMaintenanceBusy = errors.New("root_maintenance_scan_busy")

// ReconcileRootMedia is a native-only, sequential per-root maintenance
// operation. It uses the SAME generation-bound leases and scan entrypoints
// as authenticated HTTP requests. It never follows arbitrary filesystem
// paths, changes membership grants or starts backup/restore tasks.
// A full scan after reconnect catches files missed while the disk was away.
func (s *RootServer) ReconcileRootMedia(ctx context.Context, id string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	l, err := s.AcquireRootServices(ctx, id)
	if err != nil {
		return err
	}
	defer l.Close()
	s.mu.Lock()
	rt := s.runtimes[id]
	s.mu.Unlock()
	if rt == nil || rt.root.Generation != l.Root.Generation {
		return roots.ErrStale
	}
	photos, films := l.Services.Gallery, l.Services.Cinema
	if photos == nil || films == nil {
		return errors.New("root_media_unavailable")
	}
	if photos.Status().Running || films.Status().Running {
		return ErrRootMaintenanceBusy
	}
	child := &API{rootServer: s, rootRuntime: rt, rootID: id}
	if err = child.startRootScan("gallery"); err != nil {
		if errors.Is(err, gallery.ErrBusy) {
			return ErrRootMaintenanceBusy
		}
		return err
	}
	if err = child.startRootScan("cinema"); err != nil {
		photos.CancelScan()
		if errors.Is(err, cinema.ErrScanning) {
			return ErrRootMaintenanceBusy
		}
		return err
	}
	ticker := time.NewTicker(150 * time.Millisecond)
	defer ticker.Stop()
	for {
		if ctx.Err() != nil {
			photos.CancelScan()
			films.CancelScan()
			return ctx.Err()
		}
		if !l.Lease.Valid(ctx) {
			photos.CancelScan()
			films.CancelScan()
			return roots.ErrOffline
		}
		rt.scanMu.Lock()
		running := len(rt.scans) != 0
		rt.scanMu.Unlock()
		if !running && !photos.Status().Running && !films.Status().Running {
			if photos.Status().LastError != "" || films.Status().LastError != "" {
				return errors.New("root_media_scan_failed")
			}
			return nil
		}
		select {
		case <-ctx.Done():
			photos.CancelScan()
			films.CancelScan()
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

// RootServicesFactory is invoked after the request has acquired the root. It
// receives that lease so a pinned files manager can clone its directory handle
// without resolving the pathname again.
type RootServicesFactory func(context.Context, roots.Root, *roots.Lease) (*RootServices, error)

type RootServerOptions struct {
	// EnableDiscovery adds GET /api/v2/roots. Keep false until native root
	// management, grants, backups, and the Web root selector are all wired.
	EnableDiscovery bool
	// LegacyBackup provides host-level configuration snapshot integration;
	// it is not an HTTP compatibility adapter.
	LegacyBackup *backup.Service
	// TrashRetention is the host-wide, Mac-only configurable retention
	// policy. All v2 clients read the same persisted value.
	TrashRetention *tasks.RetentionStore
}

type rootRuntime struct {
	root     roots.Root
	services *RootServices
	users    int // protected by RootServer.mu
	lastUsed time.Time
	scanMu   sync.Mutex
	scans    map[string]*roots.Lease
	scanWG   sync.WaitGroup
}

type RootServer struct {
	handler  http.Handler
	registry *roots.Registry
	factory  RootServicesFactory
	options  RootServerOptions

	mu        sync.Mutex
	closed    bool
	requests  sync.WaitGroup
	runtimes  map[string]*rootRuntime
	sweepStop chan struct{}
	sweepWG   sync.WaitGroup
}

// NewWithRoots adds root-scoped endpoints alongside the default v2 API.
// Discovery is enabled only when native root management is ready.
func NewWithRoots(
	webRoot string,
	store *auth.Store,
	fileStore files.Access,
	photos *gallery.Library,
	films *cinema.Library,
	journal *tasks.Journal,
	registry *roots.Registry,
	factory RootServicesFactory,
	options ...RootServerOptions,
) *RootServer {
	var option RootServerOptions
	if len(options) > 0 {
		option = options[0]
	}
	base := NewWithRetention(webRoot, store, fileStore, photos, films, journal, option.TrashRetention, option.LegacyBackup)
	rootAPI := &API{collector: nil, webRoot: webRoot, auth: store, files: fileStore, gallery: photos, cinema: films, journal: journal,
		limiter: newLoginLimiter(), shareGrants: newShareGrantStore(), retention: option.TrashRetention}
	s := &RootServer{registry: registry, factory: factory, options: option, runtimes: map[string]*rootRuntime{}, sweepStop: make(chan struct{})}
	rootAPI.rootServer = s
	rootMux := http.NewServeMux()
	registerRootRoutes(rootMux, rootAPI)
	rootMux.HandleFunc("POST /api/v2/storage/users/{id}/categories/{category}/abandon",
		rootAPI.requireAdmin(rootAPI.abandonRemovedStorageCategory))
	rootMux.HandleFunc("GET /api/v2/roots", func(w http.ResponseWriter, r *http.Request) {
		if !option.EnableDiscovery {
			http.NotFound(w, r)
			return
		}
		rootAPI.rootDiscoveryRequest(w, r)
	})
	// Root-scoped requests are handled above; the remaining /api/v2/
	// endpoints (authentication, settings, diagnostics, etc.) belong to the
	// global API. Do not swallow them with a catch-all 404.
	rootMux.Handle("/api/v2/", base)
	securedRoots := securityHeaders(rootAPI.auditMiddleware(rootMux))
	mux := http.NewServeMux()
	mux.Handle("/api/v2/", securedRoots)
	mux.HandleFunc("/api/v2", http.NotFound)
	mux.Handle("/", base)
	s.handler = mux
	s.sweepWG.Add(1)
	go s.sweepIdleRuntimes()
	return s
}

func (s *RootServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.handler.ServeHTTP(w, r)
}

// Close is an alias for Shutdown so the runtime can be wired into normal
// application cleanup with defer.
func (s *RootServer) Close() error { return s.Shutdown() }

// RootServicesLease exposes one root's already-isolated local services to
// trusted native lifecycle code such as the backup scheduler. The lease must
// remain open until the complete operation finishes; it is never an HTTP
// capability and does not expose root paths in responses.
type RootServicesLease struct {
	Root     roots.Root
	Lease    *roots.Lease
	Services *RootServices
	close    func()
	once     sync.Once
}

func (l *RootServicesLease) Close() error {
	if l == nil {
		return nil
	}
	var err error
	l.once.Do(func() {
		if l.Lease != nil {
			err = l.Lease.Close()
		}
		if l.close != nil {
			l.close()
		}
	})
	return err
}

// AcquireRootServices is for trusted in-process callers only. Callers must
// close the returned lease after the complete task, including asynchronous
// reads/writes, has stopped.
func (s *RootServer) AcquireRootServices(ctx context.Context, id string) (*RootServicesLease, error) {
	if s == nil || s.registry == nil || s.factory == nil {
		return nil, errors.New("root_services_unavailable")
	}
	if !s.beginRequest() {
		return nil, errors.New("root_server_closed")
	}
	lease, err := s.registry.Acquire(ctx, id)
	if err != nil {
		s.requests.Done()
		return nil, err
	}
	runtime, err := s.runtimeFor(ctx, id, lease)
	if err != nil {
		_ = lease.Close()
		s.requests.Done()
		return nil, err
	}
	return &RootServicesLease{Root: runtime.root, Lease: lease, Services: runtime.services, close: func() { s.releaseRuntime(runtime); s.requests.Done() }}, nil
}

func (s *RootServer) beginRequest() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return false
	}
	s.requests.Add(1)
	return true
}

// Shutdown stops accepting root-scoped requests, closes each root's services
// (which must cancel its background scans), and waits for scan leases to be
// released. The application should call this after stopping its HTTP server.
func (s *RootServer) Shutdown() error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return nil
	}
	s.closed = true
	close(s.sweepStop)
	runtimes := make([]*rootRuntime, 0, len(s.runtimes))
	for _, runtime := range s.runtimes {
		runtimes = append(runtimes, runtime)
	}
	s.mu.Unlock()
	for _, runtime := range runtimes {
		if runtime.services.Backup != nil {
			runtime.services.Backup.Cancel()
		}
		if runtime.services.Gallery != nil {
			runtime.services.Gallery.CancelScan()
		}
		if runtime.services.Cinema != nil {
			runtime.services.Cinema.CancelScan()
		}
	}
	s.requests.Wait()
	s.sweepWG.Wait()

	s.mu.Lock()
	runtimes = make([]*rootRuntime, 0, len(s.runtimes))
	for _, runtime := range s.runtimes {
		runtimes = append(runtimes, runtime)
	}
	s.runtimes = map[string]*rootRuntime{}
	s.mu.Unlock()

	var closeErr error
	for _, runtime := range runtimes {
		if runtime.services.Gallery != nil {
			runtime.services.Gallery.CancelScan()
		}
		if runtime.services.Cinema != nil {
			runtime.services.Cinema.CancelScan()
		}
		closeErr = errors.Join(closeErr, closeRootServices(runtime.services))
	}
	for _, runtime := range runtimes {
		runtime.scanWG.Wait()
	}
	return closeErr
}

func closeRootServices(value *RootServices) error {
	if value == nil {
		return nil
	}
	if value.Close != nil {
		return value.Close()
	}
	var result error
	if value.Backup != nil {
		value.Backup.Close()
	}
	if value.Gallery != nil {
		result = errors.Join(result, value.Gallery.Close())
	}
	if value.Cinema != nil {
		result = errors.Join(result, value.Cinema.Close())
	}
	if value.Journal != nil {
		result = errors.Join(result, value.Journal.Close())
	}
	if closer, ok := value.Files.(interface{ Close() error }); ok {
		result = errors.Join(result, closer.Close())
	}
	return result
}

func findRoot(registry *roots.Registry, id string) (roots.Root, bool) {
	if registry == nil {
		return roots.Root{}, false
	}
	for _, item := range registry.List() {
		if item.ID == id {
			return item, true
		}
	}
	return roots.Root{}, false
}

const rootRuntimeIdleTTL = 10 * time.Minute

func (s *RootServer) releaseRuntime(rt *rootRuntime) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rt.users--
	rt.lastUsed = time.Now()
}

func (s *RootServer) sweepIdleRuntimes() {
	defer s.sweepWG.Done()
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-s.sweepStop:
			return
		case now := <-ticker.C:
			_ = s.releaseIdleRuntimes(now)
		}
	}
}

// The same mutex protects checkout and retirement, so a new request cannot
// acquire a runtime after the idle check. Close only releases handles/caches;
// persisted indexes, upload journals and user files are never deleted.
func (s *RootServer) releaseIdleRuntimes(now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil
	}
	var result error
	for id, rt := range s.runtimes {
		if rt.users != 0 || now.Sub(rt.lastUsed) < rootRuntimeIdleTTL {
			continue
		}
		rt.scanMu.Lock()
		scanning := len(rt.scans) != 0
		rt.scanMu.Unlock()
		if scanning {
			continue
		}
		services := rt.services
		if services.Gallery != nil {
			status := services.Gallery.Status()
			if status.Running || (status.Backfill != nil && status.Backfill.Running) {
				continue
			}
		}
		if services.Cinema != nil && services.Cinema.InUse() {
			continue
		}
		if services.Backup != nil && services.Backup.Status().Running {
			continue
		}
		result = errors.Join(result, closeRootServices(services))
		rt.scanWG.Wait()
		delete(s.runtimes, id)
	}
	return result
}

func (s *RootServer) runtimeFor(ctx context.Context, id string, lease *roots.Lease) (*rootRuntime, error) {
	if s.registry == nil || s.factory == nil {
		return nil, errors.New("root_services_unavailable")
	}
	root, ok := findRoot(s.registry, id)
	if !ok || root.Pending {
		return nil, roots.ErrMissing
	}
	if lease == nil || lease.Binding != root.Binding {
		return nil, roots.ErrStale
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil, errors.New("root_server_closed")
	}
	if current := s.runtimes[id]; current != nil && current.root.Generation == root.Generation {
		current.users++
		return current, nil
	}
	if current := s.runtimes[id]; current != nil {
		if err := closeRootServices(current.services); err != nil {
			return nil, err
		}
		delete(s.runtimes, id)
	}
	services, err := s.factory(ctx, root, lease)
	if err != nil {
		return nil, err
	}
	if services == nil {
		return nil, errors.New("root_services_unavailable")
	}
	if !lease.Valid(ctx) {
		_ = closeRootServices(services)
		return nil, roots.ErrStale
	}
	current := &rootRuntime{root: root, services: services, users: 1, lastUsed: time.Now(), scans: map[string]*roots.Lease{}}
	s.runtimes[id] = current
	return current, nil
}

type rootGuard uint8

const (
	rootLogin rootGuard = iota
	rootMedia
	rootAdmin
	rootTraverse
	rootPublic
)

func rootHandler(base *API, method func(*API) http.HandlerFunc, guard rootGuard) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		api, release := rootAPIForRequest(w, r, base, guard == rootPublic)
		if api == nil {
			return
		}
		defer release()
		var next http.HandlerFunc = method(api)
		switch guard {
		case rootMedia:
			next = api.requireMedia(next)
		case rootAdmin:
			next = api.requireAdmin(next)
		case rootTraverse:
			next = api.requireRootTraverse(next)
		case rootPublic:
			// A capability URL has its own authorization in the handler.
		case rootLogin:
			next = api.requireLogin(next)
		}
		next(w, r)
	}
}

func rootAPIForRequest(w http.ResponseWriter, r *http.Request, base *API, public bool) (*API, func()) {
	return rootLeaseForRequest(w, r, base, public)
}

func registerRootRoutes(mux *http.ServeMux, api *API) {
	file := func(method func(*API) http.HandlerFunc) http.HandlerFunc { return rootHandler(api, method, rootLogin) }
	media := func(method func(*API) http.HandlerFunc) http.HandlerFunc { return rootHandler(api, method, rootMedia) }
	admin := func(method func(*API) http.HandlerFunc) http.HandlerFunc { return rootHandler(api, method, rootAdmin) }
	traverse := func(method func(*API) http.HandlerFunc) http.HandlerFunc {
		return rootHandler(api, method, rootTraverse)
	}
	public := func(method func(*API) http.HandlerFunc) http.HandlerFunc { return rootHandler(api, method, rootPublic) }

	const base = "/api/v2/roots/{rootID}"
	mux.HandleFunc("GET "+base+"/files", file(func(a *API) http.HandlerFunc { return a.listFiles }))
	mux.HandleFunc("GET "+base+"/files/search", file(func(a *API) http.HandlerFunc { return a.searchFiles }))
	mux.HandleFunc("POST "+base+"/files/operations", file(func(a *API) http.HandlerFunc { return a.fileOperation }))
	mux.HandleFunc("DELETE "+base+"/files/trash/{id}", admin(func(a *API) http.HandlerFunc { return a.purgeTrash }))
	mux.HandleFunc("DELETE "+base+"/files", file(func(a *API) http.HandlerFunc { return a.trashFile }))
	mux.HandleFunc("POST "+base+"/files/folders", file(func(a *API) http.HandlerFunc { return a.mkdir }))
	mux.HandleFunc("GET "+base+"/files/content", file(func(a *API) http.HandlerFunc { return a.readFile }))
	mux.HandleFunc("GET "+base+"/files/sha256", file(func(a *API) http.HandlerFunc { return a.fileSHA256 }))
	mux.HandleFunc("HEAD "+base+"/files/content", file(func(a *API) http.HandlerFunc { return a.readFile }))
	mux.HandleFunc("GET "+base+"/files/archive", file(func(a *API) http.HandlerFunc { return a.downloadFolderArchive }))
	mux.HandleFunc("HEAD "+base+"/files/archive", file(func(a *API) http.HandlerFunc { return a.downloadFolderArchive }))
	mux.HandleFunc("PUT "+base+"/files/content", file(func(a *API) http.HandlerFunc { return a.uploadFile }))
	mux.HandleFunc("POST "+base+"/uploads", file(func(a *API) http.HandlerFunc { return a.beginUpload }))
	mux.HandleFunc("GET "+base+"/uploads/{id}", file(func(a *API) http.HandlerFunc { return a.uploadStatus }))
	mux.HandleFunc("PATCH "+base+"/uploads/{id}", file(func(a *API) http.HandlerFunc { return a.uploadChunk }))
	mux.HandleFunc("POST "+base+"/uploads/{id}/complete", file(func(a *API) http.HandlerFunc { return a.uploadComplete }))
	mux.HandleFunc("DELETE "+base+"/uploads/{id}", file(func(a *API) http.HandlerFunc { return a.uploadAbort }))
	mux.HandleFunc("GET "+base+"/admin/uploads", admin(func(a *API) http.HandlerFunc { return a.adminUploadList }))
	mux.HandleFunc("DELETE "+base+"/admin/uploads/{id}", admin(func(a *API) http.HandlerFunc { return a.adminUploadCancel }))
	mux.HandleFunc("POST "+base+"/admin/uploads/cleanup-expired", admin(func(a *API) http.HandlerFunc { return a.adminUploadCleanupExpired }))
	mux.HandleFunc("POST "+base+"/files/batch", file(func(a *API) http.HandlerFunc { return a.fileBatch }))
	mux.HandleFunc("GET "+base+"/files/preview", file(func(a *API) http.HandlerFunc { return a.previewFile }))
	mux.HandleFunc("GET "+base+"/files/thumbnail", file(func(a *API) http.HandlerFunc { return a.fileThumbnail }))
	mux.HandleFunc("HEAD "+base+"/files/preview", file(func(a *API) http.HandlerFunc { return a.previewFile }))
	mux.HandleFunc("HEAD "+base+"/files/thumbnail", file(func(a *API) http.HandlerFunc { return a.fileThumbnail }))
	mux.HandleFunc("GET "+base+"/files/trash", file(func(a *API) http.HandlerFunc { return a.listTrash }))
	// The setting is global, not a per-root override. Preserve this v2
	// compatibility endpoint for clients that scope every files-page URL.
	mux.HandleFunc("GET "+base+"/trash/retention", file(func(a *API) http.HandlerFunc { return a.trashRetention }))
	mux.HandleFunc("POST "+base+"/files/trash/{id}/restore", file(func(a *API) http.HandlerFunc { return a.restoreTrash }))
	mux.HandleFunc("GET "+base+"/files/root", traverse(func(a *API) http.HandlerFunc { return a.fileRoot }))
	mux.HandleFunc("POST "+base+"/file-shares", file(func(a *API) http.HandlerFunc { return a.createFileShare }))
	mux.HandleFunc("GET "+base+"/file-shares", file(func(a *API) http.HandlerFunc { return a.listFileShares }))
	mux.HandleFunc("DELETE "+base+"/file-shares/{id}", file(func(a *API) http.HandlerFunc { return a.revokeFileShare }))
	mux.HandleFunc("GET "+base+"/public/file/{token}", public(func(a *API) http.HandlerFunc { return a.downloadSharedFile }))
	mux.HandleFunc("HEAD "+base+"/public/file/{token}", public(func(a *API) http.HandlerFunc { return a.downloadSharedFile }))
	mux.HandleFunc("POST "+base+"/public/file/{token}", public(func(a *API) http.HandlerFunc { return a.downloadSharedFile }))

	mux.HandleFunc("GET "+base+"/photos", media(func(a *API) http.HandlerFunc { return a.galleryList }))
	mux.HandleFunc("GET "+base+"/photos/status", media(func(a *API) http.HandlerFunc { return a.galleryStatus }))
	mux.HandleFunc("GET "+base+"/photos/geo", media(func(a *API) http.HandlerFunc { return a.galleryGeo }))
	mux.HandleFunc("GET "+base+"/photos/timeline", media(func(a *API) http.HandlerFunc { return a.galleryTimeline }))
	mux.HandleFunc("POST "+base+"/photos/scan", admin(func(a *API) http.HandlerFunc { return a.galleryScan }))
	mux.HandleFunc("GET "+base+"/photos/{id}/thumbnail", media(func(a *API) http.HandlerFunc { return a.galleryThumbnail }))
	mux.HandleFunc("POST "+base+"/photos/{id}/favorite", media(func(a *API) http.HandlerFunc { return a.galleryFavorite }))
	mux.HandleFunc("POST "+base+"/photos/{id}/personal-favorite", media(func(a *API) http.HandlerFunc { return a.galleryPersonalFavorite }))
	mux.HandleFunc("GET "+base+"/photos/albums", media(func(a *API) http.HandlerFunc { return a.galleryAlbums }))
	mux.HandleFunc("GET "+base+"/photos/private-albums", media(func(a *API) http.HandlerFunc { return a.galleryPrivateAlbums }))
	mux.HandleFunc("POST "+base+"/photos/private-albums", media(func(a *API) http.HandlerFunc { return a.galleryCreatePrivateAlbum }))
	mux.HandleFunc("PATCH "+base+"/photos/private-albums/{id}", media(func(a *API) http.HandlerFunc { return a.galleryRenamePrivateAlbum }))
	mux.HandleFunc("DELETE "+base+"/photos/private-albums/{id}", media(func(a *API) http.HandlerFunc { return a.galleryDeletePrivateAlbum }))
	mux.HandleFunc("POST "+base+"/photos/private-albums/{id}/items", media(func(a *API) http.HandlerFunc { return a.galleryAddToPrivateAlbum }))
	mux.HandleFunc("DELETE "+base+"/photos/private-albums/{id}/items/{assetID}", media(func(a *API) http.HandlerFunc { return a.galleryRemoveFromPrivateAlbum }))
	mux.HandleFunc("POST "+base+"/photos/albums", admin(func(a *API) http.HandlerFunc { return a.galleryCreateAlbum }))
	mux.HandleFunc("POST "+base+"/photos/albums/{id}/items", admin(func(a *API) http.HandlerFunc { return a.galleryAddToAlbum }))
	mux.HandleFunc("PATCH "+base+"/photos/albums/{id}", admin(func(a *API) http.HandlerFunc { return a.galleryRenameAlbum }))
	mux.HandleFunc("DELETE "+base+"/photos/albums/{id}", admin(func(a *API) http.HandlerFunc { return a.galleryDeleteAlbum }))
	mux.HandleFunc("DELETE "+base+"/photos/albums/{id}/items/{assetID}", admin(func(a *API) http.HandlerFunc { return a.galleryRemoveFromAlbum }))

	mux.HandleFunc("GET "+base+"/cinema", media(func(a *API) http.HandlerFunc { return a.cinemaList }))
	mux.HandleFunc("GET "+base+"/cinema/status", media(func(a *API) http.HandlerFunc { return a.cinemaStatus }))
	mux.HandleFunc("POST "+base+"/cinema/scan", admin(func(a *API) http.HandlerFunc { return a.cinemaScan }))
	mux.HandleFunc("GET "+base+"/cinema/{id}", media(func(a *API) http.HandlerFunc { return a.cinemaGet }))
	mux.HandleFunc("PATCH "+base+"/cinema/{id}", admin(func(a *API) http.HandlerFunc { return a.cinemaRename }))
	mux.HandleFunc("POST "+base+"/cinema/{id}/metadata/nfo", admin(func(a *API) http.HandlerFunc { return a.cinemaImportNFO }))
	mux.HandleFunc("POST "+base+"/cinema/{id}/metadata/tmdb/search", admin(func(a *API) http.HandlerFunc { return a.cinemaTMDBSearch }))
	mux.HandleFunc("POST "+base+"/cinema/{id}/metadata/tmdb/match", admin(func(a *API) http.HandlerFunc { return a.cinemaTMDBMatch }))
	mux.HandleFunc("POST "+base+"/cinema/{id}/metadata/douban/search", admin(func(a *API) http.HandlerFunc { return a.cinemaDoubanSearch }))
	mux.HandleFunc("POST "+base+"/cinema/{id}/metadata/douban/match", admin(func(a *API) http.HandlerFunc { return a.cinemaDoubanMatch }))
	mux.HandleFunc("GET "+base+"/cinema/{id}/poster", media(func(a *API) http.HandlerFunc { return a.cinemaPoster }))
	mux.HandleFunc("HEAD "+base+"/cinema/{id}/poster", media(func(a *API) http.HandlerFunc { return a.cinemaPoster }))
	mux.HandleFunc("GET "+base+"/cinema/{id}/stream", media(func(a *API) http.HandlerFunc { return a.cinemaStream }))
	mux.HandleFunc("HEAD "+base+"/cinema/{id}/stream", media(func(a *API) http.HandlerFunc { return a.cinemaStream }))
	mux.HandleFunc("GET "+base+"/cinema/{id}/subtitles", media(func(a *API) http.HandlerFunc { return a.cinemaSubtitle }))
	mux.HandleFunc("GET "+base+"/cinema/{id}/progress", media(func(a *API) http.HandlerFunc { return a.cinemaProgress }))
	mux.HandleFunc("PUT "+base+"/cinema/{id}/progress", media(func(a *API) http.HandlerFunc { return a.cinemaSaveProgress }))
	mux.HandleFunc("GET "+base+"/cinema/transcode/status", media(func(a *API) http.HandlerFunc { return a.cinemaTranscodeStatus }))
	mux.HandleFunc("GET "+base+"/cinema/{id}/hls/session", media(func(a *API) http.HandlerFunc { return a.cinemaHLSSession }))
	mux.HandleFunc("GET "+base+"/cinema/{id}/hls/{session}/{file}", media(func(a *API) http.HandlerFunc { return a.cinemaHLSFile }))
	mux.HandleFunc("GET "+base+"/cinema/{id}/tracks", media(func(a *API) http.HandlerFunc { return a.cinemaTracks }))
	mux.HandleFunc("GET "+base+"/cinema/{id}/embedded-subtitles", media(func(a *API) http.HandlerFunc { return a.cinemaEmbeddedSubtitle }))
	mux.HandleFunc("GET "+base+"/series", media(func(a *API) http.HandlerFunc { return a.cinemaSeriesList }))
	mux.HandleFunc("GET "+base+"/series/{id}", media(func(a *API) http.HandlerFunc { return a.cinemaSeriesGet }))
	mux.HandleFunc("POST "+base+"/series/{id}/metadata/tmdb/match", admin(func(a *API) http.HandlerFunc { return a.cinemaSeriesTMDBMatch }))
	mux.HandleFunc("POST "+base+"/cinema/scrape/start", admin(func(a *API) http.HandlerFunc { return a.cinemaScrapeStart }))
	mux.HandleFunc("GET "+base+"/cinema/scrape/status", admin(func(a *API) http.HandlerFunc { return a.cinemaScrapeStatus }))
	mux.HandleFunc("GET "+base+"/cinema/history", media(func(a *API) http.HandlerFunc { return a.cinemaHistory }))
	mux.HandleFunc("DELETE "+base+"/cinema/history", media(func(a *API) http.HandlerFunc { return a.cinemaClearHistory }))
	mux.HandleFunc("POST "+base+"/cinema/{id}/watched", media(func(a *API) http.HandlerFunc { return a.cinemaMarkWatched }))

	mux.HandleFunc("GET "+base+"/tasks", admin(func(a *API) http.HandlerFunc { return a.taskList }))
	mux.HandleFunc("GET "+base+"/tasks/history", admin(func(a *API) http.HandlerFunc { return a.taskHistory }))
	mux.HandleFunc("POST "+base+"/tasks/{kind}/cancel", admin(func(a *API) http.HandlerFunc { return a.taskCancel }))
	mux.HandleFunc("POST "+base+"/tasks/{kind}/retry", admin(func(a *API) http.HandlerFunc { return a.taskRetry }))
	mux.HandleFunc("GET "+base+"/alerts", admin(func(a *API) http.HandlerFunc { return a.alertList }))
	mux.HandleFunc("POST "+base+"/alerts/{code}/acknowledge", admin(func(a *API) http.HandlerFunc { return a.alertAcknowledge }))
	mux.HandleFunc("GET "+base+"/users/{userID}/file-grants", admin(func(a *API) http.HandlerFunc { return a.rootFileGrants }))
	mux.HandleFunc("PUT "+base+"/users/{userID}/file-grants", admin(func(a *API) http.HandlerFunc { return a.rootSetFileGrant }))
	mux.HandleFunc("DELETE "+base+"/users/{userID}/file-grants", admin(func(a *API) http.HandlerFunc { return a.rootDeleteFileGrant }))
	mux.HandleFunc("PUT "+base+"/users/{userID}/storage/{category}", admin(func(a *API) http.HandlerFunc { return a.assignUserStorageRoot }))
	mux.HandleFunc("GET "+base+"/storage/users/{userID}/usage-check", admin(func(a *API) http.HandlerFunc { return a.checkStorageLiveUsage }))

}

func rootError(w http.ResponseWriter, err error) {
	if errors.Is(err, roots.ErrMissing) {
		jsonReply(w, http.StatusNotFound, map[string]string{"error": "root_not_found"})
		return
	}
	if errors.Is(err, roots.ErrOffline) || errors.Is(err, roots.ErrStale) {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "root_unavailable"})
		return
	}
	jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "root_services_unavailable"})
}

func rootLeaseForRequest(w http.ResponseWriter, r *http.Request, api *API, public bool) (*API, func()) {
	s := api.rootServer
	if s == nil || s.registry == nil || !s.beginRequest() {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "root_services_unavailable"})
		return nil, nil
	}
	var finish sync.Once
	var inUse *rootRuntime
	endRequest := func() {
		finish.Do(func() {
			if inUse != nil {
				s.releaseRuntime(inUse)
			}
			s.requests.Done()
		})
	}
	if !public && (api.auth == nil || !api.auth.Session(token(r))) {
		endRequest()
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return nil, nil
	}
	rootID := r.PathValue("rootID")
	if !public && !api.auth.CanSeeRoot(token(r), rootID, ".") {
		endRequest()
		rootError(w, roots.ErrMissing)
		return nil, nil
	}
	if public {
		if api.auth == nil {
			endRequest()
			http.NotFound(w, r)
			return nil, nil
		}
		access, resolveErr := api.auth.ResolveRootFileShare(r.PathValue("token"))
		if resolveErr != nil || access.RootID != rootID {
			endRequest()
			http.NotFound(w, r)
			return nil, nil
		}
	}
	lease, err := s.registry.Acquire(r.Context(), rootID)
	if err != nil {
		endRequest()
		if public {
			http.NotFound(w, r)
			return nil, nil
		}
		rootError(w, err)
		return nil, nil
	}
	if !public {
		root, ok := findRoot(s.registry, rootID)
		if !ok {
			_ = lease.Close()
			endRequest()
			rootError(w, roots.ErrMissing)
			return nil, nil
		}
		if !rootGenerationMatches(w, r, root.Generation) {
			_ = lease.Close()
			endRequest()
			return nil, nil
		}
	}
	runtime, err := s.runtimeFor(r.Context(), rootID, lease)
	if err != nil {
		_ = lease.Close()
		endRequest()
		if public {
			http.NotFound(w, r)
			return nil, nil
		}
		rootError(w, err)
		return nil, nil
	}
	inUse = runtime
	if public {
		access, resolveErr := api.auth.ResolveRootFileShare(r.PathValue("token"))
		if resolveErr != nil || access.RootID != rootID || access.RootGeneration != runtime.root.Generation {
			_ = lease.Close()
			endRequest()
			http.NotFound(w, r)
			return nil, nil
		}
	}
	if !lease.Valid(r.Context()) {
		_ = lease.Close()
		endRequest()
		rootError(w, roots.ErrStale)
		return nil, nil
	}
	child := *api
	child.rootID = rootID
	child.rootLease = lease
	child.rootRuntime = runtime
	child.files = runtime.services.Files
	child.gallery = runtime.services.Gallery
	child.cinema = runtime.services.Cinema
	child.journal = runtime.services.Journal
	return &child, func() {
		_ = lease.Close()
		endRequest()
	}
}

const rootGenerationHeader = "X-LightIsle-Root-Generation"

func rootRequestMutates(method string) bool {
	switch method {
	case http.MethodGet, http.MethodHead, http.MethodOptions:
		return false
	default:
		return true
	}
}

func rootGenerationMatches(w http.ResponseWriter, r *http.Request, current uint64) bool {
	headerValues := r.Header.Values(rootGenerationHeader)
	queryValues, queryPresent := r.URL.Query()["rootGeneration"]
	mutating := rootRequestMutates(r.Method)
	if mutating && len(headerValues) == 0 {
		jsonReply(w, http.StatusPreconditionRequired, map[string]string{"error": "root_generation_required"})
		return false
	}
	if len(headerValues) > 1 || (queryPresent && len(queryValues) != 1) {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_root_generation"})
		return false
	}
	values := make([]string, 0, 2)
	if len(headerValues) == 1 {
		values = append(values, headerValues[0])
	}
	if queryPresent {
		values = append(values, queryValues[0])
	}
	for _, provided := range values {
		generation, err := strconv.ParseUint(provided, 10, 64)
		if err != nil || generation == 0 {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_root_generation"})
			return false
		}
		if generation != current {
			jsonReply(w, http.StatusConflict, map[string]string{"error": "root_generation_changed"})
			return false
		}
	}
	return true
}

func (a *API) requireRootTraverse(next http.HandlerFunc) http.HandlerFunc {
	return a.requireLogin(func(w http.ResponseWriter, r *http.Request) {
		if a.auth == nil || !a.auth.CanAccessRoot(token(r), a.rootID, ".", false, true) {
			jsonReply(w, http.StatusForbidden, map[string]string{"error": "file_permission_denied"})
			return
		}
		next(w, r)
	})
}

func (a *API) rootDiscovery(w http.ResponseWriter, r *http.Request) {
	if a.rootServer == nil || a.rootServer.registry == nil {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "root_services_unavailable"})
		return
	}
	if a.auth == nil || !a.auth.Session(token(r)) {
		jsonReply(w, http.StatusUnauthorized, map[string]string{"error": "authentication_required"})
		return
	}
	items := a.rootServer.registry.List()
	out := make([]map[string]any, 0, len(items))
	for _, item := range items {
		if !a.auth.CanSeeRoot(token(r), item.ID, ".") {
			continue
		}
		online := false
		lease, err := a.rootServer.registry.Acquire(r.Context(), item.ID)
		if err == nil {
			online = true
			_ = lease.Close()
		}
		out = append(out, map[string]any{
			"rootID": item.ID, "name": item.Name, "generation": item.Generation,
			"online": online,
		})
	}
	jsonReply(w, http.StatusOK, map[string]any{"roots": out})
}

func (a *API) rootDiscoveryRequest(w http.ResponseWriter, r *http.Request) {
	if a.rootServer == nil || !a.rootServer.beginRequest() {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "root_services_unavailable"})
		return
	}
	defer a.rootServer.requests.Done()
	a.rootDiscovery(w, r)
}

func (a *API) rootFileGrants(w http.ResponseWriter, r *http.Request) {
	userID, ok := rootGrantUserID(w, r)
	if !ok {
		return
	}
	grants, err := a.auth.RootGrants(token(r), userID, a.rootID)
	if err != nil {
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "cannot_list_grants"})
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"grants": grants})
}

func (a *API) rootSetFileGrant(w http.ResponseWriter, r *http.Request) {
	userID, ok := rootGrantUserID(w, r)
	if !ok {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 2048)
	defer r.Body.Close()
	var request struct {
		Path     string `json:"path"`
		CanWrite bool   `json:"canWrite"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil || a.files == nil {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	if _, _, err := a.files.Page(request.Path, "", 1); err != nil {
		fileError(w, err)
		return
	}
	if err := a.auth.SetRootGrant(token(r), userID, a.rootID, request.Path, request.CanWrite); err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, auth.ErrForbidden) {
			status = http.StatusForbidden
		}
		jsonReply(w, status, map[string]string{"error": "invalid_grant"})
		return
	}
	jsonReply(w, http.StatusOK, map[string]bool{"saved": true})
}

func (a *API) rootDeleteFileGrant(w http.ResponseWriter, r *http.Request) {
	userID, ok := rootGrantUserID(w, r)
	if !ok {
		return
	}
	if err := a.auth.RemoveRootGrant(token(r), userID, a.rootID, r.URL.Query().Get("path")); err != nil {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_grant"})
		return
	}
	jsonReply(w, http.StatusOK, map[string]bool{"removed": true})
}

func rootGrantUserID(w http.ResponseWriter, r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("userID"), 10, 64)
	if err != nil || id <= 0 {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_user"})
		return 0, false
	}
	return id, true
}

func (a *API) startRootScan(kind string) error {
	if a.rootServer == nil || a.rootRuntime == nil || a.rootID == "" {
		return errors.New("root_scan_unavailable")
	}
	runtime := a.rootRuntime
	runtime.scanMu.Lock()
	defer runtime.scanMu.Unlock()
	if existing := runtime.scans[kind]; existing != nil {
		if kind == "gallery" {
			return gallery.ErrBusy
		}
		return cinema.ErrScanning
	}
	lease, err := a.rootServer.registry.Acquire(context.Background(), a.rootID)
	if err != nil {
		if kind == "gallery" {
			return gallery.ErrUnavailable
		}
		return cinema.ErrOffline
	}
	var startErr error
	var status func() bool
	switch kind {
	case "gallery":
		if runtime.services.Gallery == nil {
			startErr = gallery.ErrUnavailable
		} else {
			startErr = runtime.services.Gallery.StartScan()
			status = func() bool { return runtime.services.Gallery.Status().Running }
		}
	case "cinema":
		if runtime.services.Cinema == nil {
			startErr = cinema.ErrOffline
		} else {
			startErr = runtime.services.Cinema.StartScan()
			status = func() bool { return runtime.services.Cinema.Status().Running }
		}
	default:
		startErr = errors.New("invalid_scan_kind")
	}
	if startErr != nil {
		_ = lease.Close()
		return startErr
	}
	runtime.scans[kind] = lease
	runtime.scanWG.Add(1)
	go func() {
		defer runtime.scanWG.Done()
		ticker := time.NewTicker(50 * time.Millisecond)
		defer ticker.Stop()
		for status != nil && status() {
			<-ticker.C
		}
		runtime.scanMu.Lock()
		if runtime.scans[kind] == lease {
			delete(runtime.scans, kind)
			_ = lease.Close()
		}
		runtime.scanMu.Unlock()
	}()
	return nil
}
