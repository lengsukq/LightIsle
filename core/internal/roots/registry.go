// Package roots maintains a physical-volume-bound registry for the personal
// NAS. No HTTP endpoint can mutate it. Existing v1 API retains its single
// root until all downstream consumers support root-scoped identities.
package roots

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

const maxRoots = 16

var (
	ErrInvalid            = errors.New("root_registry_invalid")
	ErrMissing            = errors.New("root_registry_unknown")
	ErrOffline            = errors.New("root_registry_offline")
	ErrOverlap            = errors.New("root_registry_overlap")
	ErrBusy               = errors.New("root_registry_busy")
	ErrStale              = errors.New("root_registry_stale")
	ErrDifferentDirectory = errors.New("root_registry_other_folder_requires_add")
	ErrNotAllowed         = errors.New("root_registry_path_not_allowed")
	ErrPersistence        = errors.New("root_registry_persistence_uncertain_restart_required")
)

type Root struct {
	ID            string                  `json:"rootID"`
	Name          string                  `json:"name"`
	Path          string                  `json:"path"`
	Binding       storageidentity.Binding `json:"binding"`
	Generation    uint64                  `json:"generation"`
	Pending       bool                    `json:"pending,omitempty"`
	Compatibility bool                    `json:"compatibility,omitempty"`
}

