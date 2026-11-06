package server

import (
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/cinema"
	"github.com/lengsukq/lightisle/core/internal/gallery"
	"github.com/lengsukq/lightisle/core/internal/mediapending"
)

// An ordinary member can manage only media under that member's configured
// category directories on this exact root generation. A read grant to a
// shared folder does not confer ownership of its retained metadata.
func (a *API) missingMediaScope(r *http.Request, write bool) ([]string, error) {
	if a.rootRuntime == nil || a.rootLease == nil || !a.rootLease.Valid(r.Context()) {
		return nil, auth.ErrStorageUnassigned
	}
	user, ok := a.auth.Identity(token(r))
	if !ok {
		return nil, auth.ErrForbidden
	}
	if user.Role == auth.RoleAdmin {
		return []string{"."}, nil
	}
	policy, err := a.auth.StoragePolicy(token(r), user.ID)
	if err != nil {
		return nil, err
	}
	roots := []string{}
	for _, location := range policy.Locations {
		if location.RootID == a.rootID && location.RootGeneration == a.rootRuntime.root.Generation &&
			a.auth.CanAccessRoot(token(r), a.rootID, location.RelativePath, write, false) {
			roots = append(roots, location.RelativePath)
		}
	}
	return roots, nil
}

func (a *API) missingMediaRecheck(w http.ResponseWriter, r *http.Request) {
	roots, err := a.missingMediaScope(r, false)
	if err != nil {
		storageQuotaError(w, err)
		return
	}
	if len(roots) == 0 {
		http.NotFound(w, r)
		return
	}
	kind := r.PathValue("kind")
	if kind == "photos" {
		kind = "gallery"
	} else if kind != "cinema" {
		http.NotFound(w, r)
		return
	}
	err = a.startRootScanDirs(kind, roots)
	if errors.Is(err, gallery.ErrBusy) || errors.Is(err, cinema.ErrScanning) {
		jsonReply(w, http.StatusConflict, map[string]string{"error": "scan_running"})
		return
	}
	if err != nil {
		jsonReply(w, 503, map[string]string{"error": "missing_media_unavailable"})
		return
	}
	jsonReply(w, http.StatusAccepted, map[string]bool{"started": true})
}

func (a *API) missingMediaList(w http.ResponseWriter, r *http.Request) {
	roots, err := a.missingMediaScope(r, false)
	if err != nil {
		storageQuotaError(w, err)
		return
	}
	limit := 30
	if raw := r.URL.Query().Get("limit"); raw != "" {
		limit, err = strconv.Atoi(raw)
		if err != nil || limit < 1 || limit > 100 {
			jsonReply(w, 400, map[string]string{"error": "invalid_page_size"})
			return
		}
	}
	var after int64
	if raw := r.URL.Query().Get("after"); raw != "" {
		after, err = strconv.ParseInt(raw, 10, 64)
		if err != nil || after < 1 {
			jsonReply(w, 400, map[string]string{"error": "invalid_cursor"})
			return
		}
	}
	var items []mediapending.Item
	var next int64
	var scanState string
	var scanLastDone int64
	switch r.PathValue("kind") {
	case "photos":
		if a.gallery == nil {
			jsonReply(w, 503, map[string]string{"error": "gallery_unavailable"})
			return
		}
		items, next, err = a.gallery.MissingMedia(roots, after, limit)
		status := a.gallery.Status()
		scanState, scanLastDone = missingMediaScanState(status.Running, status.LastDone, status.LastError), status.LastDone
	case "cinema":
		if a.cinema == nil {
			jsonReply(w, 503, map[string]string{"error": "cinema_unavailable"})
			return
		}
		items, next, err = a.cinema.MissingMedia(roots, after, limit)
		status := a.cinema.Status()
		scanState, scanLastDone = missingMediaScanState(status.Running, status.LastDone, status.LastError), status.LastDone
	default:
		http.NotFound(w, r)
		return
	}
	if err != nil {
		jsonReply(w, 503, map[string]string{"error": "missing_media_unavailable"})
		return
	}
	paths := make([]string, len(items))
	for i := range items {
		paths[i] = items[i].Path
	}
	hints, err := a.auth.WritableRootPaths(token(r), a.rootID, paths)
	if err != nil {
		jsonReply(w, 503, map[string]string{"error": "missing_media_unavailable"})
		return
	}
	for i := range items {
		items[i].CanManage = hints[items[i].Path]
	}
	cursor := ""
	if next > 0 {
		cursor = strconv.FormatInt(next, 10)
	}
	jsonReply(w, 200, map[string]any{"items": items, "nextCursor": cursor, "scan": map[string]any{"state": scanState, "lastDone": scanLastDone}})
}

