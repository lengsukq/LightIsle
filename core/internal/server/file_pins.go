package server

import (
	"encoding/json"
	"errors"
	"io/fs"
	"net/http"
	"path"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

const singleRootSentinelID = "00000000000000000000000000000000"

type filePinResponse struct {
	RootID         string     `json:"rootId"`
	RootGeneration uint64     `json:"rootGeneration"`
	Path           string     `json:"path"`
	Kind           string     `json:"kind"`
	Label          string     `json:"label"`
	PinnedAt       int64      `json:"pinnedAt"`
	Exists         bool       `json:"exists"`
	Size           int64      `json:"size,omitempty"`
	Modified       *time.Time `json:"modified,omitempty"`
	CanWrite       bool       `json:"canWrite"`
}

func (a *API) effectiveRootScope() (string, uint64) {
	if a.rootID != "" {
		gen := a.currentRootGeneration()
		if gen == 0 {
			gen = 1
		}
		return a.rootID, gen
	}
	return singleRootSentinelID, 1
}

func cleanClientRelativePath(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" || trimmed == "." || strings.HasPrefix(trimmed, "/") || strings.ContainsAny(trimmed, "\\\x00") {
		return ""
	}
	cleaned := path.Clean(trimmed)
	if cleaned == "." || cleaned == "" || cleaned != trimmed {
		return ""
	}
	return cleaned
}

func (a *API) filePinsList(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	tok := token(r)
	rootID, gen := a.effectiveRootScope()
	pins, err := a.auth.ListFilePins(tok, rootID, gen)
	if err != nil {
		writeFilePinError(w, err)
		return
	}
	out := make([]filePinResponse, 0, len(pins))
	for _, pin := range pins {
		// Real-time authorization check: revoked paths vanish immediately.
		if !a.canAccess(tok, pin.Path, false, false) {
			continue
		}
		item := filePinResponse{
			RootID:         pin.RootID,
			RootGeneration: pin.RootGeneration,
			Path:           pin.Path,
			Kind:           pin.Kind,
			Label:          pin.Label,
			PinnedAt:       pin.PinnedAt,
			CanWrite:       a.canAccess(tok, pin.Path, true, false),
		}
		info, statErr := a.files.Stat(pin.Path)
		if statErr == nil {
			diskKind := "file"
			if info.IsDir() {
				diskKind = "folder"
			}
			if diskKind == pin.Kind {
				item.Exists = true
				item.Size = info.Size()
				mod := info.ModTime()
				item.Modified = &mod
			}
		} else if !errors.Is(statErr, fs.ErrNotExist) {
			// Treat unexpected stat errors as unavailable without blocking the list.
			item.Exists = false
		}
		out = append(out, item)
	}
	jsonReply(w, http.StatusOK, map[string]any{"pins": out})
}

func (a *API) filePinsAdd(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
	defer r.Body.Close()
	var body struct {
		Path  string `json:"path"`
		Label string `json:"label"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_request")
		return
	}
	cleanPath := cleanClientRelativePath(body.Path)
	if cleanPath == "" {
		writeAPIErrorCode(w, http.StatusBadRequest, "path_not_allowed")
		return
	}
	if !a.allowFile(w, r, cleanPath, false) {
		return
	}
	info, err := a.files.Stat(cleanPath)
	if err != nil {
		fileError(w, err)
		return
	}
	kind := "file"
	if info.IsDir() {
		kind = "folder"
	} else if !info.Mode().IsRegular() {
		writeAPIErrorCode(w, http.StatusBadRequest, "unsupported_file_type")
		return
	}
	rootID, gen := a.effectiveRootScope()
	pin, err := a.auth.UpsertFilePin(token(r), rootID, gen, cleanPath, kind, body.Label)
	if err != nil {
		writeFilePinError(w, err)
		return
	}
	mod := info.ModTime()
	jsonReply(w, http.StatusCreated, map[string]any{
		"pin": filePinResponse{
			RootID:         pin.RootID,
			RootGeneration: pin.RootGeneration,
			Path:           pin.Path,
			Kind:           pin.Kind,
			Label:          pin.Label,
			PinnedAt:       pin.PinnedAt,
			Exists:         true,
			Size:           info.Size(),
			Modified:       &mod,
			CanWrite:       a.canAccess(token(r), cleanPath, true, false),
		},
	})
}

func (a *API) filePinsDelete(w http.ResponseWriter, r *http.Request) {
	cleanPath := cleanClientRelativePath(r.URL.Query().Get("path"))
	if cleanPath == "" {
		writeAPIErrorCode(w, http.StatusBadRequest, "path_not_allowed")
		return
	}
	rootID, gen := a.effectiveRootScope()
	if err := a.auth.DeleteFilePin(token(r), rootID, gen, cleanPath); err != nil {
		writeFilePinError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]any{"removed": true, "path": cleanPath})
}

func writeFilePinError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, auth.ErrInput):
		writeAPIErrorCode(w, http.StatusBadRequest, "invalid_pin_request")
	case errors.Is(err, auth.ErrExists):
		writeAPIErrorCode(w, http.StatusConflict, "pin_limit_reached")
	case errors.Is(err, auth.ErrForbidden):
		writeAPIErrorCode(w, http.StatusForbidden, "file_permission_denied")
	default:
		writeAPIErrorCode(w, http.StatusInternalServerError, "file_pin_error")
	}
}