// ImportLegacy is idempotent and only runs for first-time migration when
// the v2 registry does not exist. Historical v1 path-only configuration is
// explicitly UNBOUND: no access is allowed until the Mac owner reselects the
// same physical folder through the native picker.
func (r *Registry) ImportLegacy(configPath string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.fault != nil {
		return r.fault
	}
	if _, err := os.Stat(r.file); err == nil {
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if len(r.roots) > 0 {
		return ErrInvalid
	}
	data, err := readBounded(configPath, 8192)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if len(data) > 8192 {
		return ErrInvalid
	}
	var old struct {
		Path    string                   `json:"path"`
		Binding *storageidentity.Binding `json:"binding,omitempty"`
	}
	if json.Unmarshal(data, &old) != nil || old.Path == "" {
		return ErrInvalid
	}
	if resolved, err := filepath.EvalSymlinks(old.Path); err == nil {
		// macOS may expose /var as /private/var. Preserve the historical
		// location as a canonical name, but NEVER grant access until the
		// owner confirms its physical identity.
		old.Path = filepath.Clean(resolved)
	}
	// The old single-root build allowed some Mac-owner-picked developer
	// directories outside the new registration policy. Preserve the historic
	// path ONLY as unbound metadata, never as an automatically trusted root.
	if !filepath.IsAbs(old.Path) || filepath.Clean(old.Path) != old.Path {
		return ErrInvalid
	}
	id, err := newID()
	if err != nil {
		return err
	}
	name := filepath.Base(old.Path)
	if name == "" || name == "." || name == "/" {
		return ErrInvalid
	}
	item := Root{ID: id, Name: name, Path: old.Path,
		Binding: storageidentity.Binding{Path: old.Path}, Generation: 1, Pending: true, Compatibility: true}
	if old.Binding != nil {
		if old.Binding.Validate() != nil || old.Binding.Path != old.Path {
			return ErrInvalid
		}
		if err := r.checkPersistedPath(old.Path); err != nil {
			return ErrNotAllowed
		}
		// Preserve an explicit previous binding even when its volume is now
		// offline. Acquire still verifies it before returning any handle.
		item.Binding = *old.Binding
		item.Pending = false
	}
	r.roots[id] = &entry{record: item}
	if err := r.saveLocked(); err != nil {
		delete(r.roots, id)
		return err
	}
	return nil
}

type diskState struct {
	Version int    `json:"version"`
	Roots   []Root `json:"roots"`
}

type Registry struct {
	mu         sync.Mutex
	file       string
	privateDir string
	provider   storageidentity.Provider
	allowed    []string
	roots      map[string]*entry
	// A failed directory sync after publication has an uncertain durable
	// outcome. Refuse further access until restart loads the published state.
	fault         error
	syncDirectory func(*os.File) error
}
type entry struct {
	record Root
	leases int
}

// Lease pins an already-open directory handle as well as its physical
// identity. A stale lease can never be rebound to a replacement path.
type Lease struct {
	registry *Registry
	id       string
	version  uint64
	Binding  storageidentity.Binding
	Root     *os.Root
	mu       sync.Mutex
	closed   bool
}

func Open(dataDir string) (*Registry, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	r, err := OpenWithProvider(dataDir, storageidentity.SystemProvider{}, home, "/Volumes", dataDir)
	if err != nil {
		return nil, err
	}
	if err = r.ImportLegacy(filepath.Join(dataDir, "shared-root.json")); err != nil {
		return nil, err
	}
	return r, nil
}

// OpenWithProvider is used by tests and deliberately accepts a path policy.
// Passing a fake provider must never be used in production.
func OpenWithProvider(dataDir string, provider storageidentity.Provider, allowed ...string) (*Registry, error) {
	if provider == nil || len(allowed) == 0 {
		return nil, ErrInvalid
	}
	approved := make([]string, 0, len(allowed))
	for _, p := range allowed {
		q, err := filepath.EvalSymlinks(p)
		if err != nil {
			return nil, err
		}
		approved = append(approved, filepath.Clean(q))
	}
	privateDir, err := filepath.EvalSymlinks(dataDir)
	if err != nil {
		return nil, err
	}
	r := &Registry{file: filepath.Join(dataDir, "shared-roots.json"), privateDir: privateDir, provider: provider, allowed: approved, roots: make(map[string]*entry)}
	bytes, err := readBounded(r.file, 128*1024)
	if errors.Is(err, os.ErrNotExist) {
		return r, nil
	}
	if err != nil {
		return nil, err
	}
	if len(bytes) > 128*1024 {
		return nil, ErrInvalid
	}
	var data diskState
	if err := json.Unmarshal(bytes, &data); err != nil || data.Version != 1 || len(data.Roots) > maxRoots {
		return nil, ErrInvalid
	}
	seen := map[string]bool{}
	for _, item := range data.Roots {
		if !validID(item.ID) || seen[item.ID] || item.Generation < 1 ||
			item.Name == "" || len(item.Name) > 120 || item.Path != item.Binding.Path ||
			(!item.Pending && item.Binding.Validate() != nil) {
			return nil, ErrInvalid
		}
		if item.Pending && item.Binding.VolumeUUID != "" {
			return nil, ErrInvalid
		}
		// An external volume may be disconnected on startup. Its historical
		// binding remains offline instead of making the registry unusable.
		if item.Pending {
			if !filepath.IsAbs(item.Path) || filepath.Clean(item.Path) != item.Path {
				return nil, ErrInvalid
			}
		} else if err := r.checkPersistedPath(item.Path); err != nil {
			return nil, fmt.Errorf("%w: %v", ErrInvalid, err)
		}
		for _, other := range r.roots {
			if overlap(item, other.record) {
				return nil, ErrOverlap
			}
		}
		seen[item.ID] = true
		r.roots[item.ID] = &entry{record: item}
	}
	return r, nil
}

func validID(id string) bool {
	if len(id) != 32 || strings.ToLower(id) != id {
		return false
	}
	_, err := hex.DecodeString(id)
	return err == nil
}

func readBounded(name string, limit int64) ([]byte, error) {
	f, err := os.Open(name)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, ErrInvalid
	}
	return data, nil
}
func (r *Registry) checkPath(name string) error {
	if !filepath.IsAbs(name) || filepath.Clean(name) != name {
		return ErrNotAllowed
	}
	if !safeFromPrivateData(name, r.privateDir) {
		return ErrNotAllowed
	}
	// Resolve symlinks before evaluating containment so the configured root
	// cannot escape via a linked ancestor.
	resolved, err := filepath.EvalSymlinks(name)
	if err != nil {
		return err
	}
	if resolved != name {
		return ErrNotAllowed
	}
	for _, base := range r.allowed {
		rel, err := filepath.Rel(base, name)
		if err == nil && rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
			return nil
		}
	}
	return ErrNotAllowed
}
func (r *Registry) checkPersistedPath(name string) error {
	if !filepath.IsAbs(name) || filepath.Clean(name) != name {
		return ErrNotAllowed
	}
	if !safeFromPrivateData(name, r.privateDir) {
		return ErrNotAllowed
	}
	for _, base := range r.allowed {
		rel, err := filepath.Rel(base, name)
		if err == nil && rel != "." && rel != ".." &&
			!strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
			// If mounted, refuse a path that now traverses symbolic links.
			// Offline roots remain stored but cannot be acquired before Verify.
			resolved, err := filepath.EvalSymlinks(name)
			if errors.Is(err, os.ErrNotExist) {
				return nil
			}
			if err != nil {
				return nil
			} // volume offline or no permissions
			if resolved != name {
				return ErrNotAllowed
			}
			return nil
		}
	}
	return ErrNotAllowed
}
func safeFromPrivateData(name, private string) bool {
	inside := func(child, parent string) bool {
		return child == parent || strings.HasPrefix(child, parent+string(filepath.Separator))
	}
	if !inside(name, private) && !inside(private, name) {
		return true
	}
	// The initial default share is deliberately inside application support;
	// no sibling metadata/cache directory may become a shared root.
	return inside(name, filepath.Join(private, "SharedFiles"))
}

