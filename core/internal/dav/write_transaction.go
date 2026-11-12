package dav

import (
	"errors"
	"io"
	"io/fs"
	"log/slog"
	"net/http"
	"os"
	"path"
	"sync"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
	"golang.org/x/net/webdav"
)

type writeTxn struct {
	service       *Service
	state         *requestState
	name          string
	leaf          string
	parent        *os.File
	parentInfo    os.FileInfo
	stageName     string
	stage         *os.File
	existed       bool
	originalInfo  os.FileInfo
	unlock        func()
	copyReadCount int
	permission    os.FileMode
	reservationID string
	reservedSize  int64
	spaceLeft     uint64
	writeErr      error
	exchangeAtFn  func(sourceName, destinationName string) error
	syncParentFn  func() error
	closeOnce     sync.Once
	closeErr      error
}

func (t *writeTxn) exchange(sourceName, destinationName string) error {
	if t.exchangeAtFn != nil {
		return t.exchangeAtFn(sourceName, destinationName)
	}
	return exchangeAt(t.parent, sourceName, t.parent, destinationName)
}

func (t *writeTxn) syncParent() error {
	if t.syncParentFn != nil {
		return t.syncParentFn()
	}
	return syncDirectory(t.parent)
}

func (t *writeTxn) Read(p []byte) (int, error) { return t.stage.Read(p) }
func (t *writeTxn) Write(p []byte) (int, error) {
	if t.writeErr != nil {
		return 0, t.writeErr
	}
	limit := maxDAVUploadBytes
	if t.state.method == "COPY" {
		limit = maxDAVCopyBytes
	}
	if int64(len(p)) > limit-t.state.writtenBytes {
		t.state.writeStatus = http.StatusRequestEntityTooLarge
		t.writeErr = errDAVWriteLimit
		return 0, t.writeErr
	}
	size := uint64(len(p))
	if size > t.spaceLeft {
		free, err := freeBytes(t.stage)
		if err != nil || free < writeReserve || size > free-writeReserve {
			t.state.writeStatus = http.StatusInsufficientStorage
			t.writeErr = errors.Join(errDAVFreeSpace, err)
			return 0, t.writeErr
		}
		t.spaceLeft = min(free-writeReserve, max(uint64(davSpaceCheckInterval), size))
	}
	n, err := t.stage.Write(p)
	t.spaceLeft -= uint64(n)
	t.state.writtenBytes += int64(n)
	if err != nil {
		t.writeErr = err
	}
	return n, err
}
func (t *writeTxn) Seek(offset int64, whence int) (int64, error) {
	return t.stage.Seek(offset, whence)
}
func (t *writeTxn) Stat() (os.FileInfo, error)         { return t.stage.Stat() }
func (t *writeTxn) Readdir(int) ([]os.FileInfo, error) { return nil, os.ErrInvalid }

func (t *writeTxn) Close() error {
	t.closeOnce.Do(func() { t.closeErr = t.commit() })
	return t.closeErr
}

func (t *writeTxn) releaseParentAndLock() {
	if t.parent != nil {
		_ = t.parent.Close()
		t.parent = nil
	}
	if t.unlock != nil {
		t.unlock()
		t.unlock = nil
	}
}

func (t *writeTxn) abort() {
	t.abortFiles()
	t.releaseParentAndLock()
}

func (t *writeTxn) commit() error {
	defer t.releaseParentAndLock()

	if t.writeErr != nil {
		t.abortFiles()
		return t.writeErr
	}
	if err := t.verifyStreamCompletion(); err != nil {
		t.abortFiles()
		return err
	}
	if err := t.verifyCommitPreconditions(); err != nil {
		t.abortFiles()
		return err
	}
	stageInfo, err := t.syncAndCloseStage()
	if err != nil {
		return err
	}
	if t.existed && t.state.root.replace != nil {
		return t.replacePublishedFile(stageInfo)
	}
	return t.publishAndFinalizeTarget(stageInfo)
}

func (t *writeTxn) verifyStreamCompletion() error {
	switch t.state.method {
	case http.MethodPut:
		if !t.state.body.complete() {
			if err := t.state.body.failure(); err != nil {
				return err
			}
			return io.ErrUnexpectedEOF
		}
	case "COPY":
		if !t.state.copyComplete(t.copyReadCount) {
			if t.state.preconditions != nil {
				t.state.conditionFailed = true
				return errPreconditionFailed
			}
			return errResourceChanged
		}
	case "LOCK":
		return t.state.body.failure()
	default:
		if t.state.body != nil && !t.state.body.complete() && t.state.body.failure() != nil {
			return t.state.body.failure()
		}
	}
	return nil
}

