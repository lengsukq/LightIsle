package maptiles

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

const maxTileBytes = 1024 * 1024

// Tianditu's application key is supplied exclusively over the owner's Mac
// private stdin IPC and held in process memory, never in HTTP responses.
type Service struct {
	mu          sync.RWMutex
	key         string
	client      *http.Client
	slots       chan struct{}
	cacheMu     sync.Mutex
	cacheDir    string
	maxBytes    int64
	memEntries  map[string]cachedTile
	memBytes    int64
	diskEntries map[[32]byte]diskTileEntry
	diskBytes   int64
}

func New() *Service {
	return &Service{
		client:      &http.Client{Timeout: 12 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }},
		slots:       make(chan struct{}, 16),
		maxBytes:    DefaultMapTileCacheBytes,
		memEntries:  map[string]cachedTile{},
		diskEntries: map[[32]byte]diskTileEntry{},
	}
}

// Default is shared by the global HTTP router and the trusted native IPC
// reader. It does not survive a Core process restart.
var Default = New()

func ValidKey(key string) bool {
	if len(key) < 8 || len(key) > 128 {
		return false
	}
	for _, c := range key {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

func (s *Service) Set(key string) error {
	if !ValidKey(key) {
		return errors.New("invalid_map_key")
	}
	s.mu.Lock()
	s.key = key
	s.mu.Unlock()
	return nil
}

func (s *Service) Clear() {
	s.mu.Lock()
	s.key = ""
	s.mu.Unlock()
	s.ClearCache()
}

func (s *Service) Configured() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.key != ""
}

func (s *Service) currentKey() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.key
}

// ServeTile is used only behind authenticated HTTP routing. The upstream
// domain and paths are fixed, eliminating user-supplied proxy destinations.
// No key (nor remote error response) is ever echoed to the caller.
func (s *Service) ServeTile(w http.ResponseWriter, r *http.Request, layer, zs, xs, ys string) {
	if layer != "vec" && layer != "cva" {
		http.Error(w, "invalid_map_tile", http.StatusBadRequest)
		return
	}
	z, ze := strconv.Atoi(zs)
	x, xe := strconv.Atoi(xs)
	y, ye := strconv.Atoi(ys)
	if ze != nil || xe != nil || ye != nil || z < 0 || z > 18 || x < 0 || y < 0 || x >= 1<<z || y >= 1<<z {
		http.Error(w, "invalid_map_tile", http.StatusBadRequest)
		return
	}
	key := s.currentKey()
	if key == "" {
		http.Error(w, "map_not_configured", http.StatusServiceUnavailable)
		return
	}
	tileID := fmt.Sprintf("%s_%d_%d_%d", layer, z, x, y)
	if cached, contentType, etag, ok := s.getCachedTile(tileID); ok {
		w.Header().Set("Content-Type", contentType)
		w.Header().Set("Cache-Control", "private, max-age=604800, stale-while-revalidate=86400")
		w.Header().Set("ETag", etag)
		w.Header().Set("X-Content-Type-Options", "nosniff")
		if r.Header.Get("If-None-Match") == etag {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(cached)
		return
	}
	select {
	case s.slots <- struct{}{}:
		defer func() { <-s.slots }()
	case <-r.Context().Done():
		return
	default:
		http.Error(w, "map_busy", http.StatusTooManyRequests)
		return
	}
	// Only this official HTTPS host is allowed; never follow redirects.
	url := fmt.Sprintf("https://t0.tianditu.gov.cn/%s_w/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0&LAYER=%s&STYLE=default&TILEMATRIXSET=w&FORMAT=tiles&TILEMATRIX=%d&TILEROW=%d&TILECOL=%d&tk=%s", layer, layer, z, y, x, key)
	request, err := http.NewRequestWithContext(r.Context(), http.MethodGet, url, nil)
	if err != nil {
		http.Error(w, "map_unavailable", http.StatusBadGateway)
		return
	}
	request.Header.Set("User-Agent", "LightIsle/1.0 (photo-map)")
	resp, err := s.client.Do(request)
	if err != nil {
		http.Error(w, "map_unavailable", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK || !strings.HasPrefix(resp.Header.Get("Content-Type"), "image/") {
		http.Error(w, "map_tile_unavailable", http.StatusBadGateway)
		return
	}
	buf, err := io.ReadAll(io.LimitReader(resp.Body, maxTileBytes+1))
	if err != nil || len(buf) == 0 || len(buf) > maxTileBytes {
		http.Error(w, "map_tile_unavailable", http.StatusBadGateway)
		return
	}
	sniff := http.DetectContentType(buf)
	if !strings.HasPrefix(sniff, "image/") {
		http.Error(w, "map_tile_unavailable", http.StatusBadGateway)
		return
	}
	etag := s.putCachedTile(tileID, buf, sniff)
	w.Header().Set("Content-Type", sniff)
	w.Header().Set("Cache-Control", "private, max-age=604800, stale-while-revalidate=86400")
	w.Header().Set("ETag", etag)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(buf)
}

// Reserved for tests that simulate the remote map service without network.
func (s *Service) SetHTTPClientForTest(client *http.Client) { s.client = client }
