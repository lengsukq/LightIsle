package dav

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/files"
	"golang.org/x/net/webdav"
)

const (
	writeReserve      = 64 << 20
	maxDAVUploadBytes = int64(32) << 30
	maxDAVCopyBytes   = int64(50) << 30
	maxDAVWalkEntries = 8192
	// Recheck volume space during the stream without calling fstatfs per chunk.
	davSpaceCheckInterval = 4 << 20
)

var errDAVWriteLimit = errors.New("dav write exceeds size limit")
var errDAVFreeSpace = errors.New("dav insufficient free space")

var errResourceChanged = errors.New("dav resource changed during request")
var errPreconditionFailed = errors.New("dav request precondition failed")

type grantedFS struct {
	service *Service
}

func stateFrom(ctx context.Context) (*requestState, bool) {
	state, ok := ctx.Value(requestStateKey{}).(*requestState)
	return state, ok && state != nil
}

func normalizeDAVName(name string) (string, error) {
	name = strings.TrimPrefix(name, "/")
	if name == "" || name == "." {
		return ".", nil
	}
	if strings.HasSuffix(name, "/") {
		name = strings.TrimSuffix(name, "/")
	}
	if name == "" || strings.ContainsAny(name, "\\\x00") || strings.HasPrefix(name, "/") || path.Clean(name) != name {
		return "", os.ErrPermission
	}
	for _, part := range strings.Split(name, "/") {
		if part == "" || part == "." || part == ".." || files.IsInternalName(part) {
			return "", os.ErrPermission
		}
	}
	return name, nil
}

func (f *grantedFS) authorize(ctx context.Context, name string, write bool) (*requestState, string, error) {
	state, ok := stateFrom(ctx)
	if !ok {
		return nil, "", os.ErrPermission
	}
	name, err := normalizeDAVName(name)
	if err != nil {
		return nil, "", err
	}
	// Private writes require quota accounting, including COPY/MOVE sources.
	// Only a root-scoped request may access the private namespace; old path-only
	// grants must never confer access to personal storage.
	if personalHomeNamespace(name) && !privateAccessAllowed(state, name, write) {
		return nil, "", os.ErrPermission
	}
	if !f.service.canAccess(state, name, write, !write) {
		return nil, "", os.ErrPermission
	}
	return state, name, nil
}

func personalHomeNamespace(name string) bool {
	return strings.EqualFold(name, "Users") ||
		(len(name) > 6 && name[5] == '/' && strings.EqualFold(name[:5], "Users"))
}

func privateReadAllowed(state *requestState, write bool) bool {
	return privateAccessAllowed(state, "Users", write)
}

func (f *grantedFS) Mkdir(ctx context.Context, name string, perm os.FileMode) error {
	state, name, err := f.authorize(ctx, name, true)
	if err != nil {
		return err
	}
	if name == "." || !state.root.current() {
		return os.ErrPermission
	}
	parent, leaf, err := openParentNoFollow(state.root.file, name)
	if err != nil {
		return err
	}
	defer parent.Close()
	parentInfo, err := parent.Stat()
	if err != nil || !sameDirectory(state.root.file, path.Dir(name), parentInfo) {
		return errResourceChanged
	}
	if state.method == "MKCOL" && state.preconditions != nil {
		current, statErr := statAtNoFollow(parent, leaf)
		exists := statErr == nil
		if statErr != nil && !errors.Is(statErr, fs.ErrNotExist) {
			return statErr
		}
		if !state.preconditions.matches(current, exists) || !state.preconditions.sameInitial(current, exists) {
			state.conditionFailed = true
			return errPreconditionFailed
		}
	}
	if err := mkdirAt(parent, leaf, 0700); err != nil {
		return err
	}
	entryInfo, err := statAtNoFollow(parent, leaf)
	if err != nil {
		_ = unlinkAt(parent, leaf, true)
		return err
	}
	if !state.root.current() || !sameDirectory(state.root.file, path.Dir(name), parentInfo) {
		_ = unlinkAt(parent, leaf, true)
		return errResourceChanged
	}
	state.addCreated(name, parentInfo, entryInfo, true)
	return nil
}

