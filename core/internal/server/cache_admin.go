package server

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/gallery"
	"github.com/lengsukq/lightisle/core/internal/maptiles"
)

func (s *RootServer) aggregateThumbnailCacheStats(ctx context.Context) gallery.ThumbnailCacheStats {
	s.mu.Lock()
	libs := make([]*gallery.Library, 0, len(s.runtimes))
	for _, rt := range s.runtimes {
		if rt != nil && rt.services != nil && rt.services.Gallery != nil {
			libs = append(libs, rt.services.Gallery)
		}
	}
	s.mu.Unlock()
	if len(libs) == 0 && s.registry != nil {
		if def, ok := s.registry.Default(); ok {
			if leased, err := s.AcquireRootServices(ctx, def.ID); err == nil {
				defer leased.Close()
				if leased.Services.Gallery != nil {
					return leased.Services.Gallery.CacheStats()
				}
			}
		}
	}
	var out gallery.ThumbnailCacheStats
	for _, lib := range libs {
		st := lib.CacheStats()
		out.UsedBytes += st.UsedBytes
		out.EntryCount += st.EntryCount
		if st.MaxBytes > out.MaxBytes {
			out.MaxBytes = st.MaxBytes
		}
		if st.MaxEntries > out.MaxEntries {
			out.MaxEntries = st.MaxEntries
		}
	}
	if out.MaxBytes == 0 {
		out.MaxBytes = gallery.DefaultThumbnailCacheBytes
		out.MaxEntries = gallery.MaxThumbnailCacheEntries
	}
	return out
}

func (s *RootServer) clearAllThumbnailCaches(ctx context.Context) (int, int64) {
	s.mu.Lock()
	libs := make([]*gallery.Library, 0, len(s.runtimes))
	for _, rt := range s.runtimes {
		if rt != nil && rt.services != nil && rt.services.Gallery != nil {
			libs = append(libs, rt.services.Gallery)
		}
	}
	s.mu.Unlock()
	if len(libs) == 0 && s.registry != nil {
		if def, ok := s.registry.Default(); ok {
			if leased, err := s.AcquireRootServices(ctx, def.ID); err == nil {
				defer leased.Close()
				if leased.Services.Gallery != nil {
					removed, freed, _ := leased.Services.Gallery.ClearThumbnailCache()
					return removed, freed
				}
			}
		}
	}
	var totalRemoved int
	var totalFreed int64
	for _, lib := range libs {
		removed, freed, _ := lib.ClearThumbnailCache()
		totalRemoved += removed
		totalFreed += freed
	}
	return totalRemoved, totalFreed
}

func serveCachedJPEG(w http.ResponseWriter, r *http.Request, downloadName string, modTime time.Time, f *os.File) {
	base := filepath.Base(f.Name())
	if strings.HasSuffix(base, ".jpg") && len(base) == 64+len(".jpg") {
		key := strings.TrimSuffix(base, ".jpg")
		w.Header().Set("ETag", `"`+key+`"`)
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "private, max-age=604800, stale-while-revalidate=86400")
	http.ServeContent(w, r, downloadName, modTime, f)
}

func (a *API) collectThumbnailCacheStats(r *http.Request) gallery.ThumbnailCacheStats {
	if a.gallery != nil {
		return a.gallery.CacheStats()
	}
	if a.rootServer != nil {
		return a.rootServer.aggregateThumbnailCacheStats(r.Context())
	}
	return gallery.ThumbnailCacheStats{
		MaxBytes:   gallery.DefaultThumbnailCacheBytes,
		MaxEntries: gallery.MaxThumbnailCacheEntries,
	}
}

func (a *API) cacheStatus(w http.ResponseWriter, r *http.Request) {
	thumbStats := a.collectThumbnailCacheStats(r)
	tileStats := maptiles.Default.CacheStats()
	jsonReply(w, http.StatusOK, map[string]any{
		"thumbnails":     thumbStats,
		"mapTiles":       tileStats,
		"totalUsedBytes": thumbStats.UsedBytes + tileStats.UsedBytes,
	})
}

func (a *API) adminCacheClear(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Categories []string `json:"categories"`
	}
	if r.Body != nil {
		raw, err := io.ReadAll(io.LimitReader(r.Body, 4096))
		if err == nil && len(strings.TrimSpace(string(raw))) > 0 {
			if err := json.Unmarshal(raw, &body); err != nil {
				jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
				return
			}
		}
	}
	clearThumbs := len(body.Categories) == 0
	clearTiles := len(body.Categories) == 0
	for _, cat := range body.Categories {
		switch strings.TrimSpace(cat) {
		case "thumbnails", "posters", "media":
			clearThumbs = true
		case "map_tiles", "mapTiles", "map":
			clearTiles = true
		case "all":
			clearThumbs = true
			clearTiles = true
		}
	}

	var totalRemoved int
	var totalFreed int64
	if clearThumbs {
		if a.gallery != nil {
			removed, freed, _ := a.gallery.ClearThumbnailCache()
			totalRemoved += removed
			totalFreed += freed
		}
		if a.rootServer != nil {
			removed, freed := a.rootServer.clearAllThumbnailCaches(r.Context())
			totalRemoved += removed
			totalFreed += freed
		}
	}
	if clearTiles {
		removed, freed := maptiles.Default.ClearCache()
		totalRemoved += removed
		totalFreed += freed
	}

	thumbStats := a.collectThumbnailCacheStats(r)
	tileStats := maptiles.Default.CacheStats()
	jsonReply(w, http.StatusOK, map[string]any{
		"ok":             true,
		"removedEntries": totalRemoved,
		"freedBytes":     totalFreed,
		"thumbnails":     thumbStats,
		"mapTiles":       tileStats,
		"totalUsedBytes": thumbStats.UsedBytes + tileStats.UsedBytes,
	})
}
