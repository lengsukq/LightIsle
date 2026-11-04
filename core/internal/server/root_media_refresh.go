package server

import (
	"context"
	"errors"
	"log/slog"
	"path"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/cinema"
	"github.com/lengsukq/lightisle/core/internal/gallery"
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
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	if s.mediaRefreshTimers == nil {
		s.mediaRefreshTimers = make(map[string]*time.Timer)
	}
	for _, selected := range kinds {
		key := rootID + ":" + selected
		if existing := s.mediaRefreshTimers[key]; existing != nil {
			existing.Reset(8 * time.Second)
			continue
		}
		root, media := rootID, selected
		s.mediaRefreshTimers[key] = time.AfterFunc(8*time.Second, func() {
			s.mu.Lock()
			delete(s.mediaRefreshTimers, key)
			s.mu.Unlock()
			s.refreshOneRootMedia(root, media)
		})
	}
}

func (s *RootServer) refreshOneRootMedia(rootID, kind string) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	lease, err := s.AcquireRootServices(ctx, rootID)
	if err != nil {
		// The periodic reconciliation notices the directory on reconnect.
		return
	}
	defer lease.Close()
	s.mu.Lock()
	runtime := s.runtimes[rootID]
	s.mu.Unlock()
	if runtime == nil || runtime.root.Generation != lease.Root.Generation {
		return
	}
	api := &API{rootServer: s, rootRuntime: runtime, rootID: rootID}
	if err := api.startRootScan(kind); err != nil &&
		!errors.Is(err, gallery.ErrBusy) && !errors.Is(err, cinema.ErrScanning) {
		slog.Warn("post-upload media refresh postponed", "rootID", rootID, "kind", kind, "error", err)
	}
}
