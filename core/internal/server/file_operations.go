package server

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"net/http"
	"sort"
	"strconv"

	"github.com/lengsukq/lightisle/core/internal/files"
)

type spotlightSearchProvider interface {
	SearchSpotlightOrFallback(context.Context, string, string, int) ([]files.Entry, bool, error)
}

func (a *API) searchFiles(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	engine := r.URL.Query().Get("engine")
	if engine != "" && engine != "spotlight" {
		jsonReply(w, 400, map[string]string{"error": "invalid_search_engine"})
		return
	}
	base := r.URL.Query().Get("path")
	if base == "" {
		base = "."
	}
	if a.auth == nil || !a.canSee(token(r), base) {
		jsonReply(w, 403, map[string]string{"error": "file_permission_denied"})
		return
	}
	limit := 100
	if raw := r.URL.Query().Get("limit"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 1 || n > 200 {
			jsonReply(w, 400, map[string]string{"error": "invalid_limit"})
			return
		}
		limit = n
	}
	roots, err := a.searchRoots(token(r), base)
	if err != nil {
		jsonReply(w, 403, map[string]string{"error": "file_permission_denied"})
		return
	}
	visible := make([]files.Entry, 0, limit)
	truncated := false
	const maxRoots = 32
	if len(roots) > maxRoots {
		roots = roots[:maxRoots]
		truncated = true
	}
	for _, root := range roots {
		if len(visible) >= limit {
			truncated = true
			break
		}
		var results []files.Entry
		var more bool
		var err error
		if spotlight, ok := a.files.(spotlightSearchProvider); ok && engine == "spotlight" {
			results, more, err = spotlight.SearchSpotlightOrFallback(r.Context(), root, r.URL.Query().Get("query"), limit-len(visible))
		} else {
			results, more, err = a.files.Search(root, r.URL.Query().Get("query"), limit-len(visible))
		}
		if errors.Is(err, fs.ErrNotExist) {
			continue
		} // a stale grant cannot reveal siblings
		if err != nil {
			fileError(w, err)
			return
		}
		truncated = truncated || more
		for _, entry := range results {
			if a.canAccess(token(r), entry.Path, false, false) {
				visible = append(visible, entry)
			}
		}
	}
	sort.Slice(visible, func(i, j int) bool { return visible[i].Path < visible[j].Path })
	withCapabilities, canWrite, ok := a.fileEntryCapabilities(w, r, base, visible)
	if !ok {
		return
	}
	jsonReply(w, 200, map[string]any{"entries": withCapabilities, "truncated": truncated, "canWrite": canWrite})
}

func (a *API) fileOperation(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 2048)
	defer r.Body.Close()
	var body struct {
		Action   string `json:"action"`
		From     string `json:"from"`
		To       string `json:"to"`
		Conflict string `json:"conflict"`
	}
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if d.Decode(&body) != nil || (body.Action != "move" && body.Action != "copy") {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	if _, err := files.ValidateConflict(body.Conflict); err != nil {
		jsonReply(w, 400, map[string]string{"error": "invalid_request"})
		return
	}
	if !a.allowFile(w, r, body.From, body.Action == "move") || !a.allowFile(w, r, body.To, true) {
		return
	}
	var finalTo string
	var skipped bool
	var err error
	if body.Action == "move" {
		finalTo, skipped, err = moveWithConflict(a.files, body.From, body.To, body.Conflict)
	} else {
		finalTo, skipped, err = copyWithConflict(a.files, r.Context(), body.From, body.To, body.Conflict)
	}
	if err != nil {
		fileError(w, err)
		return
	}
	jsonReply(w, 200, map[string]any{"done": true, "finalTo": finalTo, "skipped": skipped})
}

// moveWithConflict prefers the Manager's conflict-aware operations; narrow
// test fakes without them keep the historical refuse behavior.
func moveWithConflict(access files.Access, from, to, conflict string) (string, bool, error) {
	if mover, ok := access.(interface {
		MoveWithOptions(string, string, string) (string, bool, error)
	}); ok {
		return mover.MoveWithOptions(from, to, conflict)
	}
	return to, false, access.Move(from, to)
}

func copyWithConflict(access files.Access, ctx context.Context, from, to, conflict string) (string, bool, error) {
	if copier, ok := access.(interface {
		CopyContextWithOptions(context.Context, string, string, string) (string, bool, error)
	}); ok {
		return copier.CopyContextWithOptions(ctx, from, to, conflict)
	}
	return to, false, access.CopyContext(ctx, from, to)
}

func (a *API) purgeTrash(w http.ResponseWriter, r *http.Request) {
	if a.files == nil {
		a.fileUnavailable(w)
		return
	}
	if err := a.files.Purge(r.PathValue("id")); err != nil {
		fileError(w, err)
		return
	}
	jsonReply(w, 200, map[string]bool{"deleted": true})
}
