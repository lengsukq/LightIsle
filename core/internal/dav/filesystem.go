package dav

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"net/http"
	"os"
	"path"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/webdav"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

const writeReserve = 64 << 20

var errResourceChanged = errors.New("dav resource changed during request")
var errPreconditionFailed = errors.New("dav request precondition failed")

type requestStateKey struct{}

type rootHandle struct {
	path     string
	file     *os.File
	info     os.FileInfo
	validate func() bool
	trash    func(string, os.FileInfo) error
	release  func()
}

func (r *rootHandle) close() {
	if r.release != nil {
		r.release()
		return
	}
	if r.file != nil {
		_ = r.file.Close()
	}
}

func (r *rootHandle) current() bool {
	if r.validate != nil {
		return r.validate()
	}
	current, err := openRootDirectory(r.path)
	if err != nil {
		return false
	}
	defer current.Close()
	info, err := current.Stat()
	return err == nil && sameIdentity(r.info, info)
}

type trackedBody struct {
	body io.ReadCloser
	mu   sync.Mutex
	eof  bool
	err  error
}

func (b *trackedBody) Read(p []byte) (int, error) {
	n, err := b.body.Read(p)
	if err != nil {
		b.mu.Lock()
		if errors.Is(err, io.EOF) {
			b.eof = true
		} else if b.err == nil {
			b.err = err
		}
		b.mu.Unlock()
	}
	return n, err
}

func (b *trackedBody) Close() error { return b.body.Close() }

func (b *trackedBody) complete() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.eof && b.err == nil
}

func (b *trackedBody) failure() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.err
}

type createdEntry struct {
	name       string
	parentInfo os.FileInfo
	entryInfo  os.FileInfo
	directory  bool
}

type requestState struct {
	service *Service
	user    auth.User
	root    *rootHandle
	lockNS  *lockNamespace
	method  string
	body    *trackedBody

	mu              sync.Mutex
	copyReadCount   int
	copyReadErr     error
	currentCopy     *safeFile
	created         []createdEntry
	mustBeAbsent    map[string]bool
	preconditions   *requestPreconditions
	conditionFailed bool
	canSee          func(string) bool
}

func (s *requestState) noteCopyRead(err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err != nil && !errors.Is(err, io.EOF) && s.copyReadErr == nil {
		s.copyReadErr = err
	}
	if errors.Is(err, io.EOF) {
		s.copyReadCount++
	}
}

func (s *requestState) copyComplete(after int) bool {
	s.mu.Lock()
	err, count, source := s.copyReadErr, s.copyReadCount, s.currentCopy
	s.mu.Unlock()
	if err != nil || count <= after || source == nil {
		return false
	}
	return source.copyStable()
}

func (s *requestState) addCopySource(source *safeFile) {
	s.mu.Lock()
	s.currentCopy = source
	s.mu.Unlock()
}

func (s *requestState) addCreated(name string, parentInfo, entryInfo os.FileInfo, directory bool) {
	s.mu.Lock()
	s.created = append(s.created, createdEntry{name: name, parentInfo: parentInfo, entryInfo: entryInfo, directory: directory})
	s.mu.Unlock()
}

func (s *requestState) markAbsent(name string) {
	s.mu.Lock()
	if s.mustBeAbsent == nil {
		s.mustBeAbsent = map[string]bool{}
	}
	s.mustBeAbsent[name] = true
	s.mu.Unlock()
}

func (s *requestState) requiresAbsent(name string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.mustBeAbsent[name]
}

func (s *requestState) cleanupCreated() {
	s.mu.Lock()
	created := append([]createdEntry(nil), s.created...)
	s.mu.Unlock()
	for i := len(created) - 1; i >= 0; i-- {
		entry := created[i]
		parent, leaf, err := openParentNoFollow(s.root.file, entry.name)
		if err != nil {
			continue
		}
		parentInfo, infoErr := parent.Stat()
		if infoErr == nil && sameIdentity(parentInfo, entry.parentInfo) {
			current, statErr := statAtNoFollow(parent, leaf)
			unchanged := statErr == nil && sameFileVersion(current, entry.entryInfo)
			if entry.directory {
				unchanged = statErr == nil && current.IsDir() && sameIdentity(current, entry.entryInfo)
			}
			if unchanged {
				_ = unlinkAt(parent, leaf, entry.directory)
			}
		}
		_ = parent.Close()
	}
}

type requestPreconditions struct {
	pathName          string
	ifMatch           string
	ifNoneMatch       string
	ifUnmodifiedSince string
	initialExists     bool
	initialInfo       os.FileInfo
}

func (p *requestPreconditions) matches(info os.FileInfo, exists bool) bool {
	if p == nil {
		return true
	}
	if p.ifMatch != "" {
		if !exists {
			return false
		}
		etag := davETag(info)
		if !etagListMatches(p.ifMatch, etag, false) {
			return false
		}
	}
	if p.ifNoneMatch != "" && exists && etagListMatches(p.ifNoneMatch, davETag(info), true) {
		return false
	}
	if p.ifUnmodifiedSince != "" && exists {
		if t, err := http.ParseTime(p.ifUnmodifiedSince); err == nil && info.ModTime().Truncate(time.Second).After(t) {
			return false
		}
	}
	return true
}

