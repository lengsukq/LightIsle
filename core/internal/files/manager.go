package files

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

var ErrOffline = errors.New("shared_directory_unavailable")

// Access is the subset required by HTTP handlers. The Manager serializes
// root switching against file operations; already open file handles remain valid.
type Access interface {
	CopyContext(context.Context, string, string) error
	TrashInfo(string) (TrashEntry, error)
	AbortUpload(string, int64) error
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
	mu         sync.RWMutex
	opMu       sync.Mutex
	uploadMu   sync.Mutex
	store      *Store
	rootPath   string
	configFile string
}

type rootConfig struct {
	Path string `json:"path"`
}

func NewManager(dataDir string) (*Manager, error) {
	m := &Manager{configFile: filepath.Join(dataDir, "shared-root.json")}
	defaultRoot := filepath.Join(dataDir, "SharedFiles")
	if err := os.MkdirAll(defaultRoot, 0700); err != nil {
		return nil, err
	}
	target := defaultRoot
	if b, err := os.ReadFile(m.configFile); err == nil {
		var cfg rootConfig
		if json.Unmarshal(b, &cfg) != nil || cfg.Path == "" {
			return nil, errors.New("invalid shared folder configuration")
		}
		target = cfg.Path
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	m.rootPath = target
	opened, err := openExisting(target)
	if err == nil {
		m.store = opened
	}
	// A removable volume can be offline. Never switch to the default automatically,
	// because doing so could make a user write into the wrong directory.
	return m, nil
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
	if m.store == nil {
		return false
	}
	opened, err := m.store.root.Stat(".")
	if err != nil {
		return false
	}
	current, err := os.Stat(m.rootPath)
	return err == nil && os.SameFile(opened, current)
}

// Reconnect attempts to reopen the configured removable folder, only when the
// administrator explicitly requests retry (e.g. after reconnecting the drive).
func (m *Manager) Reconnect() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.onlineLocked() {
		return nil
	}
	s, err := openExisting(m.rootPath)
	if err != nil {
		return err
	}
	old := m.store
	m.store = s
	if old != nil {
		_ = old.Close()
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
	resolved, err := allowedSelectedFolder(folder)
	if err != nil {
		return err
	}
	next, err := openExisting(resolved)
	if err != nil {
		return err
	}
	cfg, err := json.Marshal(rootConfig{Path: resolved})
	if err != nil {
		next.Close()
		return err
	}
	tmp := m.configFile + ".tmp"
	if err := os.WriteFile(tmp, cfg, 0600); err != nil {
		next.Close()
		return err
	}
	if err := os.Rename(tmp, m.configFile); err != nil {
		os.Remove(tmp)
		next.Close()
		return err
	}
	m.mu.Lock()
	old := m.store
	m.store = next
	m.rootPath = resolved
	m.mu.Unlock()
	if old != nil {
		_ = old.Close()
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
