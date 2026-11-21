package server

import (
	"database/sql"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"strconv"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/cinema"
	"github.com/lengsukq/lightisle/core/internal/mediaworker"
)

func (a *API) cinemaReady(w http.ResponseWriter) bool {
	if a.cinema == nil {
		writeAPIErrorCode(w, 503, "cinema_unavailable")
		return false
	}
	return true
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
	writeAPIErrorCode(w, status, code)
}

func (a *API) filmID(w http.ResponseWriter, r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id < 1 {
		writeAPIErrorCode(w, 400, "invalid_film_id")
		return 0, false
	}
	return id, true
}

func (a *API) viewerID(w http.ResponseWriter, r *http.Request) int64 {
	u, ok := a.auth.Identity(token(r))
	if !ok {
		writeAPIErrorCode(w, 401, "authentication_required")
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
			writeAPIErrorCode(w, 400, "invalid_limit")
			return
		}
		limit = n
	}
	if raw := q.Get("cursor"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 0 || n > 1000000 {
			writeAPIErrorCode(w, 400, "invalid_cursor")
			return
		}
		offset = n
	}
	kind := q.Get("kind")
	if kind != "" && kind != "all" && kind != "movie" && kind != "series" && kind != "continue" && kind != "unmatched" && kind != "recent" {
		writeAPIErrorCode(w, 400, "invalid_kind")
		return
	}
	watched := strings.TrimSpace(q.Get("watched"))
	if !cinema.ValidWatchFilter(watched) {
		writeAPIErrorCode(w, 400, "invalid_watched")
		return
	}
	sortBy := strings.TrimSpace(q.Get("sort"))
	if !cinema.ValidSortOrder(sortBy) {
		writeAPIErrorCode(w, 400, "invalid_sort")
		return
	}
	searchTerm := q.Get("query")
	if searchTerm == "" {
		searchTerm = q.Get("search")
	}
	if searchTerm == "" {
		searchTerm = q.Get("q")
	}
	var (
		result []cinema.Film
		next   int
		err    error
	)
	if dir := q.Get("dir"); dir != "" {
		result, next, err = a.cinema.ListDirectoryScoped(userID, dir, limit, offset, roots)
	} else {
		result, next, err = a.cinema.ListScopedFiltered(userID, cinema.ListFilter{
			Kind:    kind,
			Query:   searchTerm,
			Watched: watched,
			Sort:    sortBy,
		}, limit, offset, roots)
	}
	if err != nil {
		cinemaError(w, err)
		return
	}
	for index := range result {
		result[index].CanWrite = a.canAccess(token(r), result[index].Path, true, false)
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
	film.CanWrite = a.canAccess(token(r), film.Path, true, false)
	jsonReply(w, 200, film)
}

func (a *API) cinemaLookup(w http.ResponseWriter, r *http.Request) {
	if !a.cinemaReady(w) {
		return
	}
	user := a.viewerID(w, r)
	if user == 0 {
		return
	}
	relPath := strings.TrimSpace(r.URL.Query().Get("path"))
	if relPath == "" {
		writeAPIErrorCode(w, 400, "invalid_request")
		return
	}
	if !a.allowMediaAsset(w, r, relPath, false, "film_not_found") {
		return
	}
	film, err := a.cinema.GetByPath(relPath, user)
	if err != nil {
		cinemaError(w, err)
		return
	}
	film.CanWrite = a.canAccess(token(r), film.Path, true, false)
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
		writeAPIErrorCode(w, 400, "invalid_request")
		return
	}
	if err := a.cinema.Rename(id, item.Title); err != nil {
		cinemaError(w, err)
		return
	}
	jsonReply(w, 200, map[string]bool{"updated": true})
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
		writeAPIErrorCode(w, 400, "invalid_progress")
		return
	}
	if err := a.cinema.SaveProgress(user, id, payload.Position, payload.Duration, payload.Completed); err != nil {
		cinemaError(w, err)
		return
	}
	jsonReply(w, 200, map[string]bool{"saved": true})
}
