// Package rootmigration copies owner-selected data between two verified,
// independently registered NAS roots. It never changes default selection,
// account grants, quotas or source bytes.
package rootmigration

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"golang.org/x/sys/unix"
)

var (
	ErrInvalid = errors.New("migration_invalid_roots")
	ErrBusy    = errors.New("migration_already_running")
	ErrLimit   = errors.New("migration_scan_limit")
	ErrChanged = errors.New("migration_source_changed")
	ErrNoSpace = errors.New("migration_insufficient_space")
)

const (
	maxEntries = 200000
	maxDepth   = 48
	maxPath    = 2048
	maxBytes   = int64(1) << 50
)

// Selection pins a specific generation of each root. No directory path is
// accepted from a client, and two logical roots must be distinct.
type Selection struct {
	SourceRootID     string `json:"sourceRootID"`
	SourceGeneration uint64 `json:"sourceGeneration"`
	TargetRootID     string `json:"targetRootID"`
	TargetGeneration uint64 `json:"targetGeneration"`
}

type Preview struct {
	Selection
	FilesToCopy        int   `json:"filesToCopy"`
	BytesToCopy        int64 `json:"bytesToCopy"`
	DirectoriesToMake  int   `json:"directoriesToMake"`
	Conflicts          int   `json:"conflicts"`
	ProtectedFolders   int   `json:"protectedFolders"`
	UnsupportedEntries int   `json:"unsupportedEntries"`
	TargetFreeBytes    int64 `json:"targetFreeBytes"`
	HasEnoughSpace     bool  `json:"hasEnoughSpace"`
}

type Status struct {
	Phase        string  `json:"phase"`
	Preview      Preview `json:"preview"`
	CopiedFiles  int     `json:"copiedFiles"`
	CopiedBytes  int64   `json:"copiedBytes"`
	SkippedFiles int     `json:"skippedFiles"`
	StartedAt    int64   `json:"startedAt"`
	FinishedAt   int64   `json:"finishedAt,omitempty"`
	Error        string  `json:"error,omitempty"`
}

type Service struct {
	registry    *roots.Registry
	mu          sync.Mutex
	state       Status
	cancel      context.CancelFunc
	statePath   string
	lastSaved   time.Time
	onCompleted func(string)
}

func New(registry *roots.Registry) *Service {
	return &Service{registry: registry, state: Status{Phase: "idle"}}
}

// NewWithStateDir makes migration progress observable after an unexpected Core
// exit. Only status is persisted: the next run must rescan and verify both
// physical root identities instead of trusting stale paths or byte offsets.
func NewWithStateDir(registry *roots.Registry, dataDir string) *Service {
	s := New(registry)
	s.statePath = filepath.Join(dataDir, "root-migration-status.json")
	if content, err := os.ReadFile(s.statePath); err == nil && len(content) <= 64<<10 {
		var restored Status
		if json.Unmarshal(content, &restored) == nil {
			switch restored.Phase {
			case "running", "previewing":
				restored.Phase = "interrupted"
				restored.Error = "migration_interrupted_by_restart"
				restored.FinishedAt = time.Now().Unix()
			}
			s.state = restored
		}
	}
	s.persistLocked()
	return s
}

func (s *Service) SetOnCompleted(fn func(string)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.onCompleted = fn
}

// Persist only a small, owner-private summary, never the source file contents,
// guessed offsets or raw credentials. Atomic replacement survives a crash
// without falsely marking a partial copy as completed.
func (s *Service) persistLocked() {
	if s.statePath == "" {
		return
	}
	content, err := json.Marshal(s.state)
	if err != nil {
		return
	}
	dir := filepath.Dir(s.statePath)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return
	}
	temp, err := os.CreateTemp(dir, ".lightisle-migration-status-*")
	if err != nil {
		return
	}
	defer os.Remove(temp.Name())
	if temp.Chmod(0600) != nil {
		_ = temp.Close()
		return
	}
	_, err = temp.Write(content)
	if err == nil {
		err = temp.Sync()
	}
	if closeErr := temp.Close(); err == nil {
		err = closeErr
	}
	if err == nil && os.Rename(temp.Name(), s.statePath) == nil {
		if handle, err := os.Open(dir); err == nil {
			_ = handle.Sync()
			_ = handle.Close()
		}
		s.lastSaved = time.Now()
	}
}

