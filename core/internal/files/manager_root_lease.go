package files

import (
	"os"
	"sync"
)

// DAVRootLease pins one share-root generation for the lifetime of a WebDAV
// request. It holds the manager read lock, so Close waits until the request
// has either completed or been cancelled.
type DAVRootLease struct {
	Path string
	Root *os.File
	Info os.FileInfo

	validate func() bool
	trash    func(string, os.FileInfo) error
	replace  func(string, string, os.FileInfo, os.FileInfo, func(string) error) error
	mu       sync.Mutex
	released bool
	release  func()
}

func (l *DAVRootLease) IsCurrent() bool {
	return l != nil && l.validate != nil && l.validate()
}

func (l *DAVRootLease) MoveToTrash(relative string, expected os.FileInfo) error {
	if l == nil || l.trash == nil || !l.IsCurrent() {
		return ErrOffline
	}
	return l.trash(relative, expected)
}

func (l *DAVRootLease) ReplaceFile(source, target string, expectedSource, expectedTarget os.FileInfo, finish func(string) error) error {
	if l == nil || l.replace == nil || !l.IsCurrent() {
		return ErrOffline
	}
	return l.replace(source, target, expectedSource, expectedTarget, finish)
}

func (l *DAVRootLease) Close() error {
	if l == nil {
		return nil
	}
	l.mu.Lock()
	if l.released {
		l.mu.Unlock()
		return nil
	}
	l.released = true
	root, release := l.Root, l.release
	l.mu.Unlock()
	var err error
	if root != nil {
		err = root.Close()
	}
	if release != nil {
		release()
	}
	return err
}

// AcquireDAVRootLease holds the current root generation stable for one DAV
// request. Call Close on every path, including request cancellation.
func (m *Manager) AcquireDAVRootLease() (*DAVRootLease, error) {
	m.mu.RLock()
	if !m.onlineLocked() {
		m.mu.RUnlock()
		return nil, ErrOffline
	}
	store := m.store
	root, err := store.root.Open(".")
	if err != nil {
		m.mu.RUnlock()
		return nil, err
	}
	info, err := root.Stat()
	if err != nil {
		root.Close()
		m.mu.RUnlock()
		return nil, err
	}
	lease := &DAVRootLease{Path: m.rootPath, Root: root, Info: info}
	lease.validate = func() bool {
		return m.store == store && m.onlineLocked()
	}
	lease.trash = func(relative string, expected os.FileInfo) error {
		if m.store != store || !m.onlineLocked() {
			return ErrOffline
		}
		return store.MoveToTrashIfUnchanged(relative, expected)
	}
	lease.replace = func(source, target string, expectedSource, expectedTarget os.FileInfo, finish func(string) error) error {
		if m.store != store || !m.onlineLocked() {
			return ErrOffline
		}
		return store.replaceDAVFile(source, target, expectedSource, expectedTarget, finish)
	}
	lease.release = m.mu.RUnlock
	return lease, nil
}