// This is the most recent scan of the library, which may cover only a
// subset of directories. Clients must not treat "finished" as proof that
// every directory visible to the current user has been checked.
func missingMediaScanState(running bool, lastDone int64, lastError string) string {
	if running {
		return "running"
	}
	if lastError != "" {
		return "failed"
	}
	if lastDone == 0 {
		return "not_checked"
	}
	return "finished"
}

func (a *API) missingMediaDiscard(w http.ResponseWriter, r *http.Request) {
	roots, err := a.missingMediaScope(r, true)
	if err != nil {
		storageQuotaError(w, err)
		return
	}
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		jsonReply(w, 400, map[string]string{"error": "invalid_id"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 128)
	defer r.Body.Close()
	var body struct {
		Confirm bool `json:"confirm"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil || !body.Confirm || decoder.Decode(new(any)) != io.EOF {
		jsonReply(w, 400, map[string]string{"error": "confirmation_required"})
		return
	}
	switch r.PathValue("kind") {
	case "photos":
		if a.gallery == nil {
			jsonReply(w, 503, map[string]string{"error": "gallery_unavailable"})
			return
		}
		err = a.gallery.DiscardMissing(id, roots)
	case "cinema":
		if a.cinema == nil {
			jsonReply(w, 503, map[string]string{"error": "cinema_unavailable"})
			return
		}
		err = a.cinema.DiscardMissing(id, roots)
	default:
		http.NotFound(w, r)
		return
	}
	if errors.Is(err, sql.ErrNoRows) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		jsonReply(w, 503, map[string]string{"error": "missing_media_unavailable"})
		return
	}
	jsonReply(w, 200, map[string]bool{"discarded": true})
}

func (a *API) missingMediaAttach(w http.ResponseWriter, r *http.Request) {
	roots, err := a.missingMediaScope(r, true)
	if err != nil {
		storageQuotaError(w, err)
		return
	}
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		jsonReply(w, 400, map[string]string{"error": "invalid_id"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 128)
	defer r.Body.Close()
	var body struct {
		Confirm bool `json:"confirm"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil || !body.Confirm || decoder.Decode(new(any)) != io.EOF {
		jsonReply(w, 400, map[string]string{"error": "confirmation_required"})
		return
	}
	switch r.PathValue("kind") {
	case "photos":
		if a.gallery == nil {
			jsonReply(w, 503, map[string]string{"error": "gallery_unavailable"})
			return
		}
		err = a.gallery.AttachMissing(id, roots)
	case "cinema":
		if a.cinema == nil {
			jsonReply(w, 503, map[string]string{"error": "cinema_unavailable"})
			return
		}
		err = a.cinema.AttachMissing(id, roots)
	default:
		http.NotFound(w, r)
		return
	}
	if errors.Is(err, sql.ErrNoRows) {
		http.NotFound(w, r)
		return
	}
	if errors.Is(err, mediapending.ErrTargetUnavailable) || errors.Is(err, mediapending.ErrConflict) {
		jsonReply(w, http.StatusConflict, map[string]string{"error": err.Error()})
		return
	}
	if err != nil {
		jsonReply(w, 503, map[string]string{"error": "missing_media_unavailable"})
		return
	}
	jsonReply(w, 200, map[string]bool{"attached": true})
}
