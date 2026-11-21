package cinema

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const (
	officialTMDBImageBase = "https://image.tmdb.org/t/p/w342"
	maxPosterImageBytes   = 6 << 20
)

var tmdbImageURLPattern = regexp.MustCompile(`^https://image\.tmdb\.org/t/p/(?:w185|w342|w500|w780|original)(/[a-zA-Z0-9_-]{1,110}\.(?:jpg|jpeg|png|webp))$`)

// ExtractTMDBPosterPath validates either a raw TMDB poster_path ("/abc.jpg")
// or an official TMDB image URL and returns the canonical "/abc.jpg" suffix.
func ExtractTMDBPosterPath(raw string) (string, bool) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "", false
	}
	if tmdbPosterPattern.MatchString(trimmed) {
		return trimmed, true
	}
	if m := tmdbImageURLPattern.FindStringSubmatch(trimmed); len(m) == 2 && tmdbPosterPattern.MatchString(m[1]) {
		return m[1], true
	}
	return "", false
}

// PosterMediaType returns the safe image Content-Type for supported poster extensions.
func PosterMediaType(name string) string {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".png":
		return "image/png"
	case ".webp":
		return "image/webp"
	default:
		return ""
	}
}

func validImageSignature(header []byte) bool {
	if len(header) >= 3 && header[0] == 0xff && header[1] == 0xd8 && header[2] == 0xff {
		return true
	}
	if len(header) >= 8 && bytes.Equal(header[:8], []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}) {
		return true
	}
	if len(header) >= 12 && bytes.Equal(header[:4], []byte("RIFF")) && bytes.Equal(header[8:12], []byte("WEBP")) {
		return true
	}
	return false
}

// SetTMDBImageSource configures a hermetic test server for TMDB poster image fetches.
func (l *Library) SetTMDBImageSource(endpoint string, client *http.Client) {
	l.tmdbMu.Lock()
	defer l.tmdbMu.Unlock()
	l.tmdbImageEndpoint = strings.TrimRight(strings.TrimSpace(endpoint), "/")
	l.tmdbImageClient = client
}

