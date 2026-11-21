package server

import (
	"errors"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/cinema"
)

func directStreamMime(filmPath, currentMime string) string {
	if currentMime != "" {
		return currentMime
	}
	lower := strings.ToLower(filmPath)
	switch {
	case strings.HasSuffix(lower, ".mp4"), strings.HasSuffix(lower, ".m4v"):
		return "video/mp4"
	case strings.HasSuffix(lower, ".webm"):
		return "video/webm"
	case strings.HasSuffix(lower, ".mov"):
		return "video/quicktime"
	case strings.HasSuffix(lower, ".mkv"):
		return "video/x-matroska"
	case strings.HasSuffix(lower, ".avi"):
		return "video/x-msvideo"
	case strings.HasSuffix(lower, ".ts"):
		return "video/mp2t"
	default:
		return "application/octet-stream"
	}
}

func (a *API) cinemaStream(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	id, ok := a.filmID(w, r)
	if !ok {
		return
	}
	user := a.viewerID(w, r)
	if user == 0 {
		return
	}
	requested, err := a.cinema.Get(id, user)
	if err != nil {
		cinemaError(w, err)
		return
	}
	if !a.allowMediaAsset(w, r, requested.Path, false, "film_not_found") {
		return
	}
	if cinema.IsStrmPath(requested.Path) {
		targetURL, _, strmErr := a.cinema.ReadStrmTarget(id, user)
		if strmErr != nil {
			if errors.Is(strmErr, cinema.ErrForbiddenStrmURL) {
				writeAPIErrorCode(w, http.StatusForbidden, "forbidden_strm_url")
				return
			}
			writeAPIErrorCode(w, http.StatusUnprocessableEntity, "invalid_strm_url")
			return
		}
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Cache-Control", "private, no-store")
		http.Redirect(w, r, targetURL, http.StatusTemporaryRedirect)
		return
	}
	file, info, film, err := a.cinema.Read(id, user)
	if err != nil {
		cinemaError(w, err)
		return
	}
	defer file.Close()
	allowDirect := r.URL.Query().Get("direct") == "1"
	if !film.Playable && !allowDirect {
		jsonReply(w, 415, map[string]string{"error": "browser_playback_unsupported", "suggestion": "download_original_file"})
		return
	}
	w.Header().Set("Content-Type", directStreamMime(film.Path, film.Mime))
	w.Header().Set("Accept-Ranges", "bytes")
	// No Content-Disposition: attachment — permit <video> and native decoders progressive Range playback.
	http.ServeContent(w, r, info.Name(), info.ModTime(), file)
}

