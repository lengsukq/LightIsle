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
	"github.com/lengsukq/lightisle/core/internal/ffmpegbin"
)

// transcodeError maps the honest-degradation reason codes of the transcode
// stack. Unknown errors fall back to the shared cinema mapping.
func transcodeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ffmpegbin.ErrNotInstalled):
		jsonReply(w, 503, map[string]string{"error": "transcode_unavailable"})
		return
	case errors.Is(err, cinema.ErrTranscodeBusy):
		jsonReply(w, 429, map[string]string{"error": "transcode_busy"})
		return
	case errors.Is(err, cinema.ErrTranscodeFailed):
		jsonReply(w, 502, map[string]string{"error": "transcode_failed"})
		return
	case errors.Is(err, cinema.ErrTranscodeSpace):
		jsonReply(w, 507, map[string]string{"error": "transcode_insufficient_space"})
		return
	case errors.Is(err, cinema.ErrSubtitleExtract):
		jsonReply(w, 502, map[string]string{"error": "subtitle_extract_failed"})
		return
	case errors.Is(err, cinema.ErrSubtitleTooLarge):
		jsonReply(w, 413, map[string]string{"error": "subtitle_too_large"})
		return
	case errors.Is(err, cinema.ErrTMDBNotConfigured):
		jsonReply(w, 409, map[string]string{"error": "tmdb_token_not_configured"})
		return
	}
	cinemaError(w, err)
}

func (a *API) cinemaTranscodeStatus(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	available, version, reason, active := a.cinema.TranscodeStatus(r.Context())
	payload := map[string]any{
		"available":      available,
		"activeSessions": active,
	}
	if version != "" {
		payload["version"] = version
	}
	if reason != "" {
		payload["reason"] = reason
	}
	jsonReply(w, 200, payload)
}

func (a *API) cinemaHLSSession(w http.ResponseWriter, r *http.Request) {
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
	quality, qualityErr := cinema.NormalizeQuality(r.URL.Query().Get("quality"))
	if qualityErr != nil {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	if film.BrowserPlayback == "verified-direct" && quality == "source" {
		jsonReply(w, 400, map[string]string{"error": "direct_playback_available"})
		return
	}
	start := 0.0
	if raw := r.URL.Query().Get("start"); raw != "" {
		value, err := strconv.ParseFloat(raw, 64)
		if err != nil || math.IsNaN(value) || math.IsInf(value, 0) {
			jsonReply(w, 400, map[string]string{"error": "invalid_request"})
			return
		}
		start = value
	}
	audio := 0
	if raw := r.URL.Query().Get("audio"); raw != "" {
		value, err := strconv.Atoi(raw)
		if err != nil || value < -1 || value > 64 {
			jsonReply(w, 400, map[string]string{"error": "invalid_request"})
			return
		}
		audio = value
	}
	info, err := a.cinema.StartHLSSession(id, start, audio, quality)
	if err != nil {
		transcodeError(w, err)
		return
	}
	jsonReply(w, 200, info)
}

func (a *API) cinemaHLSFile(w http.ResponseWriter, r *http.Request) {
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
	file, info, contentType, err := a.cinema.HLSFile(id, r.PathValue("session"), r.PathValue("file"))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			// Segments appear as the muxer writes them; hls.js retries
			// missing parts by itself.
			jsonReply(w, 404, map[string]string{"error": "hls_segment_pending"})
			return
		}
		transcodeError(w, err)
		return
	}
	defer file.Close()
	w.Header().Set("Content-Type", contentType)
	http.ServeContent(w, r, info.Name(), info.ModTime(), file)
}

func (a *API) cinemaTracks(w http.ResponseWriter, r *http.Request) {
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
	tracks, err := a.cinema.FilmTracks(id)
	if err != nil {
		transcodeError(w, err)
		return
	}
	jsonReply(w, 200, map[string]any{"tracks": tracks})
}

// A subtitle embedded in the film container is extracted to the regenerable
// cache on first request and converted to WebVTT exactly like sidecar SRT
// files. Requests never carry a filename, only a stream index resolved
// through the same ffprobe data.
func (a *API) cinemaEmbeddedSubtitle(w http.ResponseWriter, r *http.Request) {
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
	track, err := strconv.Atoi(r.URL.Query().Get("track"))
	if err != nil || track < 0 {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	file, extension, err := a.cinema.EmbeddedSubtitleFile(id, track)
	if err != nil {
		transcodeError(w, err)
		return
	}
	defer file.Close()
	content, err := io.ReadAll(io.LimitReader(file, (1<<20)+1))
	if err != nil || len(content) > 1<<20 {
		cinemaError(w, cinema.ErrInvalid)
		return
	}
	text := strings.TrimPrefix(strings.ReplaceAll(string(content), string([]byte{13, 10}), string([]byte{10})), string([]byte{239, 187, 191}))
	if extension == ".srt" {
		text = srtToVTT(text)
	}
	w.Header().Set("Content-Type", "text/vtt; charset=utf-8")
	w.Header().Set("Content-Disposition", "inline")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; sandbox")
	w.Header().Set("Cache-Control", "private, no-store")
	_, _ = io.WriteString(w, text)
}

// srtToVTT converts SRT timing lines to WebVTT. Shared by the sidecar and
// embedded subtitle endpoints so both behave identically.
func srtToVTT(text string) string {
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
		return text
	}
	return strings.Join(lines, string([]byte{10}))
}

