package server

import (
	"bufio"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"os"
	"strconv"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/cinema"
	"github.com/lengsukq/lightisle/core/internal/mediaworker"
)

func (a *API) cinemaReady(w http.ResponseWriter) bool {
	if a.cinema == nil {
		jsonReply(w, 503, map[string]string{"error": "cinema_unavailable"})
		return false
	}
	return true
}

func cinemaTMDBError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, cinema.ErrInvalid):
		jsonReply(w, 400, map[string]string{"error": "invalid_tmdb_request"})
	case errors.Is(err, sql.ErrNoRows):
		jsonReply(w, 404, map[string]string{"error": "film_not_found"})
	default:
		// Upstream auth, timeout, rate limiting or malformed result.
		// Never include access-token-bearing request details in responses.
		jsonReply(w, 502, map[string]string{"error": "tmdb_upstream_failed"})
	}
}

func (a *API) cinemaTMDBSearch(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	id, ok := a.filmID(w, r)
	if !ok {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	defer r.Body.Close()
	var request struct {
		AccessToken string `json:"accessToken"`
		Query       string `json:"query"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil {
		jsonReply(w, 400, map[string]string{"error": "invalid_tmdb_request"})
		return
	}
	result, err := a.cinema.SearchTMDB(r.Context(), request.AccessToken, id, request.Query)
	if err != nil {
		cinemaTMDBError(w, err)
		return
	}
	jsonReply(w, 200, map[string]any{"results": result})
}

func (a *API) cinemaTMDBMatch(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	id, ok := a.filmID(w, r)
	if !ok {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	defer r.Body.Close()
	var request struct {
		AccessToken string `json:"accessToken"`
		TMDBID      int64  `json:"tmdbId"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil || request.TMDBID < 1 {
		jsonReply(w, 400, map[string]string{"error": "invalid_tmdb_request"})
		return
	}
	film, err := a.cinema.MatchTMDB(r.Context(), request.AccessToken, id, request.TMDBID)
	if err != nil {
		cinemaTMDBError(w, err)
		return
	}
	jsonReply(w, 200, film)
}

func (a *API) cinemaImportNFO(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	id, ok := a.filmID(w, r)
	if !ok {
		return
	}
	film, err := a.cinema.ImportLocalNFO(id)
	if errors.Is(err, sql.ErrNoRows) {
		jsonReply(w, 404, map[string]string{"error": "film_not_found"})
		return
	}
	if errors.Is(err, os.ErrNotExist) {
		jsonReply(w, 404, map[string]string{"error": "nfo_not_found"})
		return
	}
	if errors.Is(err, cinema.ErrInvalid) {
		jsonReply(w, 400, map[string]string{"error": "invalid_nfo"})
		return
	}
	if err != nil {
		cinemaError(w, err)
		return
	}
	jsonReply(w, 200, film)
}
func cinemaError(w http.ResponseWriter, err error) {
	status := 500
	code := "cinema_failed"
	switch {
	case errors.Is(err, cinema.ErrOffline):
		status = 503
		code = "share_offline"
	case errors.Is(err, cinema.ErrScanning):
		status = 409
		code = "scan_running"
	case errors.Is(err, cinema.ErrInvalid):
		status = 400
		code = "invalid_request"
	case errors.Is(err, cinema.ErrAssetChanged):
		status = 409
		code = "asset_changed_rescan_required"
	case errors.Is(err, mediaworker.ErrUnavailable):
		status = 503
		code = "media_worker_unavailable"
	case errors.Is(err, sql.ErrNoRows):
		status = 404
		code = "film_not_found"
	}
	jsonReply(w, status, map[string]string{"error": code})
}
func (a *API) filmID(w http.ResponseWriter, r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id < 1 {
		jsonReply(w, 400, map[string]string{"error": "invalid_film_id"})
		return 0, false
	}
	return id, true
}
func (a *API) viewerID(w http.ResponseWriter, r *http.Request) int64 {
	u, ok := a.auth.Identity(token(r))
	if !ok {
		jsonReply(w, 401, map[string]string{"error": "authentication_required"})
		return 0
	}
	return u.ID
}
func (a *API) cinemaList(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
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
	q := r.URL.Query()
	limit := 60
	offset := 0
	if raw := q.Get("limit"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 1 || n > 120 {
			jsonReply(w, 400, map[string]string{"error": "invalid_limit"})
			return
		}
		limit = n
	}
	if raw := q.Get("cursor"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 0 || n > 1000000 {
			jsonReply(w, 400, map[string]string{"error": "invalid_cursor"})
			return
		}
		offset = n
	}
	kind := q.Get("kind")
	if kind != "" && kind != "movie" && kind != "series" && kind != "continue" {
		jsonReply(w, 400, map[string]string{"error": "invalid_kind"})
		return
	}
	result, next, err := a.cinema.ListScoped(userID, kind, q.Get("query"), limit, offset, roots)
	if err != nil {
		cinemaError(w, err)
		return
	}
	jsonReply(w, 200, map[string]any{"films": result, "nextCursor": next})
}
func (a *API) cinemaStatus(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	viewer, ok := a.auth.Identity(token(r))
	if !ok {
		return
	}
	if viewer.Role != "admin" {
		// The whole-library counters reveal activity in other users' folders.
		jsonReply(w, 200, map[string]any{"status": map[string]any{"running": a.cinema.Status().Running}})
		return
	}
	jsonReply(w, 200, map[string]any{"status": a.cinema.Status()})
}
func (a *API) cinemaScan(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	var err error
	if a.rootID != "" {
		err = a.startRootScan("cinema")
	} else {
		err = a.cinema.StartScan()
	}
	if err != nil {
		cinemaError(w, err)
		return
	}
	jsonReply(w, 202, map[string]bool{"started": true})
}
func (a *API) cinemaGet(w http.ResponseWriter, r *http.Request) {
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
	jsonReply(w, 200, film)
}
func (a *API) cinemaRename(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	id, ok := a.filmID(w, r)
	if !ok {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	defer r.Body.Close()
	var item struct {
		Title string `json:"title"`
	}
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if d.Decode(&item) != nil {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	if err := a.cinema.Rename(id, item.Title); err != nil {
		cinemaError(w, err)
		return
	}
	jsonReply(w, 200, map[string]bool{"updated": true})
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
	file, info, film, err := a.cinema.Read(id, user)
	if err != nil {
		cinemaError(w, err)
		return
	}
	defer file.Close()
	if !film.Playable {
		jsonReply(w, 415, map[string]string{"error": "browser_playback_unsupported", "suggestion": "download_original_file"})
		return
	}
	w.Header().Set("Content-Type", film.Mime)
	w.Header().Set("Accept-Ranges", "bytes")
	// No Content-Disposition: attachment — permit <video> progressive playback.
	http.ServeContent(w, r, info.Name(), info.ModTime(), file)
}

func (a *API) cinemaPoster(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) || !a.galleryReady(w) {
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
	if requested.ProbeStatus == "unsupported" {
		jsonReply(w, http.StatusUnsupportedMediaType, map[string]string{"error": "poster_unsupported"})
		return
	}
	if requested.ProbeStatus != "ready" {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "poster_unavailable"})
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
	stat, err := poster.Stat()
	if err != nil {
		galleryError(w, err)
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "private, max-age=86400")
	http.ServeContent(w, r, "poster.jpg", stat.ModTime(), poster)
}

func (a *API) cinemaProgress(w http.ResponseWriter, r *http.Request) {
	a.cinemaGet(w, r)
}
func (a *API) cinemaSaveProgress(w http.ResponseWriter, r *http.Request) {
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
	r.Body = http.MaxBytesReader(w, r.Body, 256)
	defer r.Body.Close()
	var payload struct {
		Position  float64 `json:"position"`
		Duration  float64 `json:"duration"`
		Completed bool    `json:"completed"`
	}
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if d.Decode(&payload) != nil || math.IsNaN(payload.Position) || math.IsInf(payload.Position, 0) ||
		math.IsNaN(payload.Duration) || math.IsInf(payload.Duration, 0) {
		jsonReply(w, 400, map[string]string{"error": "invalid_progress"})
		return
	}
	if err := a.cinema.SaveProgress(user, id, payload.Position, payload.Duration, payload.Completed); err != nil {
		cinemaError(w, err)
		return
	}
	jsonReply(w, 200, map[string]bool{"saved": true})
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
	content, err := io.ReadAll(io.LimitReader(file, (1<<20)+1))
	if err != nil || len(content) > 1<<20 {
		cinemaError(w, cinema.ErrInvalid)
		return
	}
	text := strings.TrimPrefix(strings.ReplaceAll(string(content), string([]byte{13, 10}), string([]byte{10})), string([]byte{239, 187, 191}))
	if format == ".srt" {
		var lines []string
		lines = append(lines, "WEBVTT", "", "")
		scanner := bufio.NewScanner(strings.NewReader(text))
		scanner.Buffer(make([]byte, 4096), 1<<20)
		for scanner.Scan() {
			line := scanner.Text()
			// SRT timestamps use a decimal comma; VTT uses a period.
			if strings.Contains(line, " --> ") {
				line = strings.ReplaceAll(line, ",", ".")
			}
			lines = append(lines, line)
		}
		if scanner.Err() != nil {
			cinemaError(w, cinema.ErrInvalid)
			return
		}
		text = strings.Join(lines, string([]byte{10}))
	}
	w.Header().Set("Content-Type", "text/vtt; charset=utf-8")
	w.Header().Set("Content-Disposition", "inline")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; sandbox")
	w.Header().Set("Cache-Control", "private, no-store")
	_, _ = io.WriteString(w, text)
}
