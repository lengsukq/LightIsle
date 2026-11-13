package server

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"net/http"
	"os"
	"strconv"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

type spotlightSearchProvider interface {
	SearchSpotlightOrFallback(context.Context, string, string, int) ([]files.Entry, bool, error)
}

type spotlightSearchKindProvider interface {
	SearchSpotlightKindOrFallback(context.Context, string, string, string, int) ([]files.Entry, bool, error)
}

// The quota ledger must reserve the FINAL destination, not the name initially
// requested by a client. Compute collision-safe candidates before the ledger
// reservation and publish with ConflictRefuse: the filesystem's exclusive
// primitive remains the authority for concurrent creates.
func accountedDestination(access files.Access, target, conflict string) (string, bool, error) {
	if conflict == files.ConflictRefuse {
		return target, false, nil
	}
	for attempt := 1; attempt <= 1000; attempt++ {
		candidate := target
		if attempt > 1 {
			var err error
			candidate, err = files.NextRenameCandidate(target, attempt)
			if err != nil {
				return "", false, err
			}
		}
		_, err := access.Stat(candidate)
		if err == nil {
			if conflict == files.ConflictSkip {
				return candidate, true, nil
			}
			continue
		}
		if errors.Is(err, fs.ErrNotExist) {
			return candidate, false, nil
		}
		return "", false, err
	}
	return "", false, files.ErrExists
}

// moveAccountedFile supports same-root, single-file renames without granting
// unmetered access to private storage. The zero-byte destination reservation
// remains after an uncertain file/ledger commit for administrator inspection.
func (a *API) moveAccountedFile(w http.ResponseWriter, r *http.Request, from, to, conflict string) {
	finalTarget, skip, err := accountedDestination(a.files, to, conflict)
	if err != nil {
		fileError(w, err)
		return
	}
	if skip {
		jsonReply(w, http.StatusOK, map[string]any{"done": true, "finalTo": finalTarget, "skipped": true})
		return
	}
	to = finalTarget
	if a.rootLease == nil || a.rootRuntime == nil || !a.rootLease.Valid(r.Context()) {
		jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_root_not_current"})
		return
	}
	info, err := a.files.Stat(from)
	if err != nil {
		fileError(w, err)
		return
	}
	if info.IsDir() {
		a.moveAccountedDirectory(w, r, from, to, files.ConflictRefuse)
		return
	}
	if !info.Mode().IsRegular() || info.Size() < 0 {
		jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_copy_regular_file_required"})
		return
	}
	identity, err := a.auth.StorageFileIdentity(a.rootID, a.rootRuntime.root.Generation, from)
	if err != nil {
		storageQuotaError(w, err)
		return
	}
	if identity != "" && (!files.MediaFileHasSingleLink(info) || files.MediaFileIdentity(info) != identity) {
		storageQuotaError(w, auth.ErrStorageLedgerConflict)
		return
	}
	reservation, err := a.auth.ReserveStorageRename(token(r), a.rootID,
		a.rootRuntime.root.Generation, from, to)
	if err != nil {
		storageQuotaError(w, err)
		return
	}
	finalTo, skipped, err := moveWithConflict(a.files, from, to, files.ConflictRefuse)
	if err != nil {
		if errors.Is(err, files.ErrExists) {
			if releaseErr := a.auth.ReleaseStorageReservation(reservation); releaseErr != nil {
				jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "storage_accounting_uncertain"})
				return
			}
			fileError(w, err)
			return
		}
		jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "storage_accounting_uncertain"})
		return
	}
	if finalTo != to || skipped || !a.rootLease.Valid(r.Context()) {
		jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "storage_accounting_uncertain"})
		return
	}
	published, err := a.files.Stat(to)
	if err != nil || !published.Mode().IsRegular() || published.Size() != info.Size() ||
		!os.SameFile(info, published) || (identity != "" && (!files.MediaFileHasSingleLink(published) || files.MediaFileIdentity(published) != identity)) {
		jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "storage_accounting_uncertain"})
		return
	}
	if err := a.auth.CommitStorageRename(reservation, a.rootID,
		a.rootRuntime.root.Generation, from, to, info.Size(), identity); err != nil {
		jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "storage_accounting_uncertain"})
		return
	}
	if a.rootServer != nil {
		a.rootServer.QueueMediaRefresh(a.rootID, from)
		a.rootServer.QueueMediaRefresh(a.rootID, to)
	}
	jsonReply(w, http.StatusOK, map[string]any{"done": true, "finalTo": to, "skipped": false})
}

