package server

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"strconv"

	"github.com/lengsukq/lightisle/core/internal/gallery"
	"github.com/lengsukq/lightisle/core/internal/mediaworker"
)

func (a *API) galleryReady(w http.ResponseWriter) bool {
	if a.gallery == nil {
		jsonReply(w, 503, map[string]string{"error": "gallery_unavailable"})
		return false
	}
	return true
}

func (a *API) galleryPersonalFavorite(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	id, ok := galleryID(w, r)
	if !ok {
		return
	}
	asset, err := a.gallery.Asset(id)
	if err != nil {
		galleryError(w, err)
		return
	}
	if !a.allowMediaAsset(w, r, asset.Path, false) {
		return
	}
	viewer, authenticated := a.auth.Identity(token(r))
	if !authenticated {
		jsonReply(w, 401, map[string]string{"error": "authentication_required"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 128)
	defer r.Body.Close()
	var body struct {
		Favorite *bool `json:"favorite"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil || body.Favorite == nil {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	if err := a.gallery.PersonalFavorite(viewer.ID, id, *body.Favorite); err != nil {
		galleryError(w, err)
		return
	}
	jsonReply(w, 200, map[string]bool{"updated": true})
}
func galleryError(w http.ResponseWriter, err error) {
	code := "gallery_failed"
	status := 500
	switch {
	case errors.Is(err, gallery.ErrBusy):
		code = "scan_running"
		status = 409
	case errors.Is(err, gallery.ErrUnavailable):
		code = "volume_offline"
		status = 503
	case errors.Is(err, gallery.ErrAssetChanged):
		code = "asset_changed_rescan_required"
		status = 409
	case errors.Is(err, mediaworker.ErrUnavailable):
		code = "media_worker_unavailable"
		status = 503
	case errors.Is(err, sql.ErrNoRows):
		code = "not_found"
		status = 404
	}
	jsonReply(w, status, map[string]string{"error": code})
}
func galleryID(w http.ResponseWriter, r *http.Request) (int64, bool) {
	id, e := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if e != nil || id <= 0 {
		jsonReply(w, 400, map[string]string{"error": "invalid_id"})
		return 0, false
	}
	return id, true
}
func (a *API) galleryStatus(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	roots, ok := a.mediaRoots(w, r)
	if !ok {
		return
	}
	n, err := a.gallery.CountScoped(roots)
	if err != nil {
		galleryError(w, err)
		return
	}
	viewer, verified := a.auth.Identity(token(r))
	if !verified {
		return
	}
	status := any(a.gallery.Status())
	if viewer.Role != "admin" {
		// The global scan counter could reveal otherwise private activity.
		status = map[string]any{"running": a.gallery.Status().Running}
	}
	jsonReply(w, 200, map[string]any{"status": status, "count": n})
}
func (a *API) galleryScan(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	var err error
	if a.rootID != "" {
		err = a.startRootScan("gallery")
	} else {
		err = a.gallery.StartScan()
	}
	if err != nil {
		galleryError(w, err)
		return
	}
	jsonReply(w, 202, map[string]bool{"started": true})
}
func (a *API) galleryList(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	roots, ok := a.mediaRoots(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	limit := 60
	if raw := q.Get("limit"); raw != "" {
		parsed, e := strconv.Atoi(raw)
		if e != nil || parsed < 1 || parsed > 120 {
			jsonReply(w, 400, map[string]string{"error": "invalid_limit"})
			return
		}
		limit = parsed
	}
	cursor, _ := strconv.ParseInt(q.Get("cursor"), 10, 64)
	album, _ := strconv.ParseInt(q.Get("album"), 10, 64)
	privateAlbum, _ := strconv.ParseInt(q.Get("privateAlbum"), 10, 64)
	viewer, authenticated := a.auth.Identity(token(r))
	if !authenticated {
		jsonReply(w, 401, map[string]string{"error": "authentication_required"})
		return
	}
	assets, next, err := a.gallery.ListScopedForUserWithPrivateAlbum(viewer.ID, cursor, limit, album, privateAlbum, q.Get("favorites") == "1", q.Get("personal") == "1", roots)
	if err != nil {
		galleryError(w, err)
		return
	}
	withCapabilities, ok := a.galleryAssetCapabilities(w, r, assets)
	if !ok {
		return
	}
	jsonReply(w, 200, map[string]any{"assets": withCapabilities, "nextCursor": next})
}
func (a *API) galleryThumbnail(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	id, ok := galleryID(w, r)
	if !ok {
		return
	}
	asset, err := a.gallery.Asset(id)
	if err != nil {
		galleryError(w, err)
		return
	}
	if !a.allowMediaAsset(w, r, asset.Path, false) {
		return
	}
	var f *os.File
	if asset.Type == "video" {
		f, err = a.gallery.VideoThumbnailContext(r.Context(), id)
	} else {
		f, err = a.gallery.ThumbnailContext(r.Context(), id)
	}
	if err != nil {
		galleryError(w, err)
		return
	}
	defer f.Close()
	stat, e := f.Stat()
	if e != nil {
		galleryError(w, e)
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "private, max-age=86400")
	http.ServeContent(w, r, "thumbnail.jpg", stat.ModTime(), f)
}
func (a *API) galleryFavorite(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	id, ok := galleryID(w, r)
	if !ok {
		return
	}
	asset, err := a.gallery.Asset(id)
	if err != nil {
		galleryError(w, err)
		return
	}
	if !a.allowMediaAsset(w, r, asset.Path, true) {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 128)
	defer r.Body.Close()
	var body struct {
		Favorite *bool `json:"favorite"`
	}
	if json.NewDecoder(r.Body).Decode(&body) != nil || body.Favorite == nil {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	if err := a.gallery.Favorite(id, *body.Favorite); err != nil {
		galleryError(w, err)
		return
	}
	jsonReply(w, 200, map[string]bool{"updated": true})
}
func (a *API) galleryAlbums(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	roots, ok := a.mediaRoots(w, r)
	if !ok {
		return
	}
	albums, err := a.gallery.AlbumsScoped(roots)
	if err != nil {
		galleryError(w, err)
		return
	}
	jsonReply(w, 200, map[string]any{"albums": albums})
}
func (a *API) galleryCreateAlbum(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 512)
	defer r.Body.Close()
	var body struct {
		Name string `json:"name"`
	}
	if json.NewDecoder(r.Body).Decode(&body) != nil {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	album, err := a.gallery.CreateAlbum(body.Name)
	if err != nil {
		jsonReply(w, 400, map[string]string{"error": "invalid_or_duplicate_album"})
		return
	}
	jsonReply(w, 201, album)
}
func (a *API) galleryAddToAlbum(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	id, ok := galleryID(w, r)
	if !ok {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 128)
	defer r.Body.Close()
	var body struct {
		AssetID int64 `json:"assetId"`
	}
	if json.NewDecoder(r.Body).Decode(&body) != nil || body.AssetID <= 0 {
		jsonReply(w, 400, map[string]string{"error": "invalid_asset"})
		return
	}
	if err := a.gallery.AddToAlbum(id, body.AssetID); err != nil {
		galleryError(w, err)
		return
	}
	jsonReply(w, 200, map[string]bool{"added": true})
}
