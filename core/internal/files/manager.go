package files

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

var ErrOffline = errors.New("shared_directory_unavailable")
var ErrRootConfirmation = errors.New("shared_directory_confirmation_required")
var ErrRootPersistence = errors.New("shared_directory_save_uncertain_restart_required")

// Access is the subset required by HTTP handlers. The Manager serializes
// root switching against file operations; already open file handles remain valid.
type Access interface {
	CopyContext(context.Context, string, string) error
	TrashInfo(string) (TrashEntry, error)
	AbortUpload(string, int64) error
	ListUploads(string, int) ([]UploadRecord, string, error)
	CancelUpload(string) error
	CleanupExpiredUploads(int64) ([]string, int, bool, error)
	Move(string, string) error
	Copy(string, string) error
	Purge(string) error
	Search(string, string, int) ([]Entry, bool, error)
	BeginUpload(string, int64, int64) (UploadState, error)
	UploadInfo(string, int64) (UploadState, error)
	AppendUpload(string, int64, int64, io.Reader) (UploadState, error)
	FinishUpload(string, int64) error
	Page(string, string, int) ([]Entry, string, error)
	List(string) ([]Entry, error)
	Read(string) (*os.File, os.FileInfo, error)
	Mkdir(string) error
	Upload(string, io.Reader) (int64, error)
	MoveToTrash(string) error
	TrashList() ([]TrashEntry, error)
	Restore(string) error
	DisplayName() string
}

func (m *Manager) TrashInfo(id string) (entry TrashEntry, err error) {
	err = m.withRead(func(s *Store) (e error) { entry, e = s.TrashInfo(id); return e })
	return
}

func (m *Manager) AbortUpload(id string, owner int64) error {
	m.uploadMu.Lock()
	defer m.uploadMu.Unlock()
	return m.withRead(func(s *Store) error { return s.AbortUpload(id, owner) })
}

func (m *Manager) ListUploads(after string, limit int) (records []UploadRecord, next string, err error) {
	if !m.uploadMu.TryLock() {
		return nil, "", ErrUploadBusy
	}
	defer m.uploadMu.Unlock()
	err = m.withRead(func(s *Store) (e error) { records, next, e = s.ListUploads(after, limit); return e })
	return
}

func (m *Manager) CancelUpload(id string) error {
	if !m.uploadMu.TryLock() {
		return ErrUploadBusy
	}
	defer m.uploadMu.Unlock()
	return m.withRead(func(s *Store) error { return s.CancelUpload(id) })
}

func (m *Manager) CleanupExpiredUploads(beforeActivity int64) (removed []string, skipped int, hasMore bool, err error) {
	if !m.uploadMu.TryLock() {
		return nil, 0, false, ErrUploadBusy
	}
	defer m.uploadMu.Unlock()
	err = m.withRead(func(s *Store) (e error) {
		removed, skipped, hasMore, e = s.CleanupExpiredUploads(beforeActivity)
		return e
	})
	return
}

func (m *Manager) Move(from, to string) error {
	m.opMu.Lock()
	defer m.opMu.Unlock()
	return m.withRead(func(s *Store) error { return s.Move(from, to) })
}
func (m *Manager) Copy(from, to string) error {
	return m.CopyContext(context.Background(), from, to)
}
func (m *Manager) CopyContext(ctx context.Context, from, to string) error {
	m.opMu.Lock()
	defer m.opMu.Unlock()
	return m.withRead(func(s *Store) error { return s.CopyContext(ctx, from, to) })
}
func (m *Manager) Purge(id string) error {
	m.opMu.Lock()
	defer m.opMu.Unlock()
	return m.withRead(func(s *Store) error { return s.Purge(id) })
}
func (m *Manager) Search(base, query string, limit int) ([]Entry, bool, error) {
	var entries []Entry
	var truncated bool
	err := m.withRead(func(s *Store) (err error) { entries, truncated, err = s.Search(base, query, limit); return })
	return entries, truncated, err
}

func (m *Manager) Page(p, after string, limit int) (entries []Entry, next string, err error) {
	err = m.withRead(func(s *Store) (e error) { entries, next, e = s.Page(p, after, limit); return e })
	return
}

