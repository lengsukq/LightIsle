package server

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/backup"
	"github.com/lengsukq/lightisle/core/internal/cinema"
	"github.com/lengsukq/lightisle/core/internal/dav"
	"github.com/lengsukq/lightisle/core/internal/downloads"
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
	Files              files.Access
	Gallery            *gallery.Library
	Cinema             *cinema.Library
	GalleryUnavailable bool
	CinemaUnavailable  bool
	Journal            *tasks.Journal
	Backup             *backup.Service
	Close              func() error
}

// SetTMDBToken propagates the owner's private token to all live root-scoped
// cinema libraries and to every future lazily constructed root runtime.
func (s *RootServer) SetTMDBToken(token string) error {
	if len(token) < 20 || len(token) > 2048 || strings.TrimSpace(token) != token ||
		strings.ContainsAny(token, "\r\n\t ") {
		return cinema.ErrInvalid
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return errors.New("root_server_closed")
	}
	s.tmdbToken = token
	for _, rt := range s.runtimes {
		if rt.services.Cinema != nil {
			_ = rt.services.Cinema.SetTMDBToken(token)
		}
	}
	return nil
}

func (s *RootServer) ClearTMDBToken() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.tmdbToken = ""
	for _, rt := range s.runtimes {
		if rt.services.Cinema != nil {
			rt.services.Cinema.ClearTMDBToken()
		}
	}
}

func (s *RootServer) TMDBTokenConfigured() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.tmdbToken != ""
}