func (s *Service) Status() Status {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.state
}

func (s *Service) Cancel() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if (s.state.Phase != "running" && s.state.Phase != "previewing") || s.cancel == nil {
		return false
	}
	s.cancel()
	return true
}

func (s *Service) Close() { s.Cancel() }

func (s *Service) openPair(ctx context.Context, selection Selection) (*roots.Lease, *roots.Lease, error) {
	if s == nil || s.registry == nil || selection.SourceRootID == "" ||
		selection.TargetRootID == "" || selection.SourceRootID == selection.TargetRootID ||
		selection.SourceGeneration == 0 || selection.TargetGeneration == 0 {
		return nil, nil, ErrInvalid
	}
	registered := s.registry.List()
	sourceOK, targetOK := false, false
	for _, root := range registered {
		if root.ID == selection.SourceRootID && root.Generation == selection.SourceGeneration {
			sourceOK = true
		}
		if root.ID == selection.TargetRootID && root.Generation == selection.TargetGeneration {
			targetOK = true
		}
	}
	if !sourceOK || !targetOK {
		return nil, nil, roots.ErrStale
	}
	source, err := s.registry.Acquire(ctx, selection.SourceRootID)
	if err != nil {
		return nil, nil, err
	}
	target, err := s.registry.Acquire(ctx, selection.TargetRootID)
	if err != nil {
		_ = source.Close()
		return nil, nil, err
	}
	if !source.Valid(ctx) || !target.Valid(ctx) {
		_ = target.Close()
		_ = source.Close()
		return nil, nil, roots.ErrStale
	}
	return source, target, nil
}

type fileItem struct {
	name     string
	size     int64
	modified time.Time
}
type scanResult struct {
	preview Preview
	dirs    []string
	files   []fileItem
}

// Both os.Root handles stay pinned by Registry leases throughout a pass;
// remove/rebind cannot occur until they close. Full provider verification
// (diskutil on macOS) is throttled to keep hundreds of thousands of small
// photo files from causing one diskutil process per file/read chunk.
type rootMonitor struct {
	source, target *roots.Lease
	lastChecked    time.Time
}

func (m *rootMonitor) Valid(ctx context.Context) bool {
	if ctx.Err() != nil {
		return false
	}
	if !m.lastChecked.IsZero() && time.Since(m.lastChecked) < time.Second {
		return true
	}
	if !m.source.Valid(ctx) || !m.target.Valid(ctx) {
		return false
	}
	m.lastChecked = time.Now()
	return true
}

// statSafe refuses symlink parents and symlink leaves. It does not make the
// eventual writer trust this preflight: Store.PublishLocal rechecks all
// components and publishes through an atomic no-replace hard link.
func statSafe(root *os.Root, name string) (os.FileInfo, error) {
	if name == "." {
		return root.Stat(".")
	}
	parts := strings.Split(name, "/")
	var info os.FileInfo
	for i, component := range parts {
		partial := strings.Join(parts[:i+1], "/")
		if component == "" || component == "." || component == ".." {
			return nil, files.ErrPath
		}
		var err error
		info, err = root.Lstat(partial)
		if err != nil {
			return nil, err
		}
		if info.Mode()&os.ModeSymlink != 0 || (i < len(parts)-1 && !info.IsDir()) {
			return nil, files.ErrPath
		}
	}
	return info, nil
}

