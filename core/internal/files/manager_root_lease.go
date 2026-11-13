package files

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"

	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

type legacyTransitionError struct {
	kind  error
	cause error
}

func (e *legacyTransitionError) Error() string { return e.kind.Error() }
func (e *legacyTransitionError) Unwrap() error { return e.cause }
func (e *legacyTransitionError) Is(target error) bool {
	return target == e.kind || errors.Is(e.cause, target)
}

// ForgetOfflineRootWithLegacyTransition abandons a physically bound,
// disconnected single-share root and reattaches the private local default
// share. It never reads or modifies the old disk. The callbacks run while
// legacy requests are excluded and the Manager is exclusively locked.
func (m *Manager) ForgetOfflineRootWithLegacyTransition(validateIdle, revokeLegacyAccess func() error) (string, error) {
	if validateIdle == nil || revokeLegacyAccess == nil {
		return "", ErrLegacyTransitionRequired
	}
	unlock, err := m.tryLockLegacyTransition()
	if err != nil {
		return "", err
	}
	defer unlock()
	if m.pinned || m.configFault != nil {
		return "", ErrRootConfirmation
	}
	if m.onlineLocked() {
		return "", ErrRootConfirmation
	}
	if m.binding == nil || m.binding.Path != m.rootPath || m.binding.Validate() != nil {
		return "", ErrRootConfirmation
	}
	checker, ok := m.identity.(storageidentity.MountedVolumeProvider)
	if !ok {
		return "", ErrRootConfirmation
	}
	mounted, err := checker.IsVolumeMounted(context.Background(), m.binding.VolumeUUID)
	if err != nil || mounted {
		return "", ErrRootConfirmation
	}
	defaultRoot := filepath.Join(filepath.Dir(m.configFile), "SharedFiles")
	canonicalParent, err := filepath.EvalSymlinks(filepath.Dir(m.configFile))
	if err != nil {
		return "", err
	}
	if m.rootPath == defaultRoot || m.rootPath == filepath.Join(canonicalParent, "SharedFiles") {
		return "", ErrRootConfirmation
	}
	if err := validateIdle(); err != nil {
		return "", err
	}
	if err := os.MkdirAll(defaultRoot, 0700); err != nil {
		return "", err
	}
	infoAtPath, err := os.Lstat(defaultRoot)
	if err != nil || !infoAtPath.IsDir() || infoAtPath.Mode()&os.ModeSymlink != 0 {
		return "", ErrPath
	}
	resolved, err := filepath.EvalSymlinks(defaultRoot)
	if err != nil {
		return "", err
	}
	// A parent such as /var may be a standard macOS symlink to /private/var,
	// but the final SharedFiles component itself must never be a symlink.
	binding, err := m.identity.Capture(context.Background(), resolved)
	if err != nil {
		return "", err
	}
	if binding.Validate() != nil || binding.Path != resolved {
		return "", ErrOffline
	}
	next, err := openExisting(resolved)
	if err != nil {
		return "", err
	}
	if err := m.identity.Verify(context.Background(), binding); err != nil {
		next.Close()
		return "", err
	}
	info, err := next.root.Stat(".")
	if err != nil || !storageidentity.MatchesDirectory(binding, info) {
		next.Close()
		return "", ErrOffline
	}
	if err := revokeLegacyAccess(); err != nil {
		next.Close()
		return "", &legacyTransitionError{kind: ErrLegacyAccessRevocationUncertain, cause: err}
	}
	if err := m.saveRootConfig(rootConfig{Path: binding.Path, Binding: &binding}); err != nil {
		next.Close()
		return "", legacyRootPublicationError(err)
	}
	oldPath, old := m.rootPath, m.store
	m.store, m.rootPath, m.binding = next, binding.Path, &binding
	if old != nil {
		old.Close()
	}
	return oldPath, nil
}

// TryAcquireLegacyRequest reserves the current single-root identity for one
// legacy HTTP/DAV request. Root transitions fail fast while a request is in
// flight rather than waiting behind an arbitrarily long stream.
func (m *Manager) TryAcquireLegacyRequest() (func(), bool) {
	if m == nil || !m.legacyRequestGate.TryRLock() {
		return nil, false
	}
	var once sync.Once
	return func() { once.Do(m.legacyRequestGate.RUnlock) }, true
}

func (m *Manager) tryLockLegacyTransition() (func(), error) {
	if !m.legacyRequestGate.TryLock() {
		return nil, &legacyTransitionError{kind: ErrLegacyTransitionBusy, cause: ErrRootBusy}
	}
	if !m.mu.TryLock() {
		m.legacyRequestGate.Unlock()
		return nil, &legacyTransitionError{kind: ErrLegacyTransitionBusy, cause: ErrRootBusy}
	}
	return func() {
		m.mu.Unlock()
		m.legacyRequestGate.Unlock()
	}, nil
}

// DAVRootLease pins one share-root generation for the lifetime of a WebDAV
// request. It holds the manager read lock, so SetRoot and Close wait until the
// request has either completed or been cancelled.
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