// copyAccountedFile makes single-file copies useful without pretending that
// a filesystem publication and SQLite commit form one transaction. A quota
// reservation survives any ambiguous publication/commit error for later
// reconciliation. No directory copy, rename/skip conflict handling or
// cross-root operation is silently treated as accounted.
func (a *API) copyAccountedFile(w http.ResponseWriter, r *http.Request, from, to, conflict string) {
	finalTarget, skip, err := accountedDestination(a.files, to, conflict)
	if err != nil {
		fileError(w, err)
		return
	}
	if skip {
		jsonReply(w, http.StatusOK, map[string]any{"done": true, "finalTo": finalTarget, "skipped": true})
		return
	}
	to = finalTarget
	if a.rootLease == nil || a.rootRuntime == nil || !a.rootLease.Valid(r.Context()) {
		jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_root_not_current"})
		return
	}
	info, err := a.files.Stat(from)
	if err != nil {
		fileError(w, err)
		return
	}
	if info.IsDir() {
		if to == from || strings.HasPrefix(to, from+"/") || isManagedCategoryRoot(from) {
			jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_copy_regular_file_required"})
			return
		}
		a.copyAccountedDirectory(w, r, from, to)
		return
	}
	if !info.Mode().IsRegular() || info.Size() < 0 {
		jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_copy_regular_file_required"})
		return
	}
	reservation, tracked, err := a.reserveUploadQuota(r, to, info.Size())
	if err != nil {
		storageQuotaError(w, err)
		return
	}
	if !tracked || reservation == "" {
		jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_destination_not_assigned"})
		return
	}
	var finalTo, identity string
	var skipped bool
	if copier, ok := a.files.(interface {
		CopyContextWithOptionsAndIdentity(context.Context, string, string, string) (string, bool, string, error)
	}); ok {
		finalTo, skipped, identity, err = copier.CopyContextWithOptionsAndIdentity(r.Context(), from, to, files.ConflictRefuse)
	} else {
		finalTo, skipped, err = copyWithConflict(a.files, r.Context(), from, to, files.ConflictRefuse)
	}
	if err != nil {
		// An exclusive destination conflict cannot have published our file.
		// Other errors (including source failures and sync failures) are
		// conservatively held; some may occur AFTER durable publication.
		if errors.Is(err, files.ErrExists) {
			if releaseErr := a.auth.ReleaseStorageReservation(reservation); releaseErr != nil {
				jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "storage_accounting_uncertain"})
				return
			}
			fileError(w, err)
			return
		}
		jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "storage_accounting_uncertain"})
		return
	}
	if finalTo != to || skipped {
		jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "storage_accounting_uncertain"})
		return
	}
	// Do not commit a different byte count when source metadata changed in
	// flight or the file has been replaced externally after publication.
	if published, statErr := a.files.Stat(to); statErr != nil || !published.Mode().IsRegular() || published.Size() != info.Size() {
		jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "storage_accounting_uncertain"})
		return
	}
	if !a.rootLease.Valid(r.Context()) {
		jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "storage_accounting_uncertain"})
		return
	}
	if err := a.auth.CommitStorageReservationWithIdentity(reservation, identity); err != nil {
		jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "storage_accounting_uncertain"})
		return
	}
	if a.rootServer != nil {
		a.rootServer.QueueMediaRefresh(a.rootID, to)
	}
	jsonReply(w, http.StatusOK, map[string]any{"done": true, "finalTo": to, "skipped": false})
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
	kind := r.URL.Query().Get("kind")
	if !files.ValidSearchKind(kind) {
		jsonReply(w, 400, map[string]string{"error": "invalid_search_kind"})
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
	query := r.URL.Query().Get("query")
	seen := make(map[string]struct{}, limit)
	for _, root := range roots {
		var results []files.Entry
		var more bool
		var err error
		if spotlightKind, ok := a.files.(spotlightSearchKindProvider); ok && engine == "spotlight" {
			results, more, err = spotlightKind.SearchSpotlightKindOrFallback(r.Context(), root, query, kind, limit)
		} else if spotlight, ok := a.files.(spotlightSearchProvider); ok && engine == "spotlight" {
			results, more, err = spotlight.SearchSpotlightOrFallback(r.Context(), root, query, limit)
		} else if kindSearcher, ok := a.files.(interface {
			SearchKind(string, string, string, int) ([]files.Entry, bool, error)
		}); ok && kind != "" && kind != "all" {
			results, more, err = kindSearcher.SearchKind(root, query, kind, limit)
		} else {
			results, more, err = a.files.Search(root, query, limit)
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
			if _, dup := seen[entry.Path]; dup {
				continue
			}
			if files.MatchesSearchKind(entry, kind) && a.canAccess(token(r), entry.Path, false, false) {
				seen[entry.Path] = struct{}{}
				visible = append(visible, entry)
			}
		}
	}
	files.RankSearchEntries(visible, query)
	if len(visible) > limit {
		visible = visible[:limit]
		truncated = true
	}
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
	// A v2 single-file copy into an assigned private category can reserve
	// its exact bytes before publication. An unmetered move still requires a
	// separate crash-recoverable rename operation and remains unavailable.
	if a.rootID != "" && body.Action == "copy" && managedStorageName(body.To) {
		a.copyAccountedFile(w, r, body.From, body.To, body.Conflict)
		return
	}
	if a.rootID != "" && body.Action == "move" && (managedStorageName(body.From) || managedStorageName(body.To)) {
		a.moveAccountedFile(w, r, body.From, body.To, body.Conflict)
		return
	}
	if a.rootID != "" && (managedStorageName(body.From) || managedStorageName(body.To)) {
		jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_mutation_accounting_pending"})
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
	if !skipped && a.rootServer != nil {
		if a.rootID != "" && (a.rootLease == nil || !a.rootLease.Valid(r.Context())) {
			jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "root_unavailable"})
			return
		}
		a.rootServer.QueueMediaRefresh(a.rootID, body.From)
		a.rootServer.QueueMediaRefresh(a.rootID, finalTo)
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
	if a.rootID != "" {
		if a.rootRuntime == nil || a.rootLease == nil || !a.rootLease.Valid(r.Context()) {
			jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "root_unavailable"})
			return
		}
		entry, err := a.files.TrashInfo(r.PathValue("id"))
		if err != nil {
			fileError(w, err)
			return
		}
		if managedStorageName(entry.OriginalPath) {
			a.purgeAccountedTrash(w, r, entry)
			return
		}
	}
	if a.auth != nil {
		if actor, ok := a.auth.Identity(token(r)); !ok || actor.Role != auth.RoleAdmin {
			jsonReply(w, http.StatusForbidden, map[string]string{"error": "admin_required"})
			return
		}
	}
	if err := a.files.Purge(r.PathValue("id")); err != nil {
		if a.rootID != "" && !a.rootLease.Valid(r.Context()) {
			jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "storage_operation_uncertain"})
			return
		}
		fileError(w, err)
		return
	}
	// Purge operates on a pinned directory, which may have been detached or
	// replaced while the deletion was in progress. Do not report a successful
	// deletion of the current root in that case.
	if a.rootID != "" && !a.rootLease.Valid(r.Context()) {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "storage_operation_uncertain"})
		return
	}
	jsonReply(w, 200, map[string]bool{"deleted": true})
}