func (a *API) cinemaSeriesList(w http.ResponseWriter, r *http.Request) {
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
	limit := 60
	if raw := r.URL.Query().Get("limit"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 1 || n > 120 {
			jsonReply(w, 400, map[string]string{"error": "invalid_limit"})
			return
		}
		limit = n
	}
	result, err := a.cinema.ListSeries(userID, limit, roots)
	if err != nil {
		cinemaError(w, err)
		return
	}
	jsonReply(w, 200, map[string]any{"series": result})
}

func (a *API) cinemaSeriesGet(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	seriesID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || seriesID < 1 {
		jsonReply(w, 400, map[string]string{"error": "invalid_series_id"})
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
	jsonReply(w, 200, map[string]any{"series": series, "films": films})
}

func (a *API) cinemaSeriesTMDBMatch(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	seriesID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || seriesID < 1 {
		jsonReply(w, 400, map[string]string{"error": "invalid_series_id"})
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
	token := request.AccessToken
	if token == "" {
		// Fall back to the Keychain-provisioned token; without either, the
		// request fails with the honest not-configured reason.
		if !a.cinema.TMDBTokenConfigured() {
			jsonReply(w, 409, map[string]string{"error": "tmdb_token_not_configured"})
			return
		}
		series, matchErr := a.cinema.MatchSeriesTMDBWithStoredToken(r.Context(), seriesID, request.TMDBID)
		if matchErr != nil {
			cinemaTMDBError(w, matchErr)
			return
		}
		jsonReply(w, 200, series)
		return
	}
	series, err := a.cinema.MatchSeriesTMDB(r.Context(), token, seriesID, request.TMDBID)
	if errors.Is(err, sql.ErrNoRows) {
		jsonReply(w, 404, map[string]string{"error": "series_not_found"})
		return
	}
	if err != nil {
		cinemaTMDBError(w, err)
		return
	}
	jsonReply(w, 200, series)
}

func (a *API) cinemaScrapeStart(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 256)
	defer r.Body.Close()
	var request struct {
		RetryMisses bool `json:"retryMisses"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&request) != nil {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	if err := a.cinema.StartScrape(request.RetryMisses); err != nil {
		transcodeError(w, err)
		return
	}
	jsonReply(w, 202, map[string]bool{"started": true})
}

func (a *API) cinemaScrapeStatus(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	status := a.cinema.Status()
	jsonReply(w, 200, map[string]any{
		"running":        status.Running,
		"operation":      status.Operation,
		"processed":      status.Visited,
		"matched":        status.Found,
		"lastError":      status.LastError,
		"tmdbConfigured": a.cinema.TMDBTokenConfigured(),
	})
}

func (a *API) cinemaHistory(w http.ResponseWriter, r *http.Request) {
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
	limit := 48
	if raw := r.URL.Query().Get("limit"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 1 || n > 120 {
			jsonReply(w, 400, map[string]string{"error": "invalid_limit"})
			return
		}
		limit = n
	}
	offset := 0
	if raw := r.URL.Query().Get("cursor"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 0 || n > 1000000 {
			jsonReply(w, 400, map[string]string{"error": "invalid_cursor"})
			return
		}
		offset = n
	}
	films, next, err := a.cinema.History(userID, limit, offset, roots)
	if err != nil {
		cinemaError(w, err)
		return
	}
	jsonReply(w, 200, map[string]any{"films": films, "nextCursor": next})
}

// cinemaClearHistory removes only the caller's own progress rows.
func (a *API) cinemaClearHistory(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	userID := a.viewerID(w, r)
	if userID == 0 {
		return
	}
	removed, err := a.cinema.ClearHistory(userID)
	if err != nil {
		cinemaError(w, err)
		return
	}
	jsonReply(w, 200, map[string]any{"removed": removed})
}

// cinemaMarkWatched flips the per-user completed flag; marking unwatched
// also resets the stored position.
func (a *API) cinemaMarkWatched(w http.ResponseWriter, r *http.Request) {
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
	r.Body = http.MaxBytesReader(w, r.Body, 128)
	defer r.Body.Close()
	var payload struct {
		Completed bool `json:"completed"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&payload) != nil {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	if err := a.cinema.MarkWatched(user, id, payload.Completed); err != nil {
		cinemaError(w, err)
		return
	}
	updated, err := a.cinema.Get(id, user)
	if err != nil {
		cinemaError(w, err)
		return
	}
	jsonReply(w, 200, updated)
}