// FetchOrCacheTMDBPoster serves a scraped TMDB poster from the local disk cache,
// downloading and caching it from image.tmdb.org on first access so mobile and
// LAN clients work reliably even when they cannot reach image.tmdb.org directly.
func (l *Library) FetchOrCacheTMDBPoster(ctx context.Context, rawPoster string) (*os.File, os.FileInfo, string, error) {
	posterPath, ok := ExtractTMDBPosterPath(rawPoster)
	if !ok {
		return nil, nil, "", ErrInvalid
	}
	fileName := strings.TrimPrefix(posterPath, "/")
	mediaType := PosterMediaType(fileName)
	if mediaType == "" || strings.ContainsAny(fileName, `/\`) {
		return nil, nil, "", ErrInvalid
	}

	cacheDir := ""
	if l.posterCacheDir != "" {
		cacheDir = filepath.Join(l.posterCacheDir, "tmdb")
	}
	if cacheDir != "" {
		cachedFile := filepath.Join(cacheDir, fileName)
		if f, err := os.Open(cachedFile); err == nil {
			if info, statErr := f.Stat(); statErr == nil && info.Mode().IsRegular() && info.Size() > 0 && info.Size() <= maxPosterImageBytes {
				return f, info, mediaType, nil
			}
			_ = f.Close()
		}
	}

	l.tmdbMu.Lock()
	base := l.tmdbImageEndpoint
	client := l.tmdbImageClient
	l.tmdbMu.Unlock()

	if base == "" {
		base = officialTMDBImageBase
	} else if client == nil {
		return nil, nil, "", ErrInvalid
	}
	if client == nil {
		client = &http.Client{
			Timeout: 9 * time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		}
	}

	reqCtx, cancel := context.WithTimeout(ctx, 9*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, base+posterPath, nil)
	if err != nil {
		return nil, nil, "", err
	}
	req.Header.Set("Accept", "image/webp,image/png,image/jpeg,*/*;q=0.8")
	resp, err := client.Do(req)
	if err != nil {
		return nil, nil, "", fmt.Errorf("tmdb_poster_unavailable: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, nil, "", fmt.Errorf("tmdb_poster_status_%d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxPosterImageBytes+1))
	if err != nil || len(body) == 0 || len(body) > maxPosterImageBytes || !validImageSignature(body) {
		return nil, nil, "", errors.New("tmdb_poster_invalid_body")
	}

	if cacheDir == "" {
		tmp, tmpErr := os.CreateTemp("", "lightisle-tmdb-poster-*"+filepath.Ext(fileName))
		if tmpErr != nil {
			return nil, nil, "", tmpErr
		}
		tmpName := tmp.Name()
		_ = os.Remove(tmpName)
		if _, wErr := tmp.Write(body); wErr != nil {
			_ = tmp.Close()
			return nil, nil, "", wErr
		}
		if _, sErr := tmp.Seek(0, io.SeekStart); sErr != nil {
			_ = tmp.Close()
			return nil, nil, "", sErr
		}
		info, statErr := tmp.Stat()
		if statErr != nil {
			_ = tmp.Close()
			return nil, nil, "", statErr
		}
		return tmp, info, mediaType, nil
	}

	if err := os.MkdirAll(cacheDir, 0o700); err != nil {
		return nil, nil, "", err
	}
	tmp, err := os.CreateTemp(cacheDir, "tmdb-poster-*.tmp")
	if err != nil {
		return nil, nil, "", err
	}
	tmpName := tmp.Name()
	_, wErr := tmp.Write(body)
	cErr := tmp.Close()
	if wErr != nil || cErr != nil {
		_ = os.Remove(tmpName)
		return nil, nil, "", errors.New("tmdb_poster_cache_write_failed")
	}
	_ = os.Chmod(tmpName, 0o600)
	finalPath := filepath.Join(cacheDir, fileName)
	if err := os.Rename(tmpName, finalPath); err != nil {
		_ = os.Remove(tmpName)
		return nil, nil, "", err
	}
	f, err := os.Open(finalPath)
	if err != nil {
		return nil, nil, "", err
	}
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() {
		_ = f.Close()
		return nil, nil, "", errors.New("tmdb_poster_cache_stat_failed")
	}
	return f, info, mediaType, nil
}

// ReadSidecarPoster looks for standard local poster artwork alongside a film
// ({stem}-poster.jpg, {stem}.jpg, poster.jpg, folder.jpg, cover.jpg) inside
// the authorized shared root without following symlinks.
func (l *Library) ReadSidecarPoster(film Film) (*os.File, os.FileInfo, string, error) {
	if l == nil || l.files == nil || strings.TrimSpace(film.Path) == "" {
		return nil, nil, "", os.ErrNotExist
	}
	cleanFilm := path.Clean(strings.TrimPrefix(film.Path, "/"))
	if cleanFilm == "." || cleanFilm == "" || strings.HasPrefix(cleanFilm, "../") {
		return nil, nil, "", os.ErrNotExist
	}
	stem := strings.TrimSuffix(cleanFilm, path.Ext(cleanFilm))
	exts := []string{".jpg", ".jpeg", ".png", ".webp"}
	candidates := make([]string, 0, 20)
	for _, ext := range exts {
		candidates = append(candidates, stem+"-poster"+ext, stem+ext)
	}
	dir := path.Dir(cleanFilm)
	if dir != "." && dir != "" && dir != "/" {
		for _, base := range []string{"poster", "folder", "cover"} {
			for _, ext := range exts {
				candidates = append(candidates, path.Join(dir, base+ext))
			}
		}
	}
	return l.openFirstValidSidecar(candidates)
}

// ReadSeriesSidecarPoster looks for local show artwork (poster.jpg, tvshow.jpg,
// folder.jpg, cover.jpg) in a series' directory or parent show directory.
func (l *Library) ReadSeriesSidecarPoster(episodes []Film) (*os.File, os.FileInfo, string, error) {
	if l == nil || l.files == nil || len(episodes) == 0 {
		return nil, nil, "", os.ErrNotExist
	}
	cleanEp := path.Clean(strings.TrimPrefix(episodes[0].Path, "/"))
	dir := path.Dir(cleanEp)
	if dir == "." || dir == "" || dir == "/" {
		return nil, nil, "", os.ErrNotExist
	}
	exts := []string{".jpg", ".jpeg", ".png", ".webp"}
	dirs := []string{dir}
	if parent := path.Dir(dir); parent != "." && parent != "" && parent != "/" {
		dirs = append(dirs, parent)
	}
	candidates := make([]string, 0, 32)
	for _, d := range dirs {
		for _, base := range []string{"poster", "tvshow-poster", "tvshow", "folder", "cover"} {
			for _, ext := range exts {
				candidates = append(candidates, path.Join(d, base+ext))
			}
		}
	}
	return l.openFirstValidSidecar(candidates)
}

func (l *Library) openFirstValidSidecar(candidates []string) (*os.File, os.FileInfo, string, error) {
	seen := make(map[string]bool, len(candidates))
	for _, rel := range candidates {
		if seen[rel] {
			continue
		}
		seen[rel] = true
		mediaType := PosterMediaType(rel)
		if mediaType == "" {
			continue
		}
		f, info, err := l.files.Read(rel)
		if err != nil {
			continue
		}
		if !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > maxPosterImageBytes {
			_ = f.Close()
			continue
		}
		var header [12]byte
		n, _ := io.ReadFull(f, header[:])
		if !validImageSignature(header[:n]) {
			_ = f.Close()
			continue
		}
		if _, sErr := f.Seek(0, io.SeekStart); sErr != nil {
			_ = f.Close()
			continue
		}
		return f, info, mediaType, nil
	}
	return nil, nil, "", os.ErrNotExist
}