func scan(ctx context.Context, source, target *roots.Lease, selection Selection) (scanResult, error) {
	result := scanResult{preview: Preview{Selection: selection}}
	monitor := &rootMonitor{source: source, target: target}
	type dirTask struct {
		name  string
		depth int
	}
	pending := []dirTask{{".", 0}}
	visited := 0
	for len(pending) > 0 {
		if err := ctx.Err(); err != nil {
			return scanResult{}, err
		}
		if !monitor.Valid(ctx) {
			return scanResult{}, roots.ErrStale
		}
		current := pending[len(pending)-1]
		pending = pending[:len(pending)-1]
		if current.depth > maxDepth {
			return scanResult{}, ErrLimit
		}
		expected, err := statSafe(source.Root, current.name)
		if err != nil || !expected.IsDir() {
			return scanResult{}, ErrChanged
		}
		dir, err := source.Root.Open(current.name)
		if err != nil {
			return scanResult{}, err
		}
		opened, err := dir.Stat()
		if err != nil || !os.SameFile(expected, opened) {
			_ = dir.Close()
			return scanResult{}, ErrChanged
		}
		for {
			batch, readErr := dir.ReadDir(128)
			if readErr != nil && !errors.Is(readErr, io.EOF) {
				_ = dir.Close()
				return scanResult{}, readErr
			}
			for _, entry := range batch {
				visited++
				if visited > maxEntries {
					_ = dir.Close()
					return scanResult{}, ErrLimit
				}
				if err := ctx.Err(); err != nil {
					_ = dir.Close()
					return scanResult{}, err
				}
				name := entry.Name()
				if files.IsInternalName(name) || name == ".DS_Store" {
					result.preview.UnsupportedEntries++
					continue
				}
				// User-private storage carries per-user quotas and ACLs.
				// Never copy its contents to a new identity as admin I/O:
				// that would bypass quota accounting and could expose
				// files through an older broad target-root grant.
				if current.name == "." && strings.EqualFold(name, "Users") {
					result.preview.ProtectedFolders++
					continue
				}
				relative := name
				if current.name != "." {
					relative = path.Join(current.name, name)
				}
				if len(relative) > maxPath {
					result.preview.UnsupportedEntries++
					continue
				}
				// Source symlinks, sockets and devices are never traversed,
				// even if an os.Root would constrain their ultimate target.
				if entry.Type()&os.ModeSymlink != 0 {
					result.preview.UnsupportedEntries++
					continue
				}
				info, err := statSafe(source.Root, relative)
				if err != nil {
					_ = dir.Close()
					return scanResult{}, err
				}
				existing, existsErr := statSafe(target.Root, relative)
				if errors.Is(existsErr, files.ErrPath) {
					// A target symlink (or symlinked parent) is a conflict,
					// never permission to follow it or replace it.
					result.preview.Conflicts++
					continue
				}
				if existsErr != nil && !errors.Is(existsErr, os.ErrNotExist) {
					_ = dir.Close()
					return scanResult{}, existsErr
				}
				exists := existsErr == nil
				switch {
				case info.IsDir():
					if exists && !existing.IsDir() {
						result.preview.Conflicts++
						continue
					}
					if !exists {
						result.preview.DirectoriesToMake++
					}
					result.dirs = append(result.dirs, relative)
					pending = append(pending, dirTask{relative, current.depth + 1})
				case info.Mode().IsRegular() && info.Size() >= 0 && info.Size() <= int64(1)<<40:
					if exists {
						result.preview.Conflicts++
						continue
					}
					if result.preview.BytesToCopy > maxBytes-info.Size() {
						_ = dir.Close()
						return scanResult{}, ErrLimit
					}
					result.preview.FilesToCopy++
					result.preview.BytesToCopy += info.Size()
					result.files = append(result.files, fileItem{name: relative, size: info.Size(), modified: info.ModTime()})
				default:
					result.preview.UnsupportedEntries++
				}
			}
			if errors.Is(readErr, io.EOF) {
				break
			}
		}
		if err := dir.Close(); err != nil {
			return scanResult{}, err
		}
	}
	return result, nil
}

func (s *Service) Preview(ctx context.Context, selection Selection) (Preview, error) {
	source, target, err := s.openPair(ctx, selection)
	if err != nil {
		return Preview{}, err
	}
	defer source.Close()
	defer target.Close()
	result, err := scan(ctx, source, target, selection)
	if err != nil {
		return Preview{}, err
	}
	if err := fillFreeSpace(target, &result.preview); err != nil {
		return Preview{}, err
	}
	return result.preview, nil
}