// ErrRootMaintenanceBusy means a user/manual scan already owns a media
// library. The scheduler must retry instead of interrupting that operation.
var ErrRootMaintenanceBusy = errors.New("root_maintenance_scan_busy")
var ErrRootMediaUnavailable = errors.New("root_media_unavailable")

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
		child := &API{rootServer: s, rootRuntime: rt, rootID: id}
		switch {
		case photos != nil:
			err = child.startRootScan("gallery")
		case films != nil:
			err = child.startRootScan("cinema")
		}
		if errors.Is(err, gallery.ErrBusy) || errors.Is(err, cinema.ErrScanning) {
			return ErrRootMaintenanceBusy
		}
		return errors.Join(ErrRootMediaUnavailable, err)
	}
	films.CancelScrapeIfRunning()
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
	// DownloadCenter publishes through a RootRegistry-backed publisher.
	DownloadCenter *downloads.Manager
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
	accounts *auth.Store
	registry *roots.Registry
	factory  RootServicesFactory
	options  RootServerOptions

	mu             sync.Mutex
	closed         bool
	duplicateScans *duplicateScanStore
	// Native Keychain sends this secret over the local IPC pipe; it never
	// enters the registry JSON or an HTTP response.
	tmdbToken          string
	requests           sync.WaitGroup
	runtimes           map[string]*rootRuntime
	initializing       map[string]chan struct{}
	sweepStop          chan struct{}
	sweepWG            sync.WaitGroup
	mediaRefreshTimers map[string]*time.Timer
	mediaRefreshScopes map[string]map[string]struct{}

	switchMu     sync.Mutex
	switchCancel context.CancelFunc
	switchTaskID string
	switchStepUp switchStepUpStore
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
	base := NewWithDownloads(webRoot, store, fileStore, photos, films, journal, option.TrashRetention, option.DownloadCenter, option.LegacyBackup)
	rootAPI := &API{collector: nil, webRoot: webRoot, auth: store, files: fileStore, gallery: photos, cinema: films, journal: journal,
		limiter: newLoginLimiter(), shareGrants: newShareGrantStore(), duplicateScans: newDuplicateScanStore(), retention: option.TrashRetention, downloads: option.DownloadCenter}
	s := &RootServer{registry: registry, factory: factory, accounts: store, options: option, duplicateScans: rootAPI.duplicateScans, runtimes: map[string]*rootRuntime{}, initializing: map[string]chan struct{}{}, sweepStop: make(chan struct{})}
	rootAPI.rootServer = s
	rootMux := http.NewServeMux()
	registerComputerFiles(rootMux, rootAPI)
	registerRootRoutes(rootMux, rootAPI)
	rootMux.HandleFunc("POST /api/v2/storage/users/{id}/categories/{category}/abandon",
		rootAPI.requireAdmin(rootAPI.abandonRemovedStorageCategory))
	rootMux.HandleFunc("POST /api/v2/storage/users/{id}/roots/{rootID}/abandon",
		rootAPI.requireAdmin(rootAPI.abandonRemovedStorageRoot))
	rootMux.HandleFunc("POST /api/v2/users/{id}/storage/switch-root",
		rootAPI.requireAdmin(rootAPI.switchUserStorageRoot))
	// Path-only grants and public share URLs belong to the retired single-root
	// model. Never issue or accept them against whichever registered disk
	// happens to be the new default; each operation must name rootID.
	retiredSingleRoot := func(w http.ResponseWriter, r *http.Request) {
		jsonReply(w, http.StatusGone, map[string]string{"error": "registered_root_required"})
	}
	rootMux.HandleFunc("GET /api/v2/users/{id}/file-grants", retiredSingleRoot)
	rootMux.HandleFunc("PUT /api/v2/users/{id}/file-grants", retiredSingleRoot)
	rootMux.HandleFunc("DELETE /api/v2/users/{id}/file-grants", retiredSingleRoot)
	rootMux.HandleFunc("GET /api/v2/public/file/{token}", retiredSingleRoot)
	rootMux.HandleFunc("HEAD /api/v2/public/file/{token}", retiredSingleRoot)
	rootMux.HandleFunc("POST /api/v2/public/file/{token}", retiredSingleRoot)
	rootMux.HandleFunc("GET /api/v2/roots", func(w http.ResponseWriter, r *http.Request) {
		if !option.EnableDiscovery {
			http.NotFound(w, r)
			return
		}
		rootAPI.rootDiscoveryRequest(w, r)
	})
	rootMux.HandleFunc("GET /api/v2/downloads/status", rootAPI.requireLogin(rootAPI.downloadStatus))
	rootMux.HandleFunc("GET /api/v2/downloads", rootAPI.requireLogin(rootAPI.downloadList))
	rootMux.HandleFunc("POST /api/v2/downloads", rootAPI.requireAdmin(rootAPI.downloadCreate))
	rootMux.HandleFunc("POST /api/v2/downloads/{id}/actions", rootAPI.requireLogin(rootAPI.downloadAction))
	rootMux.HandleFunc("DELETE /api/v2/downloads/{id}", rootAPI.requireLogin(rootAPI.downloadDelete))
	rootMux.HandleFunc("GET /api/v2/cache/status", rootAPI.requireLogin(rootAPI.cacheStatus))
	rootMux.HandleFunc("POST /api/v2/admin/cache/clear", rootAPI.requireAdmin(rootAPI.adminCacheClear))
	// Root-scoped requests are handled above; the remaining /api/v2/
	// endpoints (authentication, settings, diagnostics, etc.) belong to the
	// global API. Do not swallow them with a catch-all 404.
	// Default file/media routes are aliases of the physical RootRegistry
	// selection. They must never address the old independently mutable share.
	rootMux.Handle("/api/v2/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !defaultRootMediaRoute(r.URL.Path) {
			base.ServeHTTP(w, r)
			return
		}
		selected, ok := registry.Default()
		if !ok {
			jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "default_root_not_configured"})
			return
		}
		forwarded := r.Clone(r.Context())
		forwarded.URL.Path = "/api/v2/roots/" + selected.ID + strings.TrimPrefix(r.URL.Path, "/api/v2")
		forwarded.URL.RawPath = ""
		forwarded.Header.Set("X-LightIsle-Root-Generation", strconv.FormatUint(selected.Generation, 10))
		rootMux.ServeHTTP(w, forwarded)
	}))
	securedRoots := securityHeaders(rootAPI.auditMiddleware(rootMux))
	mux := http.NewServeMux()
	mux.Handle("/api/v2/", securedRoots)
	mux.HandleFunc("/api/v2", http.NotFound)
	registryDAV := securityHeaders(dav.NewRootRegistry(store, registry, s.QueueNativeRootRefreshDirs))
	mux.Handle("/dav-roots/", registryDAV)
	mux.Handle("/dav/", registryDAV)
	mux.Handle("/dav", registryDAV)
	mux.Handle("/", base)
	s.handler = mux
	s.sweepWG.Add(1)
	go s.sweepIdleRuntimes()
	return s
}