func overlap(a, b Root) bool {
	if storageidentity.SameObject(a.Binding, b.Binding) {
		return true
	}
	x, y := a.Path, b.Path
	return x == y || strings.HasPrefix(x, y+string(os.PathSeparator)) || strings.HasPrefix(y, x+string(os.PathSeparator))
}
func (r *Registry) List() []Root {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]Root, 0, len(r.roots))
	for _, v := range r.roots {
		out = append(out, v.record)
	}
	// Deterministic JSON/snapshots.
	for i := 0; i < len(out); i++ {
		for j := i + 1; j < len(out); j++ {
			if out[j].ID < out[i].ID {
				out[i], out[j] = out[j], out[i]
			}
		}
	}
	return out
}
func newID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}
func (r *Registry) Add(ctx context.Context, name, location string) (Root, error) {
	if len(name) == 0 || len(name) > 120 {
		return Root{}, ErrInvalid
	}
	resolved, err := filepath.EvalSymlinks(location)
	if err != nil {
		return Root{}, err
	}
	resolved = filepath.Clean(resolved)
	if err = r.checkPath(resolved); err != nil {
		return Root{}, err
	}
	binding, err := r.provider.Capture(ctx, resolved)
	if err != nil {
		return Root{}, err
	}
	if err = binding.Validate(); err != nil {
		return Root{}, err
	}
	if binding.Path != resolved {
		return Root{}, ErrInvalid
	}
	id, err := newID()
	if err != nil {
		return Root{}, err
	}
	item := Root{ID: id, Name: name, Path: resolved, Binding: binding, Generation: 1}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.fault != nil {
		return Root{}, r.fault
	}
	if len(r.roots) >= maxRoots {
		return Root{}, ErrBusy
	}
	for _, v := range r.roots {
		if overlap(item, v.record) {
			return Root{}, ErrOverlap
		}
	}
	r.roots[id] = &entry{record: item}
	if err = r.saveLocked(); err != nil {
		delete(r.roots, id)
		return Root{}, err
	}
	return item, nil
}

