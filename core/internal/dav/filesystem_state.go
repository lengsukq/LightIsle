package dav

import (
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"path"
	"sync"
	"time"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

type requestStateKey struct{}

type rootHandle struct {
	rootID     string
	generation uint64
	path       string
	file       *os.File
	info       os.FileInfo
	validate   func() bool
	trash      func(string, os.FileInfo) error
	release    func()
}

func (s *Service) canAccess(state *requestState, name string, write, traverse bool) bool {
	if state == nil || state.root == nil {
		return false
	}
	if state.root.rootID != "" {
		return s.store.CanAccessRootForUser(state.user.ID, state.root.rootID, name, write, traverse)
	}
	return s.store.CanAccessForUser(state.user.ID, name, write, traverse)
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
	body            io.ReadCloser
	controller      *http.ResponseController
	refreshDeadline time.Time
	mu              sync.Mutex
	eof             bool
	err             error
}

func (b *trackedBody) Read(p []byte) (int, error) {
	if b.controller != nil {
		now := time.Now()
		if !now.Before(b.refreshDeadline) {
			// Refresh periodically so a progressing large upload can finish,
			// while a stalled sender cannot hold a write slot indefinitely.
			_ = b.controller.SetReadDeadline(now.Add(time.Minute))
			b.refreshDeadline = now.Add(15 * time.Second)
		}
	}
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
	service       *Service
	user          auth.User
	root          *rootHandle
	lockNS        *lockNamespace
	method        string
	body          *trackedBody
	contentLength int64
	ctx           context.Context
	walkEntries   int
	walkLimited   bool
	writtenBytes  int64
	writeStatus   int

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

func (s *requestState) copyCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.copyReadCount
}

func (s *requestState) serviceCanSee(name string) bool {
	return s.canSee != nil && s.canSee(name)
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
	if f.copySource && f.state.ctx != nil {
		if err := f.state.ctx.Err(); err != nil {
			f.state.noteCopyRead(err)
			return 0, err
		}
	}
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
		!f.state.service.canAccess(f.state, f.name, false, false) {
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
		if f.state != nil && f.state.ctx != nil {
			if err := f.state.ctx.Err(); err != nil {
				return nil, err
			}
		}
		const batchSize = 128
		batch := batchSize
		if count > 0 {
			batch = min(batch, count-len(infos))
		}
		entries, err := f.file.ReadDir(batch)
		if f.state != nil && (f.state.method == "COPY" || f.state.method == "PROPFIND") {
			f.state.walkEntries += len(entries)
			if f.state.walkEntries > maxDAVWalkEntries {
				f.state.walkLimited = true
				return nil, errors.New("dav_directory_entry_limit")
			}
		}
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
		if count > 0 && len(infos) >= count {
			return infos, nil
		}
		if errors.Is(err, io.EOF) || len(entries) == 0 {
			if count <= 0 {
				return infos, nil
			}
			return infos, io.EOF
		}
	}
}

func (f *safeFile) stateRootCanSee(name string) bool {
	return f.state != nil && f.state.serviceCanSee(name)
}