func (t *writeTxn) verifyCommitPreconditions() error {
	if (t.state.ctx != nil && t.state.ctx.Err() != nil) ||
		!t.state.root.current() ||
		!t.service.canAccess(t.state, t.name, true, false) {
		return os.ErrPermission
	}
	if !sameDirectory(t.state.root.file, path.Dir(t.name), t.parentInfo) {
		return errResourceChanged
	}
	current, statErr := statAtNoFollow(t.parent, t.leaf)
	currentExists := statErr == nil
	if statErr != nil && !errors.Is(statErr, fs.ErrNotExist) {
		return statErr
	}
	if currentExists && (!current.Mode().IsRegular() || current.Mode()&os.ModeSymlink != 0) {
		return os.ErrPermission
	}
	if t.existed {
		if !currentExists || !sameFileVersion(t.originalInfo, current) {
			if t.state.preconditions != nil {
				t.state.conditionFailed = true
				return errPreconditionFailed
			}
			return errResourceChanged
		}
	} else if currentExists {
		if t.state.preconditions != nil {
			t.state.conditionFailed = true
			return errPreconditionFailed
		}
		return fs.ErrExist
	}
	if t.state.method == http.MethodPut &&
		(!t.state.preconditions.matches(current, currentExists) ||
			!t.state.preconditions.sameInitial(current, currentExists)) {
		t.state.conditionFailed = true
		return errPreconditionFailed
	}
	if t.state.method == "COPY" && !t.state.copyComplete(t.copyReadCount) {
		if t.state.preconditions != nil {
			t.state.conditionFailed = true
			return errPreconditionFailed
		}
		return errResourceChanged
	}
	return nil
}

func (t *writeTxn) syncAndCloseStage() (os.FileInfo, error) {
	if err := syncRegular(t.stage); err != nil {
		t.abortFiles()
		return nil, err
	}
	stageInfo, err := t.stage.Stat()
	if err != nil {
		t.abortFiles()
		return nil, err
	}
	if t.reservationID != "" && stageInfo.Size() != t.reservedSize {
		t.state.writeStatus = http.StatusBadRequest
		t.abortFiles()
		return nil, io.ErrUnexpectedEOF
	}
	if t.reservationID != "" {
		if err := t.prepareStoragePublication(stageInfo); err != nil {
			t.abortFiles()
			return nil, err
		}
	}
	if err := t.stage.Close(); err != nil {
		t.stage = nil
		t.cleanupUnpublishedStage()
		return nil, err
	}
	t.stage = nil
	return stageInfo, nil
}

func (t *writeTxn) prepareStoragePublication(stageInfo os.FileInfo) error {
	identity := files.MediaFileIdentity(stageInfo)
	operation := "dav_put"
	switch t.state.method {
	case "COPY":
		operation = "dav_copy"
	case "LOCK":
		operation = "dav_lock"
	}
	if t.existed {
		operation = "dav_replace"
	}
	if !files.MediaFileHasSingleLink(stageInfo) || identity == "" {
		return errResourceChanged
	}
	return t.service.store.PrepareStoragePublications(operation, []auth.StoragePublication{
		{ReservationID: t.reservationID, Identity: identity},
	})
}

func (t *writeTxn) cleanupUnpublishedStage() {
	_ = unlinkAt(t.parent, t.stageName, false)
	if t.reservationID != "" {
		_ = t.service.store.ReleaseStorageReservation(t.reservationID)
		t.reservationID = ""
	}
}

func (t *writeTxn) publishAndFinalizeTarget(stageInfo os.FileInfo) error {
	var err error
	if t.existed {
		err = t.exchange(t.stageName, t.leaf)
	} else {
		err = renameAtNoReplace(t.parent, t.stageName, t.parent, t.leaf)
	}
	if err != nil {
		t.cleanupUnpublishedStage()
		return err
	}
	if err := t.verifyPostSwapState(stageInfo); err != nil {
		return t.rollbackCommittedSwap(stageInfo, err)
	}
	if err := t.syncParent(); err != nil {
		return t.rollbackCommittedSwap(stageInfo, err)
	}
	if t.existed {
		t.cleanupPriorOverwrittenStage()
		return nil
	}
	return t.finalizeCreatedTarget()
}

