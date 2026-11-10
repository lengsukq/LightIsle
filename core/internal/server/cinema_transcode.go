package server

import (
	"bufio"
	"bytes"
	"database/sql"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"strconv"
	"strings"
	"unicode/utf16"
	"unicode/utf8"

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
	content, err := io.ReadAll(io.LimitReader(file, (2<<20)+1))
	if err != nil || len(content) > 2<<20 {
		cinemaError(w, cinema.ErrInvalid)
		return
	}
	text, err := subtitleBytesToVTT(content, extension)
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

func decodeSubtitleText(raw []byte) string {
	var decoded string
	switch {
	case bytes.HasPrefix(raw, []byte{0xFF, 0xFE}):
		body := raw[2:]
		u16 := make([]uint16, len(body)/2)
		for i := range u16 {
			u16[i] = binary.LittleEndian.Uint16(body[i*2 : i*2+2])
		}
		decoded = string(utf16.Decode(u16))
	case bytes.HasPrefix(raw, []byte{0xFE, 0xFF}):
		body := raw[2:]
		u16 := make([]uint16, len(body)/2)
		for i := range u16 {
			u16[i] = binary.BigEndian.Uint16(body[i*2 : i*2+2])
		}
		decoded = string(utf16.Decode(u16))
	default:
		trimmed := bytes.TrimPrefix(raw, []byte{0xEF, 0xBB, 0xBF})
		if utf8.Valid(trimmed) {
			decoded = string(trimmed)
		} else {
			decoded = strings.ToValidUTF8(string(trimmed), "")
		}
	}
	decoded = strings.ReplaceAll(decoded, "\r\n", "\n")
	return strings.ReplaceAll(decoded, "\r", "\n")
}

func subtitleBytesToVTT(raw []byte, format string) (string, error) {
	text := decodeSubtitleText(raw)
	switch strings.ToLower(format) {
	case ".srt":
		return srtToVTT(text), nil
	case ".ass", ".ssa":
		return assToVTT(text), nil
	default:
		return text, nil
	}
}

// srtToVTT converts SRT timing lines to WebVTT. Shared by the sidecar and
// embedded subtitle endpoints so both behave identically.
func srtToVTT(text string) string {
	var lines []string
	lines = append(lines, "WEBVTT", "", "")
	scanner := bufio.NewScanner(strings.NewReader(text))
	scanner.Buffer(make([]byte, 4096), 2<<20)
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
	return strings.Join(lines, "\n")
}

func assTimeToVTT(raw string) (string, bool) {
	parts := strings.Split(strings.TrimSpace(raw), ":")
	if len(parts) != 3 {
		return "", false
	}
	h, errH := strconv.Atoi(parts[0])
	m, errM := strconv.Atoi(parts[1])
	if errH != nil || errM != nil || h < 0 || m < 0 || m >= 60 {
		return "", false
	}
	secPart := strings.ReplaceAll(parts[2], ",", ".")
	secPieces := strings.SplitN(secPart, ".", 2)
	s, errS := strconv.Atoi(secPieces[0])
	if errS != nil || s < 0 || s >= 60 {
		return "", false
	}
	frac := "000"
	if len(secPieces) == 2 {
		digits := secPieces[1]
		for len(digits) < 3 {
			digits += "0"
		}
		if len(digits) > 3 {
			digits = digits[:3]
		}
		frac = digits
	}
	return fmt.Sprintf("%02d:%02d:%02d.%s", h, m, s, frac), true
}

func stripASSOverrides(raw string) string {
	var b strings.Builder
	depth := 0
	for _, r := range raw {
		if r == '{' {
			depth++
			continue
		}
		if r == '}' {
			if depth > 0 {
				depth--
			}
			continue
		}
		if depth == 0 {
			b.WriteRune(r)
		}
	}
	clean := b.String()
	clean = strings.ReplaceAll(clean, `\N`, "\n")
	clean = strings.ReplaceAll(clean, `\n`, "\n")
	clean = strings.ReplaceAll(clean, `\h`, " ")
	return strings.TrimSpace(clean)
}

func assToVTT(text string) string {
	out := []string{"WEBVTT", ""}
	startIdx, endIdx, textIdx, fieldCount := 1, 2, 9, 10
	scanner := bufio.NewScanner(strings.NewReader(text))
	scanner.Buffer(make([]byte, 4096), 2<<20)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		lower := strings.ToLower(line)
		if strings.HasPrefix(lower, "format:") {
			cols := strings.Split(strings.TrimSpace(line[len("format:"):]), ",")
			if len(cols) >= 3 {
				fieldCount = len(cols)
				for i, col := range cols {
					switch strings.ToLower(strings.TrimSpace(col)) {
					case "start":
						startIdx = i
					case "end":
						endIdx = i
					case "text":
						textIdx = i
					}
				}
			}
			continue
		}
		if !strings.HasPrefix(lower, "dialogue:") {
			continue
		}
		body := strings.TrimSpace(line[len("dialogue:"):])
		fields := strings.SplitN(body, ",", fieldCount)
		if len(fields) <= textIdx || len(fields) <= startIdx || len(fields) <= endIdx {
			continue
		}
		startVTT, okStart := assTimeToVTT(fields[startIdx])
		endVTT, okEnd := assTimeToVTT(fields[endIdx])
		if !okStart || !okEnd {
			continue
		}
		caption := stripASSOverrides(fields[textIdx])
		if caption == "" {
			continue
		}
		out = append(out, startVTT+" --> "+endVTT, caption, "")
	}
	return strings.Join(out, "\n")
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
	result, err := a.cinema.ListSeriesMatching(userID, limit, roots, r.URL.Query().Get("query"))
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
