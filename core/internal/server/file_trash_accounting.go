package server

import (
	"context"
	"errors"
	"io/fs"
	"net/http"
	"path"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

type accountedTrashPurger interface {
	PurgeWithAccounting(id string, prepare files.TrashPurgePrepare) error
}

func (a *API) purgeAccountedTrash(w http.ResponseWriter, r *http.Request, entry files.TrashEntry) {
	if !a.allowFile(w, r, entry.OriginalPath, true) {
		return
	}
	purger, ok := a.files.(accountedTrashPurger)
	if !ok {
		jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_trash_purge_accounting_pending"})
		return
	}
	snapshot, err := a.auth.TrashLedgerSnapshot(token(r), a.rootID, a.rootRuntime.root.Generation, entry.OriginalPath)
	if err != nil {
		storageQuotaError(w, err)
		return
	}
	toRelease := make([]auth.TrashLedgerFile, 0, len(snapshot))
	err = purger.PurgeWithAccounting(
		entry.ID,
		func(current files.TrashEntry, inspect func(string) (files.TrashFileInspection, error)) (func() error, error) {
			if current.OriginalPath != entry.OriginalPath {
				return nil, files.ErrTrashChanged
			}
			prefix := entry.OriginalPath + "/"
			for _, row := range snapshot {
				if row.Identity == "" {
					return nil, files.ErrTrashIdentityUnknown
				}
				rel := "."
				if row.Path == entry.OriginalPath {
					rel = "."
				} else if strings.HasPrefix(row.Path, prefix) {
					rel = strings.TrimPrefix(row.Path, prefix)
				} else {
					return nil, files.ErrTrashIdentityUnknown
				}
				inspected, inspectErr := inspect(rel)
				if inspectErr == nil {
					if inspected.Identity != row.Identity || inspected.Size != row.Size {
						return nil, files.ErrTrashIdentityUnknown
					}
					toRelease = append(toRelease, row)
					continue
				}
				if errors.Is(inspectErr, fs.ErrNotExist) && rel != "." {
					// If a directory was recreated at the same path after being moved
					// to trash, newer live files under that prefix stay in the ledger
					// and must not be released when the old trash directory is purged.
					liveInfo, statErr := a.files.Stat(row.Path)
					if statErr == nil && liveInfo.Mode().IsRegular() &&
						files.MediaFileHasSingleLink(liveInfo) &&
						liveInfo.Size() == row.Size &&
						files.MediaFileIdentity(liveInfo) == row.Identity {
						continue
					}
					return nil, files.ErrTrashIdentityUnknown
				}
				return nil, inspectErr
			}
			return func() error {
				if a.rootLease == nil || !a.rootLease.Valid(r.Context()) {
					return auth.ErrStorageLedgerConflict
				}
				if len(toRelease) == 0 {
					return nil
				}
				return a.auth.ReleaseTrashLedgerSnapshot(token(r), a.rootID, a.rootRuntime.root.Generation, entry.OriginalPath, toRelease)
			}, nil
		},
	)
	if err != nil {
		if errors.Is(err, files.ErrTrashAccountingUncertain) || (a.rootLease != nil && !a.rootLease.Valid(r.Context())) {
			jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "storage_accounting_uncertain"})
			return
		}
		if errors.Is(err, files.ErrTrashIdentityUnknown) {
			jsonReply(w, http.StatusConflict, map[string]string{"error": "trash_accounting_identity_unknown"})
			return
		}
		fileError(w, err)
		return
	}
	if a.rootLease == nil || !a.rootLease.Valid(r.Context()) {
		jsonReply(w, http.StatusServiceUnavailable, map[string]string{"error": "storage_operation_uncertain"})
		return
	}
	jsonReply(w, http.StatusOK, map[string]bool{"deleted": true})
}

func (a *API) moveAccountedDirectory(w http.ResponseWriter, r *http.Request, from, to, conflict string) {
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
	reservation, snapshot, err := a.auth.ReserveStorageDirectoryRename(
		token(r), a.rootID, a.rootRuntime.root.Generation, from, to,
	)
	if err != nil {
		storageQuotaError(w, err)
		return
	}
	if !verifyAccountedDirectoryTree(a.files, from, snapshot) {
		_ = a.auth.ReleaseStorageReservation(reservation)
		storageQuotaError(w, auth.ErrStorageLedgerConflict)
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
	if err := a.auth.CommitStorageDirectoryRename(
		reservation, a.rootID, a.rootRuntime.root.Generation, from, to, snapshot,
	); err != nil {
		jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "storage_accounting_uncertain"})
		return
	}
	if a.rootServer != nil {
		a.rootServer.QueueMediaRefresh(a.rootID, from)
		a.rootServer.QueueMediaRefresh(a.rootID, to)
	}
	jsonReply(w, http.StatusOK, map[string]any{"done": true, "finalTo": to, "skipped": false})
}