// StartPreview acknowledges immediately and performs large directory walks in
// the background. The private Mac IPC must not block its shared stdin reader
// for a 100k+ item photo library; callers poll Status and may cancel safely.
func (s *Service) StartPreview(parent context.Context, selection Selection) (Status, error) {
	s.mu.Lock()
	if s.state.Phase == "running" || s.state.Phase == "previewing" {
		s.mu.Unlock()
		return Status{}, ErrBusy
	}
	s.mu.Unlock()
	if source, target, err := s.openPair(parent, selection); err != nil {
		return Status{}, err
	} else {
		_ = target.Close()
		_ = source.Close()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.state.Phase == "running" || s.state.Phase == "previewing" {
		return Status{}, ErrBusy
	}
	ctx, cancel := context.WithCancel(parent)
	s.cancel = cancel
	s.state = Status{Phase: "previewing", Preview: Preview{Selection: selection}, StartedAt: time.Now().Unix()}
	s.persistLocked()
	go s.runPreview(ctx, cancel, selection)
	return s.state, nil
}

func (s *Service) runPreview(ctx context.Context, cancel context.CancelFunc, selection Selection) {
	defer cancel()
	preview, err := s.Preview(ctx, selection)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.state.FinishedAt = time.Now().Unix()
	s.cancel = nil
	switch {
	case errors.Is(err, context.Canceled):
		s.state.Phase = "cancelled"
	case err != nil:
		s.state.Phase = "failed"
		s.state.Error = err.Error()
	default:
		s.state.Phase = "previewed"
		s.state.Preview = preview
	}
	s.persistLocked()
}

// Fstatfs inspects the pinned directory descriptor, not a mutable mount
// pathname. Disk capacity is preflight only; a full disk during publication
// still safely fails without overwriting or deleting the source.
func fillFreeSpace(target *roots.Lease, preview *Preview) error {
	handle, err := target.Root.Open(".")
	if err != nil {
		return err
	}
	defer handle.Close()
	var stat unix.Statfs_t
	if err := unix.Fstatfs(int(handle.Fd()), &stat); err != nil {
		return err
	}
	if stat.Bavail < 0 || stat.Bsize <= 0 {
		return ErrNoSpace
	}
	free := uint64(stat.Bavail) * uint64(stat.Bsize)
	if free > uint64(maxBytes) {
		free = uint64(maxBytes)
	}
	preview.TargetFreeBytes = int64(free)
	// Retain a small filesystem safety reserve for directory entries and
	// metadata even when the source has many tiny files.
	const reserve = 64 << 20
	preview.HasEnoughSpace = free > uint64(preview.BytesToCopy)+reserve ||
		(preview.BytesToCopy == 0 && free > reserve)
	return nil
}

func (s *Service) Start(parent context.Context, selection Selection) (Status, error) {
	s.mu.Lock()
	if s.state.Phase == "running" || s.state.Phase == "previewing" {
		s.mu.Unlock()
		return Status{}, ErrBusy
	}
	s.mu.Unlock()
	// Fail fast if either root is already stale or offline, before returning
	// an accepted job to the native controller.
	source, target, err := s.openPair(parent, selection)
	if err != nil {
		return Status{}, err
	}
	_ = target.Close()
	_ = source.Close()
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.state.Phase == "running" || s.state.Phase == "previewing" {
		return Status{}, ErrBusy
	}
	ctx, cancel := context.WithCancel(parent)
	s.cancel = cancel
	s.state = Status{Phase: "running", Preview: Preview{Selection: selection}, StartedAt: time.Now().Unix()}
	s.persistLocked()
	go s.run(ctx, cancel, selection)
	return s.state, nil
}

func (s *Service) run(ctx context.Context, cancel context.CancelFunc, selection Selection) {
	defer cancel()
	err := s.copy(ctx, selection)
	s.mu.Lock()
	s.state.FinishedAt = time.Now().Unix()
	s.cancel = nil
	switch {
	case errors.Is(err, context.Canceled):
		s.state.Phase = "cancelled"
	case err != nil:
		s.state.Phase = "failed"
		s.state.Error = err.Error()
	default:
		s.state.Phase = "completed"
	}
	s.persistLocked()
	finished := s.state.Phase == "completed" && s.state.CopiedFiles > 0
	hook := s.onCompleted
	s.mu.Unlock()
	if finished && hook != nil {
		hook(selection.TargetRootID)
	}
}

type checkedReader struct {
	ctx        context.Context
	f          *os.File
	info       os.FileInfo
	monitor    *rootMonitor
	read       int64
	sinceCheck int64
}

func (r *checkedReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	if r.sinceCheck == 0 && !r.monitor.Valid(r.ctx) {
		return 0, roots.ErrStale
	}
	n, err := r.f.Read(p)
	r.read += int64(n)
	r.sinceCheck += int64(n)
	if r.sinceCheck >= 16<<20 {
		r.sinceCheck = 0
		if !r.monitor.Valid(r.ctx) {
			return n, roots.ErrStale
		}
	}
	if r.read > r.info.Size() {
		return n, ErrChanged
	}
	if errors.Is(err, io.EOF) {
		now, statErr := r.f.Stat()
		if statErr != nil || r.read != r.info.Size() || !os.SameFile(now, r.info) ||
			now.Size() != r.info.Size() || !now.ModTime().Equal(r.info.ModTime()) ||
			!r.monitor.Valid(r.ctx) {
			return n, ErrChanged
		}
	}
	return n, err
}

func (s *Service) copy(ctx context.Context, selection Selection) error {
	source, target, err := s.openPair(ctx, selection)
	if err != nil {
		return err
	}
	defer source.Close()
	defer target.Close()
	monitor := &rootMonitor{source: source, target: target}
	plan, err := scan(ctx, source, target, selection)
	if err != nil {
		return err
	}
	if err := fillFreeSpace(target, &plan.preview); err != nil {
		return err
	}
	s.mu.Lock()
	s.state.Preview = plan.preview
	s.persistLocked()
	s.mu.Unlock()
	if !plan.preview.HasEnoughSpace {
		return ErrNoSpace
	}
	// Only the target gets a writable Store. Its atomic no-replace journal
	// writes exclusively within the verified target's directory handle.
	dest, err := files.OpenPinnedStore(target.Root)
	if err != nil {
		return err
	}
	defer dest.Close()
	for _, dir := range plan.dirs {
		if err := ctx.Err(); err != nil {
			return err
		}
		if !monitor.Valid(ctx) {
			return roots.ErrStale
		}
		if info, statErr := dest.Stat(dir); statErr == nil {
			if !info.IsDir() {
				return files.ErrExists
			}
			continue
		} else if !errors.Is(statErr, os.ErrNotExist) {
			return statErr
		}
		if err := dest.Mkdir(dir); err != nil {
			if info, statErr := dest.Stat(dir); statErr != nil || !info.IsDir() {
				return err
			}
		}
	}
	for _, item := range plan.files {
		if err := ctx.Err(); err != nil {
			return err
		}
		if !monitor.Valid(ctx) {
			return roots.ErrStale
		}
		original, expected, err := sourceFile(source.Root, item.name)
		if err != nil {
			return err
		}
		if expected.Size() != item.size || !expected.ModTime().Equal(item.modified) {
			_ = original.Close()
			return fmt.Errorf("source %q: %w", item.name, ErrChanged)
		}
		reader := &checkedReader{ctx: ctx, f: original, info: expected, monitor: monitor}
		n, publishErr := dest.PublishLocal(item.name, reader)
		closeErr := original.Close()
		if errors.Is(publishErr, files.ErrExists) {
			s.mu.Lock()
			s.state.SkippedFiles++
			if time.Since(s.lastSaved) >= 3*time.Second {
				s.persistLocked()
			}
			s.mu.Unlock()
			continue
		}
		if publishErr != nil {
			return fmt.Errorf("copy %q: %w", item.name, publishErr)
		}
		if closeErr != nil || n != item.size {
			return fmt.Errorf("copy %q: %w", item.name, ErrChanged)
		}
		s.mu.Lock()
		s.state.CopiedFiles++
		s.state.CopiedBytes += n
		if time.Since(s.lastSaved) >= 3*time.Second {
			s.persistLocked()
		}
		s.mu.Unlock()
	}
	return nil
}

func sourceFile(root *os.Root, name string) (*os.File, os.FileInfo, error) {
	expected, err := statSafe(root, name)
	if err != nil {
		return nil, nil, err
	}
	if !expected.Mode().IsRegular() {
		return nil, nil, files.ErrType
	}
	f, err := root.Open(name)
	if err != nil {
		return nil, nil, err
	}
	opened, err := f.Stat()
	if err != nil || !os.SameFile(expected, opened) ||
		expected.Size() != opened.Size() || !expected.ModTime().Equal(opened.ModTime()) {
		_ = f.Close()
		return nil, nil, ErrChanged
	}
	return f, expected, nil
}