func (s *Store) DisplayName() string { return filepath.Base(s.root.Name()) }

type Manager struct {
	mu                sync.RWMutex
	opMu              sync.Mutex
	uploadMu          sync.Mutex
	store             *Store
	rootPath          string
	configFile        string
	binding           *storageidentity.Binding
	identity          storageidentity.Provider
	pinned            bool
	configFault       error
	syncRootDirectory func(*os.File) error
}

type rootConfig struct {
	Path    string                   `json:"path"`
	Binding *storageidentity.Binding `json:"binding,omitempty"`
}

func NewManager(dataDir string) (*Manager, error) {
	return newManagerWithIdentity(dataDir, storageidentity.SystemProvider{})
}

func newManagerWithIdentity(dataDir string, provider storageidentity.Provider) (*Manager, error) {
	m := &Manager{configFile: filepath.Join(dataDir, "shared-root.json"), identity: provider}
	defaultRoot := filepath.Join(dataDir, "SharedFiles")
	cfg := rootConfig{Path: defaultRoot}
	f, err := os.Open(m.configFile)
	firstInstall := errors.Is(err, os.ErrNotExist)
	if err == nil {
		data, readErr := io.ReadAll(io.LimitReader(f, 8193))
		f.Close()
		if readErr != nil {
			return nil, readErr
		}
		if len(data) > 8192 || json.Unmarshal(data, &cfg) != nil || !filepath.IsAbs(cfg.Path) || filepath.Clean(cfg.Path) != cfg.Path {
			return nil, errors.New("invalid shared folder configuration")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	m.rootPath = cfg.Path
	if cfg.Binding == nil && firstInstall {
		if err := os.MkdirAll(defaultRoot, 0700); err != nil {
			return nil, err
		}
		captured, e := provider.Capture(context.Background(), defaultRoot)
		if e != nil {
			slog.Warn("default share is offline until its physical volume can be verified", "reason", e)
			return m, nil
		}
		cfg.Path, cfg.Binding = captured.Path, &captured
		if err := m.saveRootConfig(cfg); err != nil {
			return nil, err
		}
		m.rootPath = cfg.Path
	}
	if cfg.Binding == nil {
		return m, nil
	}
	if cfg.Binding.Validate() != nil || cfg.Binding.Path != cfg.Path {
		return nil, errors.New("invalid shared folder identity")
	}
	binding := *cfg.Binding
	m.binding = &binding
	if err := provider.Verify(context.Background(), binding); err != nil {
		slog.Warn("shared root identity verification failed; keeping volume offline", "reason", err)
		return m, nil
	}
	opened, e := openExisting(binding.Path)
	if e != nil {
		slog.Warn("shared root directory cannot be opened; keeping volume offline", "reason", e)
		return m, nil
	}
	if err := provider.Verify(context.Background(), binding); err != nil {
		slog.Warn("shared root changed while opening; keeping volume offline", "reason", err)
		opened.Close()
		return m, nil
	}
	info, statErr := opened.root.Stat(".")
	if statErr != nil || !storageidentity.MatchesDirectory(binding, info) {
		slog.Warn("opened shared root does not match recorded directory identity", "stat_error", statErr)
		opened.Close()
		return m, nil
	}
	m.store = opened
	return m, nil
}

// NewPinnedManager clones a previously verified root descriptor. It never
// resolves the directory again by pathname and cannot be switched/reconnected.
func NewPinnedManager(root *os.Root, expected ...storageidentity.Binding) (*Manager, error) {
	if root == nil {
		return nil, ErrOffline
	}
	if len(expected) > 1 {
		return nil, ErrPath
	}
	clone, err := root.OpenRoot(".")
	if err != nil {
		return nil, err
	}
	store := &Store{root: clone}
	if err := store.ensureTrashDirectory(); err != nil {
		clone.Close()
		return nil, err
	}
	m := &Manager{store: store, rootPath: filepath.Clean(root.Name()), pinned: true}
	if len(expected) == 1 {
		binding := expected[0]
		info, err := clone.Stat(".")
		if err != nil || !storageidentity.MatchesDirectory(binding, info) || binding.Path != m.rootPath {
			clone.Close()
			return nil, ErrOffline
		}
		m.binding = &binding
	}
	return m, nil
}

func (m *Manager) saveRootConfig(cfg rootConfig) error {
	data, err := json.Marshal(cfg)
	if err != nil {
		return err
	}
	parent, err := os.OpenRoot(filepath.Dir(m.configFile))
	if err != nil {
		return err
	}
	defer parent.Close()
	tmp := ".lightisle-root-" + randomName() + ".tmp"
	file, err := parent.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer parent.Remove(tmp)
	n, err := file.Write(data)
	if err == nil && n != len(data) {
		err = io.ErrShortWrite
	}
	if err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err := parent.Rename(tmp, filepath.Base(m.configFile)); err != nil {
		return err
	}
	d, err := parent.Open(".")
	if err != nil {
		return err
	}
	defer d.Close()
	if m.syncRootDirectory != nil {
		err = m.syncRootDirectory(d)
	} else {
		err = d.Sync()
	}
	if err != nil {
		m.configFault = errors.Join(ErrRootPersistence, err)
		return m.configFault
	}
	return nil
}
func openExisting(dir string) (*Store, error) {
	info, err := os.Stat(dir)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() {
		return nil, ErrType
	}
	return Open(dir)
}
func (m *Manager) Close() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.store == nil {
		return nil
	}
	err := m.store.Close()
	m.store = nil
	return err
}
func (m *Manager) DisplayName() string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return filepath.Base(m.rootPath)
}
func (m *Manager) State() (string, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.rootPath, m.onlineLocked()
}

