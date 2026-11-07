package dav

import (
	"errors"
	"io/fs"
	"net/http"
	"os"
	"path"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

func privateAccessAllowed(state *requestState, name string, write bool) bool {
	if state == nil || state.root == nil || state.root.rootID == "" || state.root.generation == 0 {
		return false
	}
	if !write {
		switch state.method {
		case http.MethodGet, http.MethodHead, "PROPFIND", http.MethodPut, http.MethodDelete, "MKCOL", "MOVE":
			return true
		default:
			return false
		}
	}
	switch state.method {
	case http.MethodPut, http.MethodDelete, "MKCOL", "MOVE":
		ok, err := state.service.store.CanWritePersonalStorageForUser(
			state.user, state.root.rootID, state.root.generation, name,
		)
		return err == nil && ok
	default:
		return false
	}
}

func reservePersonalPut(state *requestState, name string, exists bool) (string, int64, error) {
	if !personalHomeNamespace(name) {
		return "", 0, nil
	}
	if exists {
		state.writeStatus = http.StatusConflict
		return "", 0, fs.ErrExist
	}
	if state.contentLength < 0 {
		state.writeStatus = http.StatusLengthRequired
		return "", 0, os.ErrPermission
	}
	id, tracked, err := state.service.store.ReserveStorageUploadForUser(
		state.user, state.root.rootID, state.root.generation, name, state.contentLength,
	)
	if err != nil {
		switch {
		case errors.Is(err, auth.ErrStorageQuotaExceeded):
			state.writeStatus = http.StatusInsufficientStorage
		case errors.Is(err, auth.ErrStorageLedgerConflict):
			state.writeStatus = http.StatusConflict
		case errors.Is(err, auth.ErrForbidden), errors.Is(err, auth.ErrStorageUnassigned):
			state.writeStatus = http.StatusForbidden
		default:
			state.writeStatus = http.StatusInternalServerError
		}
		return "", 0, os.ErrPermission
	}
	if !tracked || id == "" {
		state.writeStatus = http.StatusConflict
		return "", 0, os.ErrPermission
	}
	return id, state.contentLength, nil
}

func (f *grantedFS) renamePersonalEntry(
	state *requestState,
	oldName, newName string,
	oldParent *os.File, oldLeaf string, oldParentInfo os.FileInfo,
	newParent *os.File, newLeaf string, newParentInfo os.FileInfo,
	sourceInfo os.FileInfo,
) error {
	if !personalHomeNamespace(oldName) || !personalHomeNamespace(newName) ||
		state.root.rootID == "" || state.root.generation == 0 {
		return os.ErrPermission
	}
	rootID := state.root.rootID
	gen := state.root.generation
	if sourceInfo.IsDir() {
		reservationID, snapshot, err := f.service.store.ReserveStorageDirectoryRenameForUser(
			state.user, rootID, gen, oldName, newName,
		)
		if err != nil {
			state.writeStatus = http.StatusConflict
			return os.ErrPermission
		}
		for _, item := range snapshot {
			info, statErr := secureStat(state.root.file, item.Path)
			if item.Identity == "" || statErr != nil || !info.Mode().IsRegular() ||
				!files.MediaFileHasSingleLink(info) || info.Size() != item.Size ||
				files.MediaFileIdentity(info) != item.Identity {
				_ = f.service.store.ReleaseStorageReservation(reservationID)
				state.writeStatus = http.StatusConflict
				return os.ErrPermission
			}
		}
		if err := renameAtNoReplace(oldParent, oldLeaf, newParent, newLeaf); err != nil {
			_ = f.service.store.ReleaseStorageReservation(reservationID)
			return err
		}
		newInfo, err := statAtNoFollow(newParent, newLeaf)
		if err != nil || !sameIdentity(sourceInfo, newInfo) ||
			!sameDirectory(state.root.file, path.Dir(oldName), oldParentInfo) ||
			!sameDirectory(state.root.file, path.Dir(newName), newParentInfo) || !state.root.current() {
			rollbackErr := renameAtNoReplace(newParent, newLeaf, oldParent, oldLeaf)
			if rollbackErr == nil {
				_ = f.service.store.ReleaseStorageReservation(reservationID)
			}
			return errors.Join(errResourceChanged, rollbackErr)
		}
		if err := syncDirectory(newParent); err != nil {
			rollbackErr := renameAtNoReplace(newParent, newLeaf, oldParent, oldLeaf)
			if rollbackErr == nil {
				_ = f.service.store.ReleaseStorageReservation(reservationID)
			}
			return errors.Join(err, rollbackErr)
		}
		if path.Dir(oldName) != path.Dir(newName) {
			if err := syncDirectory(oldParent); err != nil {
				state.writeStatus = http.StatusInternalServerError
				return err
			}
		}
		if err := f.service.store.CommitStorageDirectoryRename(reservationID, rootID, gen, oldName, newName, snapshot); err != nil {
			state.writeStatus = http.StatusInternalServerError
			return err
		}
		return nil
	}

	identity, err := f.service.store.StorageFileIdentity(rootID, gen, oldName)
	if err != nil || (identity != "" && (!files.MediaFileHasSingleLink(sourceInfo) || files.MediaFileIdentity(sourceInfo) != identity)) {
		state.writeStatus = http.StatusConflict
		return os.ErrPermission
	}
	reservationID, err := f.service.store.ReserveStorageRenameForUser(
		state.user, rootID, gen, oldName, newName,
	)
	if err != nil {
		state.writeStatus = http.StatusConflict
		return os.ErrPermission
	}
	if err := renameAtNoReplace(oldParent, oldLeaf, newParent, newLeaf); err != nil {
		_ = f.service.store.ReleaseStorageReservation(reservationID)
		return err
	}
	newInfo, err := statAtNoFollow(newParent, newLeaf)
	if err != nil || !sameIdentity(sourceInfo, newInfo) ||
		!sameDirectory(state.root.file, path.Dir(oldName), oldParentInfo) ||
		!sameDirectory(state.root.file, path.Dir(newName), newParentInfo) || !state.root.current() {
		rollbackErr := renameAtNoReplace(newParent, newLeaf, oldParent, oldLeaf)
		if rollbackErr == nil {
			_ = f.service.store.ReleaseStorageReservation(reservationID)
		}
		return errors.Join(errResourceChanged, rollbackErr)
	}
	if err := syncDirectory(newParent); err != nil {
		rollbackErr := renameAtNoReplace(newParent, newLeaf, oldParent, oldLeaf)
		if rollbackErr == nil {
			_ = f.service.store.ReleaseStorageReservation(reservationID)
		}
		return errors.Join(err, rollbackErr)
	}
	if path.Dir(oldName) != path.Dir(newName) {
		if err := syncDirectory(oldParent); err != nil {
			state.writeStatus = http.StatusInternalServerError
			return err
		}
	}
	if err := f.service.store.CommitStorageRename(reservationID, rootID, gen, oldName, newName, sourceInfo.Size(), identity); err != nil {
		state.writeStatus = http.StatusInternalServerError
		return err
	}
	return nil
}