func (f *grantedFS) OpenFile(ctx context.Context, rawName string, flag int, perm os.FileMode) (webdav.File, error) {
	write := flag&(os.O_WRONLY|os.O_RDWR|os.O_APPEND|os.O_CREATE|os.O_TRUNC) != 0
	state, name, err := f.authorize(ctx, rawName, write)
	if err != nil {
		return nil, err
	}
	if name == "." {
		if write {
			return nil, os.ErrPermission
		}
		file, err := dupDirectory(state.root.file)
		if err != nil {
			return nil, err
		}
		return f.wrapRead(state, name, file), nil
	}
	if !write {
		parent, leaf, err := openParentNoFollow(state.root.file, name)
		if err != nil {
			return nil, err
		}
		file, err := openRegularAt(parent, leaf, 0, 0)
		_ = parent.Close()
		if err != nil {
			return nil, err
		}
		if state.method == "COPY" && state.preconditions != nil && name == state.preconditions.pathName {
			info, statErr := file.Stat()
			if statErr != nil || !state.preconditions.matches(info, true) || !state.preconditions.sameInitial(info, true) {
				state.conditionFailed = true
				_ = file.Close()
				return nil, errPreconditionFailed
			}
		}
		return f.wrapRead(state, name, file), nil
	}
	if err := checkSpace(state.root.file); err != nil {
		return nil, err
	}
	return f.openWrite(ctx, state, name, flag, perm)
}

func (f *grantedFS) wrapRead(state *requestState, name string, file *os.File) *safeFile {
	info, _ := file.Stat()
	state.canSee = func(child string) bool {
		return (!personalHomeNamespace(child) || privateReadAllowed(state, false)) &&
			f.service.canAccess(state, child, false, true)
	}
	safe := &safeFile{file: file, state: state, name: name, info: info, copySource: state.method == "COPY" && info != nil && info.Mode().IsRegular()}
	if safe.copySource {
		state.addCopySource(safe)
	}
	if info != nil && info.IsDir() {
		safe.filter = true
	}
	return safe
}

