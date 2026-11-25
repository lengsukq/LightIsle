package server

import (
	"encoding/json"
	"net/http"

	"github.com/lengsukq/lightisle/core/internal/gallery"
)

func (a *API) galleryUpdateMetadata(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
	defer r.Body.Close()

	var body struct {
		IDs           []int64  `json:"ids"`
		TakenAt       *int64   `json:"takenAt,omitempty"`
		CapturedAt    *string  `json:"capturedAt,omitempty"`
		Latitude      *float64 `json:"latitude,omitempty"`
		Longitude     *float64 `json:"longitude,omitempty"`
		ClearLocation bool     `json:"clearLocation,omitempty"`
		Reset         bool     `json:"reset,omitempty"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil || len(body.IDs) == 0 || len(body.IDs) > 100 {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_request")
		return
	}

	// Verify write authorization on every requested asset before mutating any row.
	for _, id := range body.IDs {
		if id <= 0 {
			writeAPIErrorCode(w, http.StatusBadRequest, "invalid_id")
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
	}

	patch := gallery.MetadataOverridePatch{
		TakenAt:       body.TakenAt,
		CapturedAt:    body.CapturedAt,
		Latitude:      body.Latitude,
		Longitude:     body.Longitude,
		ClearLocation: body.ClearLocation,
		Reset:         body.Reset,
	}
	updated, err := a.gallery.ApplyMetadataOverrides(body.IDs, patch)
	if err != nil {
		galleryError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"updated": updated})
}