func (p *requestPreconditions) sameInitial(info os.FileInfo, exists bool) bool {
	if p == nil {
		return true
	}
	if p.initialExists != exists {
		return false
	}
	return !exists || sameFileVersion(p.initialInfo, info)
}

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
		if part == "" || part == "." || part == ".." || strings.HasPrefix(part, ".lightisle-") || part == files.Trash {
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
	if !f.service.store.CanAccessForUser(state.user.ID, name, write, !write) {
		return nil, "", os.ErrPermission
	}
	return state, name, nil
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
		return f.service.store.CanAccessForUser(state.user.ID, child, false, true)
	}
	safe := &safeFile{file: file, state: state, name: name, info: info, copySource: state.method == "COPY" && info != nil && info.Mode().IsRegular()}
	if safe.copySource {
		state.addCopySource(safe)
	}
	if info != nil && info.IsDir() && state.user.Role != auth.RoleAdmin {
		safe.filter = true
	}
	return safe
}

func (f *grantedFS) openWrite(ctx context.Context, state *requestState, name string, flag int, perm os.FileMode) (webdav.File, error) {
	if !state.root.current() || !f.service.store.CanAccessForUser(state.user.ID, name, true, false) {
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
	stageName, err := randomDAVName()
	if err != nil {
		parent.Close()
		unlock()
		return nil, err
	}
	fd, err := unixOpenAtStage(parent, stageName)
	if err != nil {
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

func (s *requestState) copyCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.copyReadCount
}

func (f *grantedFS) RemoveAll(ctx context.Context, rawName string) error {
	state, name, err := f.authorize(ctx, rawName, true)
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
		err := state.root.trash(name, info)
		if err == nil && state.method == "COPY" {
			state.markAbsent(name)
		}
		return err
	}
	if f.service.trash == nil {
		return os.ErrPermission
	}
	if !state.root.current() {
		return ErrUnavailable
	}
	err = f.service.trash(name)
	if err == nil && state.method == "COPY" {
		state.markAbsent(name)
	}
	return err
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

type safeFile struct {
	file       *os.File
	state      *requestState
	name       string
	info       os.FileInfo
	copySource bool
	copyEOF    bool
	closed     bool
	stable     bool
	filter     bool
}

func (f *safeFile) Close() error {
	if f.copySource {
		current, err := f.file.Stat()
		f.stable = err == nil && sameFileVersion(f.info, current)
		f.closed = true
	}
	return f.file.Close()
}

func (f *safeFile) Read(p []byte) (int, error) {
	n, err := f.file.Read(p)
	if f.copySource {
		if err != nil && !errors.Is(err, io.EOF) {
			f.state.noteCopyRead(err)
		} else if errors.Is(err, io.EOF) {
			f.copyEOF = true
			f.state.noteCopyRead(io.EOF)
		}
	}
	return n, err
}

func (f *safeFile) Write(p []byte) (int, error) { return f.file.Write(p) }
func (f *safeFile) Seek(offset int64, whence int) (int64, error) {
	return f.file.Seek(offset, whence)
}
func (f *safeFile) Stat() (os.FileInfo, error) { return f.file.Stat() }

func (f *safeFile) copyStable() bool {
	if !f.copySource {
		return true
	}
	if f.state == nil || f.state.service == nil || !f.state.root.current() ||
		!f.state.service.store.CanAccessForUser(f.state.user.ID, f.name, false, false) {
		return false
	}
	if f.closed {
		return f.stable
	}
	current, err := f.file.Stat()
	return err == nil && sameFileVersion(f.info, current)
}

func (f *safeFile) Readdir(count int) ([]os.FileInfo, error) {
	infos := make([]os.FileInfo, 0)
	for {
		remaining := count - len(infos)
		if count <= 0 {
			remaining = 0
		}
		entries, err := f.file.ReadDir(remaining)
		if err != nil && !errors.Is(err, io.EOF) {
			return infos, err
		}
		for _, entry := range entries {
			info, statErr := statAtNoFollow(f.file, entry.Name())
			if statErr != nil || (!info.Mode().IsRegular() && !info.IsDir()) || info.Mode()&os.ModeSymlink != 0 {
				continue
			}
			child := entry.Name()
			if f.name != "." {
				child = path.Join(f.name, entry.Name())
			}
			if _, nameErr := normalizeDAVName(child); nameErr != nil {
				continue
			}
			if f.filter && !f.stateRootCanSee(child) {
				continue
			}
			infos = append(infos, info)
		}
		if count <= 0 || len(infos) >= count {
			return infos, nil
		}
		if errors.Is(err, io.EOF) || len(entries) == 0 {
			return infos, io.EOF
		}
	}
}

func (f *safeFile) stateRootCanSee(name string) bool {
	return f.state != nil && f.state.user.Role == auth.RoleAdmin ||
		f.state != nil && f.state.serviceCanSee(name)
}

func (s *requestState) serviceCanSee(name string) bool {
	return s.canSee != nil && s.canSee(name)
}

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
	n, err := t.stage.Write(p)
	if err != nil && t.writeErr == nil {
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
	if !t.state.root.current() || !t.service.store.CanAccessForUser(t.state.user.ID, t.name, true, false) {
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
	if err := t.stage.Close(); err != nil {
		t.stage = nil
		_ = unlinkAt(t.parent, t.stageName, false)
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
		newInfo, _ = statAtNoFollow(t.parent, t.leaf)
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