func (f *grantedFS) openWrite(ctx context.Context, state *requestState, name string, flag int, perm os.FileMode) (webdav.File, error) {
	if !state.root.current() || !f.service.canAccess(state, name, true, false) {
		return nil, os.ErrPermission
	}
	unlock, err := f.service.lockPath(ctx, state.root, name)
	if err != nil {
		return nil, err
	}
	parent, leaf, err := openParentNoFollow(state.root.file, name)
	if err != nil {
		unlock()
		return nil, err
	}
	parentInfo, err := parent.Stat()
	if err != nil || !sameDirectory(state.root.file, path.Dir(name), parentInfo) {
		parent.Close()
		unlock()
		return nil, errResourceChanged
	}
	targetInfo, statErr := statAtNoFollow(parent, leaf)
	exists := statErr == nil
	if statErr != nil && !errors.Is(statErr, fs.ErrNotExist) {
		parent.Close()
		unlock()
		return nil, statErr
	}
	if exists && !targetInfo.Mode().IsRegular() {
		parent.Close()
		unlock()
		return nil, os.ErrPermission
	}
	if !exists && flag&os.O_CREATE == 0 {
		parent.Close()
		unlock()
		return nil, fs.ErrNotExist
	}
	if exists && flag&os.O_CREATE != 0 && flag&os.O_EXCL != 0 {
		parent.Close()
		unlock()
		return nil, fs.ErrExist
	}
	if exists && state.requiresAbsent(name) {
		parent.Close()
		unlock()
		return nil, fs.ErrExist
	}
	if state.method == http.MethodPut {
		if !state.preconditions.matches(targetInfo, exists) || !state.preconditions.sameInitial(targetInfo, exists) {
			state.conditionFailed = true
			parent.Close()
			unlock()
			return nil, errPreconditionFailed
		}
	}
	if !state.root.current() || !sameDirectory(state.root.file, path.Dir(name), parentInfo) {
		parent.Close()
		unlock()
		return nil, errResourceChanged
	}
	reservationID, reservedSize, err := reservePersonalPut(state, name, exists)
	if err != nil {
		parent.Close()
		unlock()
		return nil, err
	}
	stageName, err := randomDAVName()
	if err != nil {
		if reservationID != "" {
			_ = f.service.store.ReleaseStorageReservation(reservationID)
		}
		parent.Close()
		unlock()
		return nil, err
	}
	fd, err := unixOpenAtStage(parent, stageName)
	if err != nil {
		if reservationID != "" {
			_ = f.service.store.ReleaseStorageReservation(reservationID)
		}
		parent.Close()
		unlock()
		return nil, err
	}
	stage := os.NewFile(uintptr(fd), path.Join(parent.Name(), stageName))
	txn := &writeTxn{
		service:       f.service,
		state:         state,
		name:          name,
		leaf:          leaf,
		parent:        parent,
		parentInfo:    parentInfo,
		stageName:     stageName,
		stage:         stage,
		existed:       exists,
		originalInfo:  targetInfo,
		unlock:        unlock,
		copyReadCount: state.copyCount(),
		permission:    0600,
		reservationID: reservationID,
		reservedSize:  reservedSize,
	}
	if exists {
		txn.permission = targetInfo.Mode().Perm()
	}
	if !exists && perm.Perm() != 0 {
		// Match the private-file policy used by the file manager. A random
		// staging name never exposes request bytes before the atomic publish.
		txn.permission = 0600
	}
	if err := stage.Chmod(txn.permission); err != nil {
		txn.abort()
		return nil, err
	}
	if exists && flag&os.O_TRUNC == 0 {
		source, openErr := openRegularAt(parent, leaf, 0, 0)
		if openErr != nil {
			txn.abort()
			return nil, openErr
		}
		_, copyErr := io.Copy(stage, source)
		closeErr := source.Close()
		if copyErr != nil || closeErr != nil {
			txn.abort()
			return nil, errors.Join(copyErr, closeErr)
		}
	}
	if flag&os.O_APPEND != 0 {
		if _, err := stage.Seek(0, io.SeekEnd); err != nil {
			txn.abort()
			return nil, err
		}
	} else if flag&os.O_TRUNC == 0 {
		if _, err := stage.Seek(0, io.SeekStart); err != nil {
			txn.abort()
			return nil, err
		}
	}
	return txn, nil
}

func (f *grantedFS) RemoveAll(ctx context.Context, rawName string) error {
	state, name, err := f.authorize(ctx, rawName, true)
	if err != nil {
		return err
	}
	// x/net removes the destination before a COPY or MOVE can succeed.
	// Refuse replacements at that boundary, including a destination
	// created concurrently after the handler's initial lookup.
	if state.method == "COPY" || state.method == "MOVE" {
		state.writeStatus = http.StatusPreconditionFailed
		return fs.ErrExist
	}
	if name == "." || !state.root.current() {
		return os.ErrPermission
	}
	parent, leaf, err := openParentNoFollow(state.root.file, name)
	if err != nil {
		return err
	}
	defer parent.Close()
	target, err := openRegularAt(parent, leaf, 0, 0)
	if err != nil {
		return err
	}
	defer target.Close()
	info, err := target.Stat()
	if err != nil {
		return err
	}
	if state.preconditions != nil &&
		(!state.preconditions.matches(info, true) || !state.preconditions.sameInitial(info, true)) {
		state.conditionFailed = true
		return errPreconditionFailed
	}
	if !sameDirectory(state.root.file, path.Dir(name), mustStat(parent)) || !state.root.current() {
		return errResourceChanged
	}
	if state.root.trash != nil {
		return state.root.trash(name, info)
	}
	if f.service.trash == nil {
		return os.ErrPermission
	}
	if !state.root.current() {
		return ErrUnavailable
	}
	return f.service.trash(name)
}

func mustStat(file *os.File) os.FileInfo {
	info, _ := file.Stat()
	return info
}