// A removable volume can be disconnected and another filesystem mounted at
// the same pathname. The Root handle remains tied to the original inode;
// never claim it is online or redirect writes to the replacement mount.
func (m *Manager) onlineLocked() bool {
	if m.store == nil || m.configFault != nil {
		return false
	}
	opened, err := m.store.root.Stat(".")
	if err != nil {
		return false
	}
	current, err := os.Stat(m.rootPath)
	if err != nil || !os.SameFile(opened, current) {
		return false
	}
	return m.binding == nil || (storageidentity.MatchesDirectory(*m.binding, opened) &&
		storageidentity.MatchesDirectory(*m.binding, current))
}

// Reconnect attempts to reopen the configured removable folder, only when the
// administrator explicitly requests retry (e.g. after reconnecting the drive).
func (m *Manager) Reconnect() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.configFault != nil {
		return m.configFault
	}
	if m.onlineLocked() {
		return nil
	}
	if m.pinned {
		return ErrOffline
	}
	if m.binding == nil {
		return ErrRootConfirmation
	}
	if err := m.identity.Verify(context.Background(), *m.binding); err != nil {
		return err
	}
	next, err := openExisting(m.rootPath)
	if err != nil {
		return err
	}
	if err := m.identity.Verify(context.Background(), *m.binding); err != nil {
		next.Close()
		return err
	}
	info, statErr := next.root.Stat(".")
	if statErr != nil || !storageidentity.MatchesDirectory(*m.binding, info) {
		next.Close()
		return ErrOffline
	}
	old := m.store
	m.store = next
	if old != nil {
		old.Close()
	}
	return nil
}
func allowedSelectedFolder(folder string) (string, error) {
	if !filepath.IsAbs(folder) {
		return "", ErrPath
	}
	resolved, err := filepath.EvalSymlinks(folder)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", err
	}
	if !info.IsDir() {
		return "", ErrType
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	home, err = filepath.EvalSymlinks(home)
	if err != nil {
		return "", err
	}
	allowedHome := strings.HasPrefix(resolved, home+string(filepath.Separator))
	// External volume must be a named mount or a child of that mount.
	allowedVolume := strings.HasPrefix(resolved, "/Volumes/") && len(strings.TrimPrefix(resolved, "/Volumes/")) > 0
	if !allowedHome && !allowedVolume {
		return "", ErrPath
	}
	return resolved, nil
}
func (m *Manager) SetRoot(folder string) error {
	if m.pinned {
		return ErrPath
	}
	resolved, err := allowedSelectedFolder(folder)
	if err != nil {
		return err
	}
	privateDir, err := filepath.EvalSymlinks(filepath.Dir(m.configFile))
	if err != nil {
		return err
	}
	inside := func(child, parent string) bool {
		return child == parent || strings.HasPrefix(child, parent+string(filepath.Separator))
	}
	if (inside(resolved, privateDir) || inside(privateDir, resolved)) &&
		!inside(resolved, filepath.Join(privateDir, "SharedFiles")) {
		return ErrPath
	}
	binding, err := m.identity.Capture(context.Background(), resolved)
	if err != nil {
		return err
	}
	if binding.Validate() != nil || binding.Path != resolved {
		return ErrOffline
	}
	next, err := openExisting(resolved)
	if err != nil {
		return err
	}
	if err := m.identity.Verify(context.Background(), binding); err != nil {
		next.Close()
		return err
	}
	info, statErr := next.root.Stat(".")
	if statErr != nil || !storageidentity.MatchesDirectory(binding, info) {
		next.Close()
		return ErrOffline
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.configFault != nil {
		next.Close()
		return m.configFault
	}
	if err := m.saveRootConfig(rootConfig{Path: binding.Path, Binding: &binding}); err != nil {
		next.Close()
		return err
	}
	old := m.store
	m.store = next
	m.rootPath = binding.Path
	m.binding = &binding
	if old != nil {
		old.Close()
	}
	return nil
}
func (m *Manager) withRead(fn func(*Store) error) error {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if !m.onlineLocked() {
		return ErrOffline
	}
	return fn(m.store)
}
func (m *Manager) List(p string) (entries []Entry, err error) {
	err = m.withRead(func(s *Store) (e error) { entries, e = s.List(p); return e })
	return
}
func (m *Manager) Read(p string) (f *os.File, info os.FileInfo, err error) {
	err = m.withRead(func(s *Store) (e error) { f, info, e = s.Read(p); return e })
	return
}
func (m *Manager) Mkdir(p string) error {
	return m.withRead(func(s *Store) error { return s.Mkdir(p) })
}
func (m *Manager) Upload(p string, r io.Reader) (n int64, err error) {
	err = m.withRead(func(s *Store) (e error) { n, e = s.Upload(p, r); return e })
	return
}
func (m *Manager) MoveToTrash(p string) error {
	return m.withRead(func(s *Store) error { return s.MoveToTrash(p) })
}
func (m *Manager) TrashList() (entries []TrashEntry, err error) {
	err = m.withRead(func(s *Store) (e error) { entries, e = s.TrashList(); return e })
	return
}
func (m *Manager) Restore(id string) error {
	return m.withRead(func(s *Store) error { return s.Restore(id) })
}

var _ Access = (*Manager)(nil)
var _ Access = (*Store)(nil)

func (m *Manager) BeginUpload(p string, size, owner int64) (v UploadState, e error) {
	m.uploadMu.Lock()
	defer m.uploadMu.Unlock()
	e = m.withRead(func(s *Store) (err error) { v, err = s.BeginUpload(p, size, owner); return err })
	return
}
func (m *Manager) UploadInfo(id string, owner int64) (v UploadState, e error) {
	m.uploadMu.Lock()
	defer m.uploadMu.Unlock()
	e = m.withRead(func(s *Store) (err error) { v, err = s.UploadInfo(id, owner); return err })
	return
}
func (m *Manager) AppendUpload(id string, owner, offset int64, r io.Reader) (v UploadState, e error) {
	m.uploadMu.Lock()
	defer m.uploadMu.Unlock()
	e = m.withRead(func(s *Store) (err error) { v, err = s.AppendUpload(id, owner, offset, r); return err })
	return
}
func (m *Manager) FinishUpload(id string, owner int64) (e error) {
	m.uploadMu.Lock()
	defer m.uploadMu.Unlock()
	return m.withRead(func(s *Store) error { return s.FinishUpload(id, owner) })
}
