package server

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/cinema"
	"github.com/lengsukq/lightisle/core/internal/gallery"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/safego"
)

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

func rootError(w http.ResponseWriter, err error) {
	if errors.Is(err, roots.ErrMissing) {
		writeAPIErrorCode(w, http.StatusNotFound, "root_not_found")
		return
	}
	if errors.Is(err, roots.ErrOffline) || errors.Is(err, roots.ErrStale) {
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "root_unavailable")
		return
	}
	writeAPIErrorCode(w, http.StatusServiceUnavailable, "root_services_unavailable")
}

func rootLeaseForRequest(w http.ResponseWriter, r *http.Request, api *API, public bool) (*API, func()) {
	s := api.rootServer
	if s == nil || s.registry == nil || !s.beginRequest() {
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "root_services_unavailable")
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
		writeAPIErrorCode(w, http.StatusUnauthorized, "authentication_required")
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
	child.collector = nil
	child.backup = nil
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
		writeAPIErrorCode(w, http.StatusPreconditionRequired, "root_generation_required")
		return false
	}
	if len(headerValues) > 1 || (queryPresent && len(queryValues) != 1) {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_root_generation")
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
			writeAPIErrorCode(w, http.StatusBadRequest, "invalid_root_generation")
			return false
		}
		if generation != current {
			writeAPIErrorCode(w, http.StatusConflict, "root_generation_changed")
			return false
		}
	}
	return true
}

func (a *API) requireRootTraverse(next http.HandlerFunc) http.HandlerFunc {
	return a.requireLogin(func(w http.ResponseWriter, r *http.Request) {
		if a.auth == nil || !a.auth.CanAccessRoot(token(r), a.rootID, ".", false, true) {
			writeAPIErrorCode(w, http.StatusForbidden, "file_permission_denied")
			return
		}
		next(w, r)
	})
}

func (a *API) rootDiscovery(w http.ResponseWriter, r *http.Request) {
	if a.rootServer == nil || a.rootServer.registry == nil {
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "root_services_unavailable")
		return
	}
	if a.auth == nil || !a.auth.Session(token(r)) {
		writeAPIErrorCode(w, http.StatusUnauthorized, "authentication_required")
		return
	}
	viewer, _ := a.auth.Identity(token(r))
	isAdmin := viewer.Role == auth.RoleAdmin
	items := a.rootServer.registry.List()
	defaultRoot, hasDefault := a.rootServer.registry.Default()
	out := make([]map[string]any, 0, len(items))
	for _, item := range items {
		if !a.auth.CanSeeRoot(token(r), item.ID, ".") {
			continue
		}
		online := false
		var capacity map[string]any
		lease, err := a.rootServer.registry.Acquire(r.Context(), item.ID)
		if err == nil {
			online = true
			if a.auth != nil {
				if syncErr := a.auth.SyncVerifiedRootGeneration(item.ID, item.Generation); syncErr != nil {
					slog.Warn("failed to sync verified root generation on root discovery", "rootID", item.ID, "generation", item.Generation, "error", syncErr)
				}
			}
			// This is free space of the underlying filesystem, NOT a
			// dedicated allocation to this LightIsle root or user. Multiple
			// roots on one APFS volume report the same shared free space.
			var stat syscall.Statfs_t
			if syscall.Statfs(item.Path, &stat) == nil && stat.Bsize > 0 {
				capacity = map[string]any{
					"filesystemTotalBytes":     uint64(stat.Blocks) * uint64(stat.Bsize),
					"filesystemAvailableBytes": uint64(stat.Bavail) * uint64(stat.Bsize),
					"capacityScope":            "underlying_filesystem_shared",
				}
				// Only the administrator can correlate a NAS root with
				// an underlying macOS volume. No arbitrary filesystem
				// browsing is introduced by this diagnostic metadata.
				if isAdmin {
					mount := make([]byte, 0, len(stat.Mntonname))
					for _, char := range stat.Mntonname {
						if char == 0 {
							break
						}
						mount = append(mount, byte(char))
					}
					if len(mount) > 0 {
						capacity["volumeMount"] = string(mount)
					}
				}
			}
			_ = lease.Close()
		}
		entry := map[string]any{
			"rootID": item.ID, "name": item.Name, "generation": item.Generation,
			"online": online, "isDefault": hasDefault && defaultRoot.ID == item.ID,
		}
		for key, value := range capacity {
			entry[key] = value
		}
		out = append(out, entry)
	}
	jsonReply(w, http.StatusOK, map[string]any{"roots": out})
}

func (a *API) rootDiscoveryRequest(w http.ResponseWriter, r *http.Request) {
	if a.rootServer == nil || !a.rootServer.beginRequest() {
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "root_services_unavailable")
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
		writeAPIErrorCode(w, http.StatusForbidden, "cannot_list_grants")
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
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_request")
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
		writeAPIErrorCode(w, status, "invalid_grant")
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
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_grant")
		return
	}
	jsonReply(w, http.StatusOK, map[string]bool{"removed": true})
}

func rootGrantUserID(w http.ResponseWriter, r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("userID"), 10, 64)
	if err != nil || id <= 0 {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_user")
		return 0, false
	}
	return id, true
}

func (a *API) startRootScan(kind string) error {
	return a.startRootScanDirs(kind, []string{"."})
}

func (a *API) startRootScanDirs(kind string, dirs []string) error {
	if a.rootServer == nil || a.rootRuntime == nil || a.rootID == "" {
		return errors.New("root_scan_unavailable")
	}
	runtime := a.rootRuntime
	if kind == "cinema" && runtime.services.Cinema != nil {
		runtime.services.Cinema.CancelScrapeIfRunning()
	}
	runtime.scanMu.Lock()
	defer runtime.scanMu.Unlock()
	if existing := runtime.scans[kind]; existing != nil {
		if kind == "cinema" && runtime.services.Cinema != nil && !runtime.services.Cinema.Status().Running {
			delete(runtime.scans, kind)
			_ = existing.Close()
		} else {
			if kind == "gallery" {
				return gallery.ErrBusy
			}
			return cinema.ErrScanning
		}
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
			startErr = runtime.services.Gallery.StartScanDirs(dirs)
			status = func() bool { return runtime.services.Gallery.Status().Running }
		}
	case "cinema":
		if runtime.services.Cinema == nil {
			startErr = cinema.ErrOffline
		} else {
			startErr = runtime.services.Cinema.StartScanDirs(dirs)
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
	safego.Go("root-scan-lease:"+kind, func() {
		defer runtime.scanWG.Done()
		ticker := time.NewTicker(50 * time.Millisecond)
		defer ticker.Stop()
		for status != nil && status() {
			<-ticker.C
		}
		// Match the idle sweeper's lock order. A long manual scan starts a
		// fresh idle interval when it releases its background lease.
		a.rootServer.mu.Lock()
		runtime.scanMu.Lock()
		if runtime.scans[kind] == lease {
			delete(runtime.scans, kind)
			_ = lease.Close()
			runtime.lastUsed = time.Now()
		}
		runtime.scanMu.Unlock()
		a.rootServer.mu.Unlock()
	})
	return nil
}
