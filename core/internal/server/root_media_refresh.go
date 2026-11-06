package server

import (
	"context"
	"errors"
	"log/slog"
	"path"
	"strconv"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/cinema"
	"github.com/lengsukq/lightisle/core/internal/gallery"
	"github.com/lengsukq/lightisle/core/internal/mediascope"
)

// MediaKindForPath selects only known media destinations. Other files retain
// the normal periodic full scan rather than triggering costly scans for each
// document, archive or arbitrary directory upload.
func mediaKindForPath(name string) string {
	value := strings.ToLower(strings.Trim(name, "/"))
	for _, p := range []string{"图库/", "photos/", "users/"} {
		if strings.HasPrefix(value, p) {
			if p == "users/" {
				parts := strings.Split(value, "/")
				if len(parts) >= 4 && parts[2] == "photos" {
					return "gallery"
				}
				break
			}
			return "gallery"
		}
	}
	for _, p := range []string{"影视/", "videos/"} {
		if strings.HasPrefix(value, p) {
			return "cinema"
		}
	}
	parts := strings.Split(value, "/")
	if len(parts) >= 4 && parts[0] == "users" && parts[2] == "videos" {
		return "cinema"
	}
	if len(parts) >= 3 && parts[0] == "users" &&
		parts[2] != "files" && parts[2] != "photos" && parts[2] != "videos" {
		// Unknown personal-home categories are not valid media index roots.
		return ""
	}
	// Users can organize shared media inside custom folders rather than the
	// default Chinese library directories. The scanner walks the verified
	// root, so refresh it when a recognizable media *file* is uploaded,
	// renamed, restored or deleted anywhere else. Without this fallback
	// custom folders remain stale until the next periodic full reconciliation.
	// Do not trigger a costly full scan for arbitrary extensionless dirs,
	// archives, app-private metadata or unrelated documents.
	if strings.HasPrefix(value, ".lightisle-") || strings.Contains(value, "/.lightisle-") {
		return ""
	}
	switch path.Ext(value) {
	case ".jpg", ".jpeg", ".png", ".webp", ".gif", ".heic", ".heif", ".tif", ".tiff", ".avif", ".dng", ".cr2", ".cr3", ".nef", ".arw", ".raf", ".rw2", ".orf":
		return "gallery"
	case ".mp4", ".m4v", ".mov", ".mkv", ".avi", ".webm", ".wmv", ".ts", ".m2ts", ".mpg", ".mpeg":
		return "cinema"
	}
	return ""
}

// QueueMediaRefresh is called only after a successful, authorized mutation.
// Per-root debouncing prevents a photo upload batch from starting hundreds of
// parallel full scans. Admin and members use the same server-side trigger;
// clients never need scan-administrator privilege after uploading.
// An empty relativePath is trusted native migration completion and refreshes
// both libraries. Root identity is checked again before the scan starts.
func (s *RootServer) QueueMediaRefresh(rootID, relativePath string) {
	if s == nil || rootID == "" {
		return
	}
	kind := mediaKindForPath(relativePath)
	kinds := []string{kind}
	if relativePath == "" {
		kinds = []string{"gallery", "cinema"}
	} else if kind == "" {
		// A moved or deleted directory may have no recognizable media
		// extension. Scan its parent for both libraries so nested photos and
		// films do not stay stale until the periodic reconciliation.
		if strings.HasPrefix(relativePath, ".lightisle-") || strings.Contains(relativePath, "/.lightisle-") {
			return
		}
		kinds = []string{"gallery", "cinema"}
	}
	for _, selected := range kinds {
		dir := "."
		if relativePath != "" {
			dir = path.Dir(relativePath)
		}
		s.scheduleMediaRefreshScope(rootID, selected, 0, []string{dir}, 8*time.Second, true)
	}
}

// QueueNativeRootRefresh accepts an event from the local Mac process for a
// particular registered generation. A delayed event must never be applied to
// a later binding of the same root ID.
func (s *RootServer) QueueNativeRootRefresh(rootID string, generation uint64) {
	s.QueueNativeRootRefreshDirs(rootID, generation, []string{"."})
}