func (f *grantedFS) Rename(ctx context.Context, oldRaw, newRaw string) error {
	state, oldName, err := f.authorize(ctx, oldRaw, true)
	if err != nil {
		return err
	}
	if _, newName, err := f.authorize(ctx, newRaw, true); err != nil {
		return err
	} else {
		newRaw = newName
	}
	newName, _ := normalizeDAVName(newRaw)
	if oldName == "." || newName == "." || oldName == newName || !state.root.current() {
		return os.ErrPermission
	}
	if state.preconditions != nil {
		oldInfo, oldErr := secureStat(state.root.file, oldName)
		if oldErr != nil || !state.preconditions.matches(oldInfo, oldErr == nil) ||
			!state.preconditions.sameInitial(oldInfo, oldErr == nil) {
			state.conditionFailed = true
			return errPreconditionFailed
		}
	}
	oldParent, oldLeaf, err := openParentNoFollow(state.root.file, oldName)
	if err != nil {
		return err
	}
	defer oldParent.Close()
	newParent, newLeaf, err := openParentNoFollow(state.root.file, newName)
	if err != nil {
		return err
	}
	defer newParent.Close()
	oldParentInfo, err := oldParent.Stat()
	if err != nil || !sameDirectory(state.root.file, path.Dir(oldName), oldParentInfo) {
		return errResourceChanged
	}
	newParentInfo, err := newParent.Stat()
	if err != nil || !sameDirectory(state.root.file, path.Dir(newName), newParentInfo) {
		return errResourceChanged
	}
	sourceInfo, err := statAtNoFollow(oldParent, oldLeaf)
	if err != nil {
		return err
	}
	if sourceInfo.Mode()&os.ModeSymlink != 0 || (!sourceInfo.Mode().IsRegular() && !sourceInfo.IsDir()) {
		return os.ErrPermission
	}
	if _, err := statAtNoFollow(newParent, newLeaf); err == nil {
		return fs.ErrExist
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	if personalHomeNamespace(oldName) || personalHomeNamespace(newName) {
		return f.renamePersonalEntry(
			state, oldName, newName,
			oldParent, oldLeaf, oldParentInfo,
			newParent, newLeaf, newParentInfo,
			sourceInfo,
		)
	}
	if err := renameAtNoReplace(oldParent, oldLeaf, newParent, newLeaf); err != nil {
		return err
	}
	newInfo, err := statAtNoFollow(newParent, newLeaf)
	if err != nil || !sameIdentity(sourceInfo, newInfo) ||
		!sameDirectory(state.root.file, path.Dir(oldName), oldParentInfo) ||
		!sameDirectory(state.root.file, path.Dir(newName), newParentInfo) || !state.root.current() {
		rollbackErr := renameAtNoReplace(newParent, newLeaf, oldParent, oldLeaf)
		return errors.Join(errResourceChanged, rollbackErr)
	}
	if err := syncDirectory(newParent); err != nil {
		rollbackErr := renameAtNoReplace(newParent, newLeaf, oldParent, oldLeaf)
		return errors.Join(err, rollbackErr)
	}
	if path.Dir(oldName) != path.Dir(newName) {
		if err := syncDirectory(oldParent); err != nil {
			return err
		}
	}
	return nil
}

func (f *grantedFS) Stat(ctx context.Context, rawName string) (os.FileInfo, error) {
	state, name, err := f.authorize(ctx, rawName, false)
	if err != nil {
		return nil, err
	}
	if name == "." {
		return state.root.file.Stat()
	}
	info, err := secureStat(state.root.file, name)
	if errors.Is(err, fs.ErrNotExist) && (state.method == "COPY" || state.method == "LOCK") {
		state.markAbsent(name)
	}
	return info, err
}

func secureStat(root *os.File, name string) (os.FileInfo, error) {
	parent, leaf, err := openParentNoFollow(root, name)
	if err != nil {
		return nil, err
	}
	defer parent.Close()
	info, err := statAtNoFollow(parent, leaf)
	if err != nil {
		return nil, err
	}
	if info.Mode()&os.ModeSymlink != 0 || (!info.Mode().IsRegular() && !info.IsDir()) {
		return nil, os.ErrPermission
	}
	return info, nil
}

func checkSpace(root *os.File) error {
	free, err := freeBytes(root)
	if err == nil && free < writeReserve {
		return fs.ErrInvalid
	}
	return nil
}

func randomDAVName() (string, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	return ".lightisle-dav-" + hex.EncodeToString(raw[:]), nil
}