func defaultRootMediaRoute(path string) bool {
	if !strings.HasPrefix(path, "/api/v2/") {
		return false
	}
	suffix := strings.TrimPrefix(path, "/api/v2/")
	// Only the media scan controls use the selected physical root. Host-wide
	// task and history endpoints must retain configuration backups, cleanup
	// and audit records when the default disk changes.
	if suffix == "tasks/gallery/retry" || suffix == "tasks/gallery/cancel" ||
		suffix == "tasks/cinema/retry" || suffix == "tasks/cinema/cancel" {
		return true
	}
	for _, prefix := range []string{"files", "photos", "cinema", "series", "uploads", "file-shares", "admin/uploads"} {
		if suffix == prefix || strings.HasPrefix(suffix, prefix+"/") {
			return true
		}
	}
	return false
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
	for _, timer := range s.mediaRefreshTimers {
		timer.Stop()
	}
	s.mediaRefreshTimers = nil
	s.mediaRefreshScopes = nil
	runtimes := make([]*rootRuntime, 0, len(s.runtimes))
	for _, runtime := range s.runtimes {
		runtimes = append(runtimes, runtime)
	}
	s.mu.Unlock()
	s.switchMu.Lock()
	if s.switchCancel != nil {
		s.switchCancel()
	}
	s.switchMu.Unlock()
	if s.duplicateScans != nil {
		s.duplicateScans.cancelAll()
	}
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
	if s.closed {
		s.mu.Unlock()
		return nil
	}
	retired := map[string]*rootRuntime{}
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
			if status.Running || (status.Backfill != nil && status.Backfill.Running) || (status.AIIndexing != nil && status.AIIndexing.Running) {
				continue
			}
		}
		if services.Cinema != nil && services.Cinema.InUse() {
			continue
		}
		if services.Backup != nil && services.Backup.Status().Running {
			continue
		}
		// Reserve this ID until its old SQLite/cache owners have fully closed.
		// Other roots must remain available during cancellation and disk I/O.
		delete(s.runtimes, id)
		s.initializing[id] = make(chan struct{})
		s.requests.Add(1)
		retired[id] = rt
	}
	s.mu.Unlock()
	var result error
	for id, rt := range retired {
		result = errors.Join(result, closeRootServices(rt.services))
		rt.scanWG.Wait()
		s.mu.Lock()
		close(s.initializing[id])
		delete(s.initializing, id)
		s.mu.Unlock()
		s.requests.Done()
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
	for {
		s.mu.Lock()
		if s.closed {
			s.mu.Unlock()
			return nil, errors.New("root_server_closed")
		}
		if pending := s.initializing[id]; pending != nil {
			s.mu.Unlock()
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-pending:
				continue
			}
		}
		if current := s.runtimes[id]; current != nil && current.root.Generation == root.Generation {
			current.users++
			s.mu.Unlock()
			return current, nil
		}
		previous := s.runtimes[id]
		delete(s.runtimes, id)
		pending := make(chan struct{})
		s.initializing[id] = pending
		s.mu.Unlock()

		// A large thumbnail directory can take seconds to reopen. Only this
		// root's callers wait; never keep the global checkout lock during I/O.
		var services *RootServices
		var err error
		if previous != nil {
			err = closeRootServices(previous.services)
			previous.scanWG.Wait()
		}
		if err == nil {
			services, err = s.factory(ctx, root, lease)
		}
		if err == nil && services == nil {
			err = errors.New("root_services_unavailable")
		}
		if err == nil && !lease.Valid(ctx) {
			err = roots.ErrStale
		}

		s.mu.Lock()
		if err == nil && s.closed {
			err = errors.New("root_server_closed")
		}
		if err == nil && services.Cinema != nil && s.tmdbToken != "" {
			if tokenErr := services.Cinema.SetTMDBToken(s.tmdbToken); tokenErr != nil {
				err = tokenErr
			}
		}
		if err != nil && services != nil {
			s.mu.Unlock()
			_ = closeRootServices(services)
			s.mu.Lock()
		}
		var current *rootRuntime
		if err == nil {
			current = &rootRuntime{root: root, services: services, users: 1, lastUsed: time.Now(), scans: map[string]*roots.Lease{}}
			s.runtimes[id] = current
		}
		delete(s.initializing, id)
		close(pending)
		s.mu.Unlock()
		return current, err
	}
}
