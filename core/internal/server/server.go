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
	"github.com/lengsukq/lightisle/core/internal/cinema"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/gallery"
	"github.com/lengsukq/lightisle/core/internal/system"
)

type API struct {
	collector *system.Collector
	webRoot   string
	auth      *auth.Store
	files     files.Access
	gallery   *gallery.Library
	cinema    *cinema.Library
	limiter   *loginLimiter
}

func New(webRoot string, store *auth.Store, fileStore files.Access, photoLibrary ...*gallery.Library) http.Handler {
	var photos *gallery.Library
	if len(photoLibrary) > 0 {
		photos = photoLibrary[0]
	}
	return NewWithCinema(webRoot, store, fileStore, photos, nil)
}
func NewWithCinema(webRoot string, store *auth.Store, fileStore files.Access, photos *gallery.Library, films *cinema.Library) http.Handler {
	a := &API{collector: &system.Collector{}, webRoot: webRoot, auth: store, files: fileStore, gallery: photos, cinema: films, limiter: newLoginLimiter()}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/health", a.health)
	mux.HandleFunc("GET /api/v1/auth/status", a.authStatus)
	mux.HandleFunc("POST /api/v1/auth/login", a.login)
	mux.HandleFunc("POST /api/v1/auth/logout", a.logout)
	mux.HandleFunc("GET /api/v1/auth/me", a.me)
	mux.HandleFunc("GET /api/v1/users", a.requireAdmin(a.users))
	mux.HandleFunc("POST /api/v1/users", a.requireAdmin(a.addUser))
	mux.HandleFunc("PATCH /api/v1/users/{id}", a.requireAdmin(a.changeUser))
	mux.HandleFunc("GET /api/v1/system", a.requireLogin(a.system))
	mux.HandleFunc("GET /api/v1/files", a.requireLogin(a.listFiles))
	mux.HandleFunc("DELETE /api/v1/files", a.requireLogin(a.trashFile))
	mux.HandleFunc("POST /api/v1/files/folders", a.requireLogin(a.mkdir))
	mux.HandleFunc("GET /api/v1/files/content", a.requireLogin(a.readFile))
	mux.HandleFunc("HEAD /api/v1/files/content", a.requireLogin(a.readFile))
	mux.HandleFunc("PUT /api/v1/files/content", a.requireLogin(a.uploadFile))
	mux.HandleFunc("POST /api/v1/uploads", a.requireLogin(a.beginUpload))
	mux.HandleFunc("GET /api/v1/uploads/{id}", a.requireLogin(a.uploadStatus))
	mux.HandleFunc("PATCH /api/v1/uploads/{id}", a.requireLogin(a.uploadChunk))
	mux.HandleFunc("POST /api/v1/uploads/{id}/complete", a.requireLogin(a.uploadComplete))
	mux.HandleFunc("POST /api/v1/files/batch", a.requireLogin(a.fileBatch))
	mux.HandleFunc("GET /api/v1/files/preview", a.requireLogin(a.previewFile))
	mux.HandleFunc("HEAD /api/v1/files/preview", a.requireLogin(a.previewFile))
	mux.HandleFunc("GET /api/v1/files/trash", a.requireLogin(a.listTrash))
	mux.HandleFunc("POST /api/v1/files/trash/{id}/restore", a.requireLogin(a.restoreTrash))
	mux.HandleFunc("GET /api/v1/files/root", a.requireLogin(a.fileRoot))
	mux.HandleFunc("GET /api/v1/photos", a.requireLogin(a.galleryList))
	mux.HandleFunc("GET /api/v1/photos/status", a.requireLogin(a.galleryStatus))
	mux.HandleFunc("POST /api/v1/photos/scan", a.requireAdmin(a.galleryScan))
	mux.HandleFunc("GET /api/v1/photos/{id}/thumbnail", a.requireLogin(a.galleryThumbnail))
	mux.HandleFunc("POST /api/v1/photos/{id}/favorite", a.requireLogin(a.galleryFavorite))
	mux.HandleFunc("GET /api/v1/photos/albums", a.requireLogin(a.galleryAlbums))
	mux.HandleFunc("POST /api/v1/photos/albums", a.requireLogin(a.galleryCreateAlbum))
	mux.HandleFunc("POST /api/v1/photos/albums/{id}/items", a.requireLogin(a.galleryAddToAlbum))
	mux.HandleFunc("GET /api/v1/cinema", a.requireLogin(a.cinemaList))
	mux.HandleFunc("GET /api/v1/cinema/status", a.requireLogin(a.cinemaStatus))
	mux.HandleFunc("POST /api/v1/cinema/scan", a.requireAdmin(a.cinemaScan))
	mux.HandleFunc("GET /api/v1/cinema/{id}", a.requireLogin(a.cinemaGet))
	mux.HandleFunc("PATCH /api/v1/cinema/{id}", a.requireAdmin(a.cinemaRename))
	mux.HandleFunc("GET /api/v1/cinema/{id}/stream", a.requireLogin(a.cinemaStream))
	mux.HandleFunc("HEAD /api/v1/cinema/{id}/stream", a.requireLogin(a.cinemaStream))
	mux.HandleFunc("GET /api/v1/cinema/{id}/subtitles", a.requireLogin(a.cinemaSubtitle))
	mux.HandleFunc("GET /api/v1/cinema/{id}/progress", a.requireLogin(a.cinemaProgress))
	mux.HandleFunc("PUT /api/v1/cinema/{id}/progress", a.requireLogin(a.cinemaSaveProgress))
	mux.HandleFunc("/", a.static)
	return securityHeaders(mux)
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
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