func serveCinemaPosterAsset(w http.ResponseWriter, r *http.Request, name string, info os.FileInfo, mediaType string, f *os.File) {
	etag := `"` + strconv.FormatInt(info.Size(), 16) + `-` + strconv.FormatInt(info.ModTime().UnixNano(), 16) + `"`
	w.Header().Set("Cache-Control", "private, max-age=604800, stale-while-revalidate=86400")
	w.Header().Set("Content-Type", mediaType)
	w.Header().Set("Content-Disposition", "inline")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("ETag", etag)
	if (r.Method == http.MethodGet || r.Method == http.MethodHead) && ifNoneMatchContains(r.Header.Get("If-None-Match"), etag) {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	http.ServeContent(w, r, name, info.ModTime(), f)
}

func (a *API) cinemaTMDBPosterProxy(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	if a.viewerID(w, r) == 0 {
		return
	}
	raw := r.URL.Query().Get("path")
	if raw == "" {
		raw = r.URL.Query().Get("url")
	}
	f, info, mediaType, err := a.cinema.FetchOrCacheTMDBPoster(r.Context(), raw)
	if err != nil {
		if errors.Is(err, cinema.ErrInvalid) {
			writeAPIErrorCode(w, http.StatusBadRequest, "invalid_poster_path")
			return
		}
		writeAPIErrorCode(w, http.StatusBadGateway, "tmdb_poster_unavailable")
		return
	}
	defer f.Close()
	serveCinemaPosterAsset(w, r, info.Name(), info, mediaType, f)
}

func (a *API) cinemaSeriesPoster(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	seriesID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || seriesID < 1 {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_series_id")
		return
	}
	roots, scoped := a.mediaRoots(w, r)
	if !scoped {
		return
	}
	userID := a.viewerID(w, r)
	if userID == 0 {
		return
	}
	series, films, err := a.cinema.GetSeries(userID, seriesID, roots)
	if err != nil {
		cinemaError(w, err)
		return
	}
	posterTarget := series.PosterURL
	if posterTarget == "" {
		for _, ep := range films {
			if ep.PosterURL != "" {
				posterTarget = ep.PosterURL
				break
			}
		}
	}
	if posterTarget != "" {
		if f, info, mediaType, pErr := a.cinema.FetchOrCacheTMDBPoster(r.Context(), posterTarget); pErr == nil {
			defer f.Close()
			serveCinemaPosterAsset(w, r, info.Name(), info, mediaType, f)
			return
		}
	}
	if f, info, mediaType, sErr := a.cinema.ReadSeriesSidecarPoster(films); sErr == nil {
		defer f.Close()
		serveCinemaPosterAsset(w, r, info.Name(), info, mediaType, f)
		return
	}
	if a.gallery != nil {
		for _, ep := range films {
			if cinema.IsStrmPath(ep.Path) || ep.ProbeStatus != "ready" {
				continue
			}
			file, info, film, rErr := a.cinema.Read(ep.ID, userID)
			if rErr != nil {
				continue
			}
			poster, tErr := a.gallery.VideoThumbnailFromFileContext(r.Context(), film.Path, file, info)
			_ = file.Close()
			if tErr == nil {
				defer poster.Close()
				serveCachedJPEG(w, r, "poster.jpg", info.ModTime(), poster)
				return
			}
		}
	}
	writeAPIErrorCode(w, http.StatusNotFound, "poster_unavailable")
}

func (a *API) cinemaPoster(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	id, ok := a.filmID(w, r)
	if !ok {
		return
	}
	user := a.viewerID(w, r)
	if user == 0 {
		return
	}
	requested, err := a.cinema.Get(id, user)
	if err != nil {
		cinemaError(w, err)
		return
	}
	if !a.allowMediaAsset(w, r, requested.Path, false, "film_not_found") {
		return
	}
	// 1. Scraped TMDB poster (cached locally on NAS so mobile clients work even when image.tmdb.org is unreachable).
	tmdbFailed := false
	if requested.PosterURL != "" {
		if f, info, mediaType, pErr := a.cinema.FetchOrCacheTMDBPoster(r.Context(), requested.PosterURL); pErr == nil {
			defer f.Close()
			serveCinemaPosterAsset(w, r, info.Name(), info, mediaType, f)
			return
		}
		tmdbFailed = true
	}
	// 2. Local sidecar poster alongside the movie/episode ({stem}-poster.jpg, poster.jpg, folder.jpg).
	if f, info, mediaType, sErr := a.cinema.ReadSidecarPoster(requested); sErr == nil {
		defer f.Close()
		serveCinemaPosterAsset(w, r, info.Name(), info, mediaType, f)
		return
	}
	// 3. Fallback to extracted video frame thumbnail when probe is ready.
	if !a.galleryReady(w) {
		return
	}
	if cinema.IsStrmPath(requested.Path) || requested.ProbeStatus == "unsupported" {
		if tmdbFailed {
			writeAPIErrorCode(w, http.StatusBadGateway, "tmdb_poster_unavailable")
			return
		}
		writeAPIErrorCode(w, http.StatusUnsupportedMediaType, "poster_unsupported")
		return
	}
	if requested.ProbeStatus != "ready" {
		if tmdbFailed {
			writeAPIErrorCode(w, http.StatusBadGateway, "tmdb_poster_unavailable")
			return
		}
		writeAPIErrorCode(w, http.StatusServiceUnavailable, "poster_unavailable")
		return
	}
	file, info, film, err := a.cinema.Read(id, user)
	if err != nil {
		cinemaError(w, err)
		return
	}
	defer file.Close()
	poster, err := a.gallery.VideoThumbnailFromFileContext(r.Context(), film.Path, file, info)
	if err != nil {
		galleryError(w, err)
		return
	}
	defer poster.Close()
	serveCachedJPEG(w, r, "poster.jpg", info.ModTime(), poster)
}

// A subtitle may be present next to a film as {stem}.vtt or
// {stem}.zh.vtt, {stem}.en.srt, etc. Requests never take a filename,
// preventing an authenticated user from probing arbitrary file paths.
func (a *API) cinemaSubtitle(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	id, ok := a.filmID(w, r)
	if !ok {
		return
	}
	user := a.viewerID(w, r)
	if user == 0 {
		return
	}
	film, err := a.cinema.Get(id, user)
	if err != nil {
		cinemaError(w, err)
		return
	}
	if !a.allowMediaAsset(w, r, film.Path, false, "film_not_found") {
		return
	}
	file, format, err := a.cinema.FindSubtitle(film, r.URL.Query().Get("lang"))
	if err != nil {
		cinemaError(w, err)
		return
	}
	defer file.Close()
	content, err := io.ReadAll(io.LimitReader(file, (2<<20)+1))
	if err != nil || len(content) > 2<<20 {
		cinemaError(w, cinema.ErrInvalid)
		return
	}
	text, err := subtitleBytesToVTT(content, format)
	if err != nil {
		cinemaError(w, cinema.ErrInvalid)
		return
	}
	w.Header().Set("Content-Type", "text/vtt; charset=utf-8")
	w.Header().Set("Content-Disposition", "inline")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; sandbox")
	w.Header().Set("Cache-Control", "private, no-store")
	_, _ = io.WriteString(w, text)
}
