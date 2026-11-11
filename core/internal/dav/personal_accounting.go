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
		case http.MethodGet, http.MethodHead, http.MethodOptions, "PROPFIND", http.MethodPut, http.MethodDelete, "MKCOL", "MOVE", "COPY", "LOCK", "UNLOCK":
			return true
		default:
			return false
		}
	}
	switch state.method {
	case http.MethodPut, http.MethodDelete, "MKCOL", "MOVE", "COPY", "LOCK", "UNLOCK":
		ok, err := state.service.store.CanWritePersonalStorageForUser(
			state.user, state.root.rootID, state.root.generation, name,
		)
		return err == nil && ok
	default:
		return false
	}
}

func reservePersonalPut(state *requestState, name string, current os.FileInfo) (string, int64, error) {
	if !personalHomeNamespace(name) {
		return "", 0, nil
	}
	if current != nil && state.root.replace == nil {
		state.writeStatus = http.StatusConflict
		return "", 0, fs.ErrExist
	}
	size := state.contentLength
	if state.method == "COPY" {
		if state.currentCopy == nil || state.currentCopy.info == nil {
			return "", 0, os.ErrPermission
		}
		size = state.currentCopy.info.Size()
	} else if state.method == "LOCK" {
		size = 0
	}
	if size < 0 {
		state.writeStatus = http.StatusLengthRequired
		return "", 0, os.ErrPermission
	}
	var id string
	var tracked bool
	var err error
	if current != nil {
		id, tracked, err = state.service.store.ReserveStorageReplacementForUser(
			state.user, state.root.rootID, state.root.generation, name, size, storageVersion(current),
		)
	} else {
		id, tracked, err = state.service.store.ReserveStorageUploadForUser(
			state.user, state.root.rootID, state.root.generation, name, size,
		)
	}
	if err != nil {
		switch {
		case errors.Is(err, auth.ErrStorageQuotaExceeded):
			state.writeStatus = http.StatusInsufficientStorage
			state.writeCode = "storage_quota_exceeded"
		case errors.Is(err, auth.ErrStorageLedgerConflict):
			state.writeStatus = http.StatusConflict
			state.writeCode = "storage_accounting_conflict"
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
	return id, size, nil
}

func storageVersion(info os.FileInfo) auth.StorageVersion {
	if !files.MediaFileHasSingleLink(info) {
		return auth.StorageVersion{}
	}
	return auth.StorageVersion{Identity: files.MediaFileIdentity(info), Size: info.Size()}
}

func (f *grantedFS) replaceMovedFile(state *requestState, from, to string, sourceInfo, targetInfo os.FileInfo) error {
	if state.root.replace == nil || !sameFileVersion(state.replacement, targetInfo) ||
		!sourceInfo.Mode().IsRegular() || !targetInfo.Mode().IsRegular() {
		state.writeStatus = http.StatusPreconditionFailed
		return fs.ErrExist
	}
	var reservation string
	previous, next := storageVersion(targetInfo), storageVersion(sourceInfo)
	if personalHomeNamespace(from) || personalHomeNamespace(to) {
		if !personalHomeNamespace(from) || !personalHomeNamespace(to) {
			state.writeCode = "dav_cross_owner_move"
			return os.ErrPermission
		}
		var err error
		reservation, err = f.service.store.ReserveStorageRenameReplacementForUser(
			state.user, state.root.rootID, state.root.generation, from, to, previous, next,
		)
		if err != nil {
			if errors.Is(err, auth.ErrForbidden) {
				state.writeStatus = http.StatusForbidden
				state.writeCode = "dav_cross_owner_move"
				return err
			}
			state.writeStatus = http.StatusConflict
			return err
		}
		if err := f.service.store.PrepareStoragePublications("dav_replace", []auth.StoragePublication{
			{ReservationID: reservation, Identity: next.Identity},
		}); err != nil {
			_ = f.service.store.ReleaseStorageReservation(reservation)
			return err
		}
	}
	err := state.root.replace(from, to, sourceInfo, targetInfo, func(trashID string) error {
		if !state.root.current() || !f.service.canAccess(state, from, true, false) || !f.service.canAccess(state, to, true, false) {
			return errResourceChanged
		}
		if reservation == "" {
			return nil
		}
		return f.service.store.CommitStorageReplacement(reservation, trashID, from, previous, next)
	})
	if err != nil && reservation != "" && !errors.Is(err, files.ErrDAVReplacementUncertain) {
		_ = f.service.store.ReleaseStorageReservation(reservation)
	}
	if err != nil {
		setReplacementError(state, err)
	}
	return err
}

func setReplacementError(state *requestState, err error) {
	switch {
	case errors.Is(err, files.ErrDAVReplaceUnsupported):
		state.writeStatus = http.StatusConflict
		state.writeCode = "dav_replace_unsupported_save_as"
	case errors.Is(err, files.ErrDAVReplacementUncertain):
		state.writeStatus = http.StatusInternalServerError
		state.writeCode = "storage_operation_uncertain"
	case errors.Is(err, files.ErrTrashChanged):
		state.writeStatus = http.StatusPreconditionFailed
	}
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
