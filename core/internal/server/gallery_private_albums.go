package server

import (
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"

	"github.com/lengsukq/lightisle/core/internal/gallery"
)

func privateAlbumID(w http.ResponseWriter, r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		jsonReply(w, 400, map[string]string{"error": "invalid_album"})
		return 0, false
	}
	return id, true
}
func (a *API) privateAlbumOwner(w http.ResponseWriter, r *http.Request) (int64, bool) {
	identity, ok := a.auth.Identity(token(r))
	if !ok {
		jsonReply(w, 401, map[string]string{"error": "authentication_required"})
		return 0, false
	}
	return identity.ID, true
}
func privateAlbumWriteError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, gallery.ErrAlbumName):
		jsonReply(w, 400, map[string]string{"error": "invalid_album_name"})
	case errors.Is(err, gallery.ErrAlbumDuplicate):
		jsonReply(w, 409, map[string]string{"error": "album_name_exists"})
	case errors.Is(err, gallery.ErrPrivateAlbumLimit):
		jsonReply(w, 409, map[string]string{"error": "private_album_limit"})
	case errors.Is(err, sql.ErrNoRows):
		jsonReply(w, 404, map[string]string{"error": "not_found"})
	default:
		galleryError(w, err)
	}
}
func readPrivateAlbumBody(w http.ResponseWriter, r *http.Request, output any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 512)
	defer r.Body.Close()
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(output) != nil || decoder.Decode(new(any)) != io.EOF {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return false
	}
	return true
}
func (a *API) galleryPrivateAlbums(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	roots, ok := a.mediaRoots(w, r)
	if !ok {
		return
	}
	userID, ok := a.privateAlbumOwner(w, r)
	if !ok {
		return
	}
	albums, err := a.gallery.PrivateAlbumsScoped(userID, roots)
	if err != nil {
		privateAlbumWriteError(w, err)
		return
	}
	jsonReply(w, 200, map[string]any{"albums": albums})
}
func (a *API) galleryCreatePrivateAlbum(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	userID, ok := a.privateAlbumOwner(w, r)
	if !ok {
		return
	}
	var body struct {
		Name string `json:"name"`
	}
	if !readPrivateAlbumBody(w, r, &body) {
		return
	}
	album, err := a.gallery.CreatePrivateAlbum(userID, body.Name)
	if err != nil {
		privateAlbumWriteError(w, err)
		return
	}
	jsonReply(w, 201, album)
}
func (a *API) galleryRenamePrivateAlbum(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	userID, ok := a.privateAlbumOwner(w, r)
	if !ok {
		return
	}
	id, ok := privateAlbumID(w, r)
	if !ok {
		return
	}
	var body struct {
		Name string `json:"name"`
	}
	if !readPrivateAlbumBody(w, r, &body) {
		return
	}
	album, err := a.gallery.RenamePrivateAlbum(userID, id, body.Name)
	if err != nil {
		privateAlbumWriteError(w, err)
		return
	}
	jsonReply(w, 200, album)
}
func (a *API) galleryDeletePrivateAlbum(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	userID, ok := a.privateAlbumOwner(w, r)
	if !ok {
		return
	}
	id, ok := privateAlbumID(w, r)
	if !ok {
		return
	}
	if err := a.gallery.DeletePrivateAlbum(userID, id); err != nil {
		privateAlbumWriteError(w, err)
		return
	}
	jsonReply(w, 200, map[string]bool{"deleted": true})
}
func (a *API) galleryAddToPrivateAlbum(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	userID, ok := a.privateAlbumOwner(w, r)
	if !ok {
		return
	}
	id, ok := privateAlbumID(w, r)
	if !ok {
		return
	}
	var body struct {
		AssetID int64 `json:"assetId"`
	}
	if !readPrivateAlbumBody(w, r, &body) {
		return
	}
	if body.AssetID <= 0 {
		jsonReply(w, 400, map[string]string{"error": "invalid_asset"})
		return
	}
	asset, err := a.gallery.Asset(body.AssetID)
	if err != nil {
		galleryError(w, err)
		return
	}
	if !a.allowMediaAsset(w, r, asset.Path, false) {
		return
	}
	if err := a.gallery.AddToPrivateAlbum(userID, id, body.AssetID); err != nil {
		privateAlbumWriteError(w, err)
		return
	}
	jsonReply(w, 200, map[string]bool{"added": true})
}
func (a *API) galleryRemoveFromPrivateAlbum(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	userID, ok := a.privateAlbumOwner(w, r)
	if !ok {
		return
	}
	id, ok := privateAlbumID(w, r)
	if !ok {
		return
	}
	assetID, err := strconv.ParseInt(r.PathValue("assetID"), 10, 64)
	if err != nil || assetID <= 0 {
		jsonReply(w, 400, map[string]string{"error": "invalid_asset"})
		return
	}
	// Listing a private album never discloses inaccessible source paths.
	// Removing inaccessible/stale items is allowed only by the album owner.
	if err := a.gallery.RemoveFromPrivateAlbum(userID, id, assetID); err != nil {
		privateAlbumWriteError(w, err)
		return
	}
	jsonReply(w, 200, map[string]bool{"removed": true})
}
