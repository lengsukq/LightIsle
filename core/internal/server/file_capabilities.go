package server

import (
	"net/http"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/gallery"
)

type fileEntryWithCapabilities struct {
	files.Entry
	CanWrite bool `json:"canWrite"`
}

func (a *API) fileEntryCapabilities(w http.ResponseWriter, r *http.Request, base string, entries []files.Entry) ([]fileEntryWithCapabilities, bool, bool) {
	paths := make([]string, 0, len(entries)+1)
	paths = append(paths, base)
	for _, entry := range entries {
		paths = append(paths, entry.Path)
	}
	var hints map[string]bool
	var err error
	if a.rootID != "" {
		hints, err = a.auth.WritableRootPaths(token(r), a.rootID, paths)
	} else {
		hints, err = a.auth.WritablePaths(token(r), paths)
	}
	if err != nil {
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "file_permission_denied"})
		return nil, false, false
	}
	result := make([]fileEntryWithCapabilities, 0, len(entries))
	for _, entry := range entries {
		result = append(result, fileEntryWithCapabilities{Entry: entry, CanWrite: hints[entry.Path]})
	}
	return result, hints[base], true
}

type galleryAssetWithCapabilities struct {
	gallery.Asset
	CanWrite bool `json:"canWrite"`
}

func (a *API) galleryAssetCapabilities(w http.ResponseWriter, r *http.Request, assets []gallery.Asset) ([]galleryAssetWithCapabilities, bool) {
	paths := make([]string, 0, len(assets))
	for _, asset := range assets {
		paths = append(paths, asset.Path)
	}
	var hints map[string]bool
	var err error
	if a.rootID != "" {
		hints, err = a.auth.WritableRootPaths(token(r), a.rootID, paths)
	} else {
		hints, err = a.auth.WritablePaths(token(r), paths)
	}
	if err != nil {
		jsonReply(w, http.StatusForbidden, map[string]string{"error": "file_permission_denied"})
		return nil, false
	}
	result := make([]galleryAssetWithCapabilities, 0, len(assets))
	for _, asset := range assets {
		result = append(result, galleryAssetWithCapabilities{Asset: asset, CanWrite: hints[asset.Path]})
	}
	return result, true
}