func (t *writeTxn) verifyPostSwapState(stageInfo os.FileInfo) error {
	newInfo, err := statAtNoFollow(t.parent, t.leaf)
	if err != nil || !sameIdentity(stageInfo, newInfo) ||
		!sameDirectory(t.state.root.file, path.Dir(t.name), t.parentInfo) ||
		!t.state.root.current() {
		return errResourceChanged
	}
	if t.existed {
		oldInfo, oldErr := statAtNoFollow(t.parent, t.stageName)
		if oldErr != nil || !sameFileContentVersion(t.originalInfo, oldInfo) {
			return errResourceChanged
		}
	}
	if t.state.method == "COPY" && !t.state.copyComplete(t.copyReadCount) {
		if t.state.preconditions != nil {
			t.state.conditionFailed = true
		}
		return errResourceChanged
	}
	return nil
}

func (t *writeTxn) rollbackCommittedSwap(stageInfo os.FileInfo, cause error) error {
	var rollbackErr error
	if t.existed {
		rollbackErr = t.exchange(t.stageName, t.leaf)
	} else {
		newInfo, statErr := statAtNoFollow(t.parent, t.leaf)
		if statErr == nil && sameIdentity(newInfo, stageInfo) {
			rollbackErr = unlinkAt(t.parent, t.leaf, false)
		}
	}
	_ = t.syncParent()
	// If the reverse exchange failed, stageName still holds the original
	// target. Keep it recoverable; deleting it would destroy the only copy.
	if rollbackErr == nil {
		_ = unlinkAt(t.parent, t.stageName, false)
	} else if t.existed {
		slog.Error(
			"dav overwrite rollback failed; previous file remains in staging for manual recovery",
			"path", t.name,
			"staging", t.stageName,
			"error", rollbackErr,
		)
	}
	return errors.Join(cause, rollbackErr)
}

func (t *writeTxn) cleanupPriorOverwrittenStage() {
	if err := unlinkAt(t.parent, t.stageName, false); err != nil {
		slog.Warn("dav overwrite committed with recoverable prior file", "path", t.name, "staging", t.stageName, "error", err)
		return
	}
	if err := t.syncParent(); err != nil {
		slog.Warn("dav overwrite committed; prior-file cleanup durability is uncertain", "path", t.name, "staging", t.stageName, "error", err)
	}
}

func (t *writeTxn) finalizeCreatedTarget() error {
	newInfo, statErr := statAtNoFollow(t.parent, t.leaf)
	if t.reservationID != "" {
		identity := files.MediaFileIdentity(newInfo)
		if statErr != nil || !files.MediaFileHasSingleLink(newInfo) || identity == "" || !t.state.root.current() {
			t.state.writeStatus = http.StatusInternalServerError
			return errResourceChanged
		}
		if err := t.service.store.CommitStorageReservationWithIdentity(t.reservationID, identity); err != nil {
			t.state.writeStatus = http.StatusInternalServerError
			return err
		}
		t.reservationID = ""
	}
	t.state.addCreated(t.name, t.parentInfo, newInfo, false)
	return nil
}

func (t *writeTxn) replacePublishedFile(stageInfo os.FileInfo) error {
	staging := path.Join(path.Dir(t.name), t.stageName)
	err := t.state.root.replace(staging, t.name, stageInfo, t.originalInfo, func(trashID string) error {
		if !t.state.root.current() || !t.service.canAccess(t.state, t.name, true, false) ||
			(t.state.method == "COPY" && !t.state.copyComplete(t.copyReadCount)) {
			return errResourceChanged
		}
		if t.reservationID == "" {
			return nil
		}
		return t.service.store.CommitStorageReplacement(t.reservationID, trashID, "",
			storageVersion(t.originalInfo), storageVersion(stageInfo))
	})
	if err == nil {
		t.reservationID = ""
		t.state.replacedPut = t.state.method == http.MethodPut
		return nil
	}
	setReplacementError(t.state, err)
	if !errors.Is(err, files.ErrDAVReplacementUncertain) {
		info, statErr := statAtNoFollow(t.parent, t.stageName)
		if statErr == nil && sameIdentity(info, stageInfo) && unlinkAt(t.parent, t.stageName, false) == nil &&
			t.reservationID != "" {
			_ = t.service.store.ReleaseStorageReservation(t.reservationID)
			t.reservationID = ""
		}
	}
	return err
}

func (t *writeTxn) abortFiles() {
	if t.stage != nil {
		_ = t.stage.Close()
		t.stage = nil
	}
	if t.parent != nil {
		_ = unlinkAt(t.parent, t.stageName, false)
	}
	if t.reservationID != "" {
		_ = t.service.store.ReleaseStorageReservation(t.reservationID)
		t.reservationID = ""
	}
}

var _ webdav.FileSystem = (*grantedFS)(nil)
var _ webdav.File = (*safeFile)(nil)
var _ webdav.File = (*writeTxn)(nil)
