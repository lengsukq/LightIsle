package dav

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"net/http"
	"os"
	"path"
	"sync"

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

func (t *writeTxn) abort() {
	t.abortFiles()
	if t.parent != nil {
		_ = t.parent.Close()
		t.parent = nil
	}
	if t.unlock != nil {
		t.unlock()
		t.unlock = nil
	}
}

func (t *writeTxn) commit() error {
	defer func() {
		if t.parent != nil {
			_ = t.parent.Close()
			t.parent = nil
		}
		if t.unlock != nil {
			t.unlock()
			t.unlock = nil
		}
	}()

	if t.writeErr != nil {
		t.abortFiles()
		return t.writeErr
	}
	switch t.state.method {
	case http.MethodPut:
		if !t.state.body.complete() {
			t.abortFiles()
			if err := t.state.body.failure(); err != nil {
				return err
			}
			return io.ErrUnexpectedEOF
		}
	case "COPY":
		if !t.state.copyComplete(t.copyReadCount) {
			if t.state.preconditions != nil {
				t.state.conditionFailed = true
			}
			t.abortFiles()
			if t.state.preconditions != nil {
				return errPreconditionFailed
			}
			return errResourceChanged
		}
	case "LOCK":
		if err := t.state.body.failure(); err != nil {
			t.abortFiles()
			return err
		}
	default:
		if t.state.body != nil && !t.state.body.complete() && t.state.body.failure() != nil {
			t.abortFiles()
			return t.state.body.failure()
		}
	}
	if !t.state.root.current() || !t.service.canAccess(t.state, t.name, true, false) {
		t.abortFiles()
		return os.ErrPermission
	}
	if !sameDirectory(t.state.root.file, path.Dir(t.name), t.parentInfo) {
		t.abortFiles()
		return errResourceChanged
	}
	current, statErr := statAtNoFollow(t.parent, t.leaf)
	currentExists := statErr == nil
	if statErr != nil && !errors.Is(statErr, fs.ErrNotExist) {
		t.abortFiles()
		return statErr
	}
	if currentExists && (!current.Mode().IsRegular() || current.Mode()&os.ModeSymlink != 0) {
		t.abortFiles()
		return os.ErrPermission
	}
	if t.existed {
		if !currentExists || !sameFileVersion(t.originalInfo, current) {
			if t.state.preconditions != nil {
				t.state.conditionFailed = true
				t.abortFiles()
				return errPreconditionFailed
			}
			t.abortFiles()
			return errResourceChanged
		}
	} else if currentExists {
		if t.state.preconditions != nil {
			t.state.conditionFailed = true
			t.abortFiles()
			return errPreconditionFailed
		}
		t.abortFiles()
		return fs.ErrExist
	}
	if t.state.method == http.MethodPut &&
		(!t.state.preconditions.matches(current, currentExists) ||
			!t.state.preconditions.sameInitial(current, currentExists)) {
		t.state.conditionFailed = true
		t.abortFiles()
		return errPreconditionFailed
	}
	if t.state.method == "COPY" && !t.state.copyComplete(t.copyReadCount) {
		if t.state.preconditions != nil {
			t.state.conditionFailed = true
		}
		t.abortFiles()
		if t.state.preconditions != nil {
			return errPreconditionFailed
		}
		return errResourceChanged
	}
	if err := syncRegular(t.stage); err != nil {
		t.abortFiles()
		return err
	}
	stageInfo, err := t.stage.Stat()
	if err != nil {
		t.abortFiles()
		return err
	}
	if t.reservationID != "" && stageInfo.Size() != t.reservedSize {
		t.state.writeStatus = http.StatusBadRequest
		t.abortFiles()
		return io.ErrUnexpectedEOF
	}
	if err := t.stage.Close(); err != nil {
		t.stage = nil
		_ = unlinkAt(t.parent, t.stageName, false)
		if t.reservationID != "" {
			_ = t.service.store.ReleaseStorageReservation(t.reservationID)
			t.reservationID = ""
		}
		return err
	}
	t.stage = nil
	if t.existed {
		err = t.exchange(t.stageName, t.leaf)
	} else {
		err = renameAtNoReplace(t.parent, t.stageName, t.parent, t.leaf)
	}
	if err != nil {
		_ = unlinkAt(t.parent, t.stageName, false)
		if t.reservationID != "" {
			_ = t.service.store.ReleaseStorageReservation(t.reservationID)
			t.reservationID = ""
		}
		return err
	}
	rollback := func(cause error) error {
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
			slog.Error("dav overwrite rollback failed; previous file remains in staging for manual recovery",
				"path", t.name, "staging", t.stageName, "error", rollbackErr)
		}
		return errors.Join(cause, rollbackErr)
	}
	newInfo, err := statAtNoFollow(t.parent, t.leaf)
	if err != nil || !sameIdentity(stageInfo, newInfo) ||
		!sameDirectory(t.state.root.file, path.Dir(t.name), t.parentInfo) || !t.state.root.current() {
		return rollback(errResourceChanged)
	}
	if t.existed {
		oldInfo, oldErr := statAtNoFollow(t.parent, t.stageName)
		if oldErr != nil || !sameFileContentVersion(t.originalInfo, oldInfo) {
			return rollback(errResourceChanged)
		}
	}
	if t.state.method == "COPY" && !t.state.copyComplete(t.copyReadCount) {
		if t.state.preconditions != nil {
			t.state.conditionFailed = true
		}
		return rollback(errResourceChanged)
	}
	if err := t.syncParent(); err != nil {
		return rollback(err)
	}
	if t.existed {
		if err := unlinkAt(t.parent, t.stageName, false); err != nil {
			slog.Warn("dav overwrite committed with recoverable prior file", "path", t.name, "staging", t.stageName, "error", err)
			return nil
		}
		if err := t.syncParent(); err != nil {
			slog.Warn("dav overwrite committed; prior-file cleanup durability is uncertain", "path", t.name, "staging", t.stageName, "error", err)
			return nil
		}
	}
	if !t.existed {
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
	}
	return nil
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

func fmtName(name string, err error) error {
	if err == nil {
		return nil
	}
	return fmt.Errorf("%s: %w", name, err)
}
