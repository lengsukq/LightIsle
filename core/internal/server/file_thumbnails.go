package server

import (
	"errors"
	"net/http"
	"strconv"

	"github.com/lengsukq/lightisle/core/internal/gallery"
)

// fileThumbnail serves a 512px list thumbnail or a 2048px preview JPEG for
// any authorized path — the file-manager counterpart of the gallery's
// per-asset endpoint. Authorization follows the same model as previewFile:
// the caller needs read access to the exact path; thumbnails of sources the
// gallery pipeline cannot render answer 404 like any other missing asset.
func (a *API) fileThumbnail(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	if a.gallery == nil {
		jsonReply(w, 503, map[string]string{"error": "gallery_unavailable"})
		return
	}
	path := r.URL.Query().Get("path")
	if path == "" {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	size := gallery.ThumbnailSizeList
	if raw := r.URL.Query().Get("size"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || !gallery.ThumbnailSizeSupported(parsed) {
			jsonReply(w, 400, map[string]string{"error": "invalid_request"})
			return
		}
		size = parsed
	}
	if !a.allowFile(w, r, path, false) {
		return
	}
	if !gallery.ThumbnailPathSupported(path) {
		jsonReply(w, 404, map[string]string{"error": "thumbnail_unsupported"})
		return
	}
	file, err := a.gallery.ThumbnailFromPathContext(r.Context(), path, size)
	if err != nil {
		switch {
		case errors.Is(err, gallery.ErrAssetChanged):
			jsonReply(w, 409, map[string]string{"error": "asset_changed_rescan_required"})
		case errors.Is(err, gallery.ErrUnavailable):
			jsonReply(w, 503, map[string]string{"error": "share_offline"})
		default:
			// Unsupported extensions, oversized sources and renderer
			// failures all read as "no thumbnail" to the client, which
			// falls back to its extension icon.
			jsonReply(w, 404, map[string]string{"error": "thumbnail_unavailable"})
		}
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		jsonReply(w, 404, map[string]string{"error": "thumbnail_unavailable"})
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "private, max-age=86400")
	http.ServeContent(w, r, "thumbnail.jpg", info.ModTime(), file)
}