func verifyAccountedDirectoryTree(access files.Access, from string, snapshot []auth.TrashLedgerFile) bool {
	expected := make(map[string]auth.TrashLedgerFile, len(snapshot))
	for _, item := range snapshot {
		if item.Identity == "" {
			return false
		}
		info, err := access.Stat(item.Path)
		if err != nil || !info.Mode().IsRegular() || !files.MediaFileHasSingleLink(info) ||
			info.Size() != item.Size || files.MediaFileIdentity(info) != item.Identity {
			return false
		}
		expected[item.Path] = item
	}
	queue := []string{from}
	seenDirs := 0
	for len(queue) > 0 {
		dir := queue[0]
		queue = queue[1:]
		seenDirs++
		if seenDirs > 1024 {
			return false
		}
		cursor := ""
		for {
			entries, next, err := access.Page(dir, cursor, 200)
			if err != nil {
				return false
			}
			for _, entry := range entries {
				if entry.Type == "folder" {
					queue = append(queue, entry.Path)
					continue
				}
				if _, ok := expected[entry.Path]; !ok {
					return false
				}
				delete(expected, entry.Path)
			}
			if next == "" {
				break
			}
			cursor = next
		}
	}
	return len(expected) == 0
}

func isManagedCategoryRoot(p string) bool {
	trimmed := strings.Trim(p, "/")
	if !managedStorageName(trimmed) {
		return false
	}
	return strings.Count(trimmed, "/") <= 2
}

type accountedCopyFilePlan struct {
	relPath string
	size    int64
}

func (a *API) copyAccountedDirectory(w http.ResponseWriter, r *http.Request, from, to string) {
	if _, err := a.files.Stat(to); err == nil {
		fileError(w, files.ErrExists)
		return
	} else if !errors.Is(err, fs.ErrNotExist) {
		fileError(w, err)
		return
	}
	var relDirs []string
	var relFiles []accountedCopyFilePlan
	queue := []string{from}
	seenEntries := 0
	prefix := from + "/"
	for len(queue) > 0 {
		dir := queue[0]
		queue = queue[1:]
		cursor := ""
		for {
			entries, next, err := a.files.Page(dir, cursor, 200)
			if err != nil {
				fileError(w, err)
				return
			}
			for _, entry := range entries {
				seenEntries++
				if seenEntries > 500 {
					fileError(w, files.ErrSize)
					return
				}
				rel := strings.TrimPrefix(entry.Path, prefix)
				if rel == "" || rel == entry.Path {
					fileError(w, files.ErrPath)
					return
				}
				if entry.Type == "folder" {
					relDirs = append(relDirs, rel)
					queue = append(queue, entry.Path)
					continue
				}
				if entry.Size < 0 {
					jsonReply(w, http.StatusConflict, map[string]string{"error": "storage_copy_regular_file_required"})
					return
				}
				relFiles = append(relFiles, accountedCopyFilePlan{relPath: rel, size: entry.Size})
			}
			if next == "" {
				break
			}
			cursor = next
		}
	}
	if err := a.files.Mkdir(to); err != nil {
		fileError(w, err)
		return
	}
	for _, relDir := range relDirs {
		if err := a.files.Mkdir(path.Join(to, relDir)); err != nil {
			fileError(w, err)
			return
		}
	}
	for _, item := range relFiles {
		srcPath := path.Join(from, item.relPath)
		dstPath := path.Join(to, item.relPath)
		reservation, tracked, err := a.reserveUploadQuota(r, dstPath, item.size)
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
			finalTo, skipped, identity, err = copier.CopyContextWithOptionsAndIdentity(r.Context(), srcPath, dstPath, files.ConflictRefuse)
		} else {
			finalTo, skipped, err = copyWithConflict(a.files, r.Context(), srcPath, dstPath, files.ConflictRefuse)
		}
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
		if finalTo != dstPath || skipped || !a.rootLease.Valid(r.Context()) {
			jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "storage_accounting_uncertain"})
			return
		}
		if published, statErr := a.files.Stat(dstPath); statErr != nil || !published.Mode().IsRegular() || published.Size() != item.size {
			jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "storage_accounting_uncertain"})
			return
		}
		if err := a.auth.CommitStorageReservationWithIdentity(reservation, identity); err != nil {
			jsonReply(w, http.StatusInternalServerError, map[string]string{"error": "storage_accounting_uncertain"})
			return
		}
	}
	if a.rootServer != nil {
		a.rootServer.QueueMediaRefresh(a.rootID, to)
	}
	jsonReply(w, http.StatusOK, map[string]any{"done": true, "finalTo": to, "skipped": false})
}