// Rebind must only be called following an explicit owner selection. Existing
// leases are invalidated by generation; any active lease blocks the operation.
func (r *Registry) Rebind(ctx context.Context, id, location string) (Root, error) {
	resolved, err := filepath.EvalSymlinks(location)
	if err != nil {
		return Root{}, err
	}
	resolved = filepath.Clean(resolved)
	if err = r.checkPath(resolved); err != nil {
		return Root{}, err
	}
	binding, err := r.provider.Capture(ctx, resolved)
	if err != nil {
		return Root{}, err
	}
	if err = binding.Validate(); err != nil {
		return Root{}, err
	}
	if binding.Path != resolved {
		return Root{}, ErrInvalid
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.fault != nil {
		return Root{}, r.fault
	}
	e := r.roots[id]
	if e == nil {
		return Root{}, ErrMissing
	}
	if e.leases != 0 {
		return Root{}, ErrBusy
	}
	before := e.record
	next := before
	next.Path = resolved
	next.Binding = binding
	if next.Generation == ^uint64(0) {
		return Root{}, ErrInvalid
	}
	next.Generation++
	next.Pending = false
	for k, other := range r.roots {
		if k != id && overlap(next, other.record) {
			return Root{}, ErrOverlap
		}
	}
	// Critical ACL invariant: a logical root ID already owns member grants,
	// per-account media metadata and backup references. Rebinding it to a
	// different physical directory would silently grant access to unrelated
	// files. Allow the explicitly unbound legacy migration or the SAME inode
	// on the SAME volume (possibly remounted elsewhere). For a different
	// directory the owner must Add a fresh root ID and re-grant access.
	if before.Binding.Validate() == nil &&
		!storageidentity.SameObject(before.Binding, binding) {
		return Root{}, ErrDifferentDirectory
	}
	e.record = next
	if err = r.saveLocked(); err != nil {
		e.record = before
		return Root{}, err
	}
	return next, nil
}
func (r *Registry) Remove(id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.fault != nil {
		return r.fault
	}
	e := r.roots[id]
	if e == nil {
		return ErrMissing
	}
	if e.leases != 0 {
		return ErrBusy
	}
	delete(r.roots, id)
	if err := r.saveLocked(); err != nil {
		r.roots[id] = e
		return err
	}
	return nil
}
func (r *Registry) Acquire(ctx context.Context, id string) (*Lease, error) {
	r.mu.Lock()
	if r.fault != nil {
		err := r.fault
		r.mu.Unlock()
		return nil, err
	}
	e := r.roots[id]
	if e == nil {
		r.mu.Unlock()
		return nil, ErrMissing
	}
	value := e.record
	if value.Pending {
		r.mu.Unlock()
		return nil, ErrOffline
	}
	e.leases++
	r.mu.Unlock()
	release := func() { r.mu.Lock(); e.leases--; r.mu.Unlock() }
	// Verify the physical directory, not only a same-name mount. The second
	// registry check closes the gap with a concurrent explicit rebind/removal.
	if err := r.provider.Verify(ctx, value.Binding); err != nil {
		release()
		return nil, fmt.Errorf("%w: %v", ErrOffline, err)
	}
	handle, err := os.OpenRoot(value.Path)
	if err != nil {
		release()
		return nil, fmt.Errorf("%w: %v", ErrOffline, err)
	}
	if err = r.provider.Verify(ctx, value.Binding); err != nil {
		handle.Close()
		release()
		return nil, fmt.Errorf("%w: %v", ErrOffline, err)
	}
	opened, statErr := handle.Stat(".")
	if statErr != nil || !storageidentity.MatchesDirectory(value.Binding, opened) {
		handle.Close()
		release()
		return nil, ErrOffline
	}
	r.mu.Lock()
	valid := r.fault == nil && r.roots[id] == e && e.record.Generation == value.Generation
	r.mu.Unlock()
	if !valid {
		handle.Close()
		release()
		return nil, ErrStale
	}
	return &Lease{registry: r, id: id, version: value.Generation, Binding: value.Binding, Root: handle}, nil
}
func (l *Lease) Valid(ctx context.Context) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return false
	}
	l.registry.mu.Lock()
	e := l.registry.roots[l.id]
	valid := l.registry.fault == nil && e != nil && e.record.Generation == l.version &&
		storageidentity.Equal(e.record.Binding, l.Binding)
	l.registry.mu.Unlock()
	if !valid || l.registry.provider.Verify(ctx, l.Binding) != nil {
		return false
	}
	opened, err := l.Root.Stat(".")
	return err == nil && storageidentity.MatchesDirectory(l.Binding, opened)
}
func (l *Lease) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return nil
	}
	l.closed = true
	err := l.Root.Close()
	l.registry.mu.Lock()
	if e := l.registry.roots[l.id]; e != nil {
		e.leases--
	}
	l.registry.mu.Unlock()
	return err
}

func (r *Registry) saveLocked() error {
	state := diskState{Version: 1, Roots: make([]Root, 0, len(r.roots))}
	for _, e := range r.roots {
		state.Roots = append(state.Roots, e.record)
	}
	data, err := json.Marshal(state)
	if err != nil {
		return err
	}
	if len(data) > 128*1024 {
		return ErrInvalid
	}
	parent, err := os.OpenRoot(filepath.Dir(r.file))
	if err != nil {
		return err
	}
	defer parent.Close()
	directory, err := parent.Open(".")
	if err != nil {
		return err
	}
	defer directory.Close()
	id, err := newID()
	if err != nil {
		return err
	}
	temporary := ".lightisle-roots-" + id + ".tmp"
	f, err := parent.OpenFile(temporary, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer parent.Remove(temporary)
	n, err := f.Write(data)
	if err == nil && n != len(data) {
		err = io.ErrShortWrite
	}
	if err != nil {
		f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	if err = parent.Rename(temporary, filepath.Base(r.file)); err != nil {
		return err
	}
	if r.syncDirectory != nil {
		err = r.syncDirectory(directory)
	} else {
		err = directory.Sync()
	}
	if err != nil {
		r.fault = fmt.Errorf("%w: %v", ErrPersistence, err)
		return r.fault
	}
	return nil
}