func (s *RootServer) QueueNativeRootRefreshDirs(rootID string, generation uint64, dirs []string) {
	if s == nil || rootID == "" || generation == 0 {
		return
	}
	dirs, err := mediascope.ScanDirectories(dirs)
	if err != nil {
		return
	}
	for _, kind := range []string{"gallery", "cinema"} {
		s.scheduleMediaRefreshScope(rootID, kind, generation, dirs, 8*time.Second, true)
	}
}

// A retry must not postpone a newer user mutation already waiting to run.
// Conversely, a new mutation extends the debounce window for its batch.
func (s *RootServer) scheduleMediaRefreshScope(rootID, kind string, generation uint64, dirs []string, delay time.Duration, debounce bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	if s.mediaRefreshTimers == nil {
		s.mediaRefreshTimers = make(map[string]*time.Timer)
	}
	if s.mediaRefreshScopes == nil {
		s.mediaRefreshScopes = make(map[string]map[string]struct{})
	}
	key := rootID + ":" + kind
	if generation != 0 {
		key += ":" + strconv.FormatUint(generation, 10)
	}
	scope := s.mediaRefreshScopes[key]
	if scope == nil {
		scope = make(map[string]struct{})
		s.mediaRefreshScopes[key] = scope
	}
	for _, dir := range dirs {
		if dir == "" || dir == "." || path.Clean(dir) != dir || strings.HasPrefix(dir, "/") || dir == ".." || strings.HasPrefix(dir, "../") {
			clear(scope)
			scope["."] = struct{}{}
			break
		}
		if _, full := scope["."]; !full {
			scope[dir] = struct{}{}
			if len(scope) > 32 {
				clear(scope)
				scope["."] = struct{}{}
			}
		}
	}
	if existing := s.mediaRefreshTimers[key]; existing != nil {
		if !debounce {
			return
		}
		if existing.Stop() {
			existing.Reset(delay)
			return
		}
		// The old callback has already fired and may be waiting on mu.
		// Replace it, and do not let it delete this newer request.
	}
	var timer *time.Timer
	timer = time.AfterFunc(delay, func() {
		s.mu.Lock()
		if s.mediaRefreshTimers[key] != timer {
			s.mu.Unlock()
			return
		}
		delete(s.mediaRefreshTimers, key)
		selectedDirs := make([]string, 0, len(s.mediaRefreshScopes[key]))
		for dir := range s.mediaRefreshScopes[key] {
			selectedDirs = append(selectedDirs, dir)
		}
		delete(s.mediaRefreshScopes, key)
		s.mu.Unlock()
		s.refreshOneRootMediaScope(rootID, kind, generation, selectedDirs)
	})
	s.mediaRefreshTimers[key] = timer
}

func (s *RootServer) refreshOneRootMedia(rootID, kind string) {
	s.refreshOneRootMediaGeneration(rootID, kind, 0)
}

func (s *RootServer) refreshOneRootMediaGeneration(rootID, kind string, generation uint64) {
	s.refreshOneRootMediaScope(rootID, kind, generation, []string{"."})
}

func (s *RootServer) refreshOneRootMediaScope(rootID, kind string, generation uint64, dirs []string) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	lease, err := s.AcquireRootServices(ctx, rootID)
	if err != nil {
		// The periodic reconciliation notices the directory on reconnect.
		return
	}
	defer lease.Close()
	if generation != 0 && generation != lease.Root.Generation {
		return
	}
	s.mu.Lock()
	runtime := s.runtimes[rootID]
	s.mu.Unlock()
	if runtime == nil || runtime.root.Generation != lease.Root.Generation {
		return
	}
	api := &API{rootServer: s, rootRuntime: runtime, rootID: rootID}
	if len(dirs) == 0 {
		dirs = []string{"."}
	}
	if err := api.startRootScanDirs(kind, dirs); err != nil {
		if errors.Is(err, gallery.ErrBusy) || errors.Is(err, cinema.ErrScanning) {
			// The current scan may already have visited the changed directory.
			// Keep the request until it can start a subsequent reconciliation.
			s.scheduleMediaRefreshScope(rootID, kind, generation, dirs, 5*time.Second, false)
			return
		}
		slog.Warn("post-mutation media refresh postponed", "rootID", rootID, "kind", kind, "error", err)
	}
}
