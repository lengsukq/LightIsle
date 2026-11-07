package server

import (
	"fmt"
	"log/slog"
	"mime"
	"net/http"
	"path"
	"strconv"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

// gallerySelectedArchive streams a bounded selection of indexed originals.
// IDs keep browser URLs small and never grant access beyond the current user.
func (a *API) gallerySelectedArchive(w http.ResponseWriter, r *http.Request) {
	if !a.galleryReady(w) {
		return
	}
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	raw := r.URL.Query().Get("ids")
	parts := strings.Split(raw, ",")
	if raw == "" || len(raw) > 1100 || len(parts) > 50 {
		jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_archive_selection"})
		return
	}
	ids := make([]int64, 0, len(parts))
	seen := make(map[int64]bool, len(parts))
	for _, part := range parts {
		id, err := strconv.ParseInt(part, 10, 64)
		if err != nil || id <= 0 || seen[id] {
			jsonReply(w, http.StatusBadRequest, map[string]string{"error": "invalid_archive_selection"})
			return
		}
		seen[id] = true
		ids = append(ids, id)
	}
	if !acquireArchiveSlot(w, false) {
		return
	}
	defer func() { <-archiveSlots }()
	plan := make([]archiveItem, 0, len(ids))
	remaining := archiveMaxBytes
	for index, id := range ids {
		if r.Context().Err() != nil {
			return
		}
		if a.rootID != "" && (a.rootLease == nil || !a.rootLease.Valid(r.Context())) {
			jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "root_unavailable"})
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
		if asset.Size < 0 || asset.Size > remaining {
			jsonReply(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "archive_limit_exceeded"})
			return
		}
		remaining -= asset.Size
		f, info, err := a.files.Read(asset.Path)
		if err != nil {
			fileError(w, err)
			return
		}
		closeErr := f.Close()
		if closeErr != nil || asset.FileIdentity == "" || files.MediaFileIdentity(info) != asset.FileIdentity ||
			info.Size() != asset.Size || info.ModTime().UnixNano() != asset.Modified {
			jsonReply(w, http.StatusConflict, map[string]string{"error": "asset_changed_rescan_required"})
			return
		}
		plan = append(plan, archiveItem{path: asset.Path, name: fmt.Sprintf("%02d_%s", index+1, path.Base(asset.Path)),
			size: asset.Size, modified: time.Unix(0, asset.Modified), identity: asset.FileIdentity})
	}
	if a.rootID != "" && (a.rootLease == nil || !a.rootLease.Valid(r.Context())) {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "root_unavailable"})
		return
	}
	for _, item := range plan {
		if !a.canAccess(token(r), item.path, false, false) {
			jsonReply(w, http.StatusNotFound, map[string]string{"error": "not_found"})
			return
		}
	}
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": "LightIsle-photos.zip"}))
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	if err := a.writeFolderZip(w, r, plan, func(p string) bool {
		return (a.rootID == "" || a.rootLease != nil && a.rootLease.Valid(r.Context())) && a.canAccess(token(r), p, false, false)
	}); err != nil {
		slog.Warn("selected photo archive interrupted", "error", err)
		panic(http.ErrAbortHandler)
	}
}
