package server

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"

	"github.com/lengsukq/lightisle/core/internal/gallery"
)

func galleryAlbumError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, gallery.ErrAlbumName):
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_album_name"})
	case errors.Is(err, gallery.ErrAlbumDuplicate):
		jsonReply(w, http.StatusConflict, map[string]string{"error": "album_name_exists"})
	default:
		galleryError(w, err)
	}
}

func (a *API) galleryRenameAlbum(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	id, ok := galleryID(w, r)
	if !ok {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 512)
	defer r.Body.Close()
	var body struct {
		Name string `json:"name"`
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&body) != nil || decoder.Decode(new(any)) != io.EOF {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_request"})
		return
	}
	album, err := a.gallery.RenameAlbum(id, body.Name)
	if err != nil {
		galleryAlbumError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, album)
}

func (a *API) galleryDeleteAlbum(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	id, ok := galleryID(w, r)
	if !ok {
		return
	}
	if err := a.gallery.DeleteAlbum(id); err != nil {
		galleryAlbumError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]bool{"deleted": true})
}

func (a *API) galleryRemoveFromAlbum(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	id, ok := galleryID(w, r)
	if !ok {
		return
	}
	assetID, err := strconv.ParseInt(r.PathValue("assetID"), 10, 64)
	if err != nil || assetID <= 0 {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_asset"})
		return
	}
	if err := a.gallery.RemoveFromAlbum(id, assetID); err != nil {
		galleryAlbumError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]bool{"removed": true})
}
