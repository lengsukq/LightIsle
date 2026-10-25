package roots

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

type provider struct{ fail bool }

func (p *provider) Capture(_ context.Context, where string) (storageidentity.Binding, error) {
	if p.fail {
		return storageidentity.Binding{}, errors.New("disconnected")
	}
	info, err := os.Stat(where)
	if err != nil {
		return storageidentity.Binding{}, err
	}
	// Only the volume UUID is simulated; capture real directory inode,
	// generation and birthtime to test same-path directory replacement.
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return storageidentity.Binding{}, errors.New("stat identity unavailable")
	}
	return storageidentity.Binding{Path: where, VolumeUUID: "12345678-1234-1234-1234-123456789abc",
		DirectoryID: stat.Ino, BirthSec: stat.Birthtimespec.Sec, BirthNsec: stat.Birthtimespec.Nsec,
		Generation: uint64(stat.Gen)}, nil
}

func TestLegacyMigrationRequiresExplicitRebind(t *testing.T) {
	ctx := context.Background()
	r, p, base := setup(t)
	legacy := dir(t, base, "legacy")
	config := filepath.Join(filepath.Dir(r.file), "shared-root.json")
	if err := os.WriteFile(config, []byte(`{"path":"`+legacy+`"}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := r.ImportLegacy(config); err != nil {
		t.Fatal(err)
	}
	items := r.List()
	if len(items) != 1 || !items[0].Pending || items[0].Binding.VolumeUUID != "" {
		t.Fatalf("legacy wasn't safely unbound: %+v", items)
	}
	if _, err := r.Acquire(ctx, items[0].ID); !errors.Is(err, ErrOffline) {
		t.Fatalf("legacy auto-mounted: %v", err)
	}
	if err := r.ImportLegacy(config); err != nil {
		t.Fatal(err)
	}
	if again := r.List(); len(again) != 1 || again[0].ID != items[0].ID {
		t.Fatal("migration changed ID")
	}
	reloaded, err := OpenWithProvider(filepath.Dir(r.file), p, base)
	if err != nil || len(reloaded.List()) != 1 || !reloaded.List()[0].Pending {
		t.Fatalf("pending not persisted: %v", err)
	}
	bound, err := r.Rebind(ctx, items[0].ID, legacy)
	if err != nil || bound.Pending || bound.Generation != 2 {
		t.Fatalf("explicit rebind: %+v %v", bound, err)
	}
	lease, err := r.Acquire(ctx, bound.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close()
	if !lease.Valid(ctx) {
		t.Fatal("owner-confirmed binding unexpectedly invalid")
	}
}
func (p *provider) Verify(ctx context.Context, b storageidentity.Binding) error {
	a, err := p.Capture(ctx, b.Path)
	if err != nil {
		return err
	}
	if !storageidentity.Equal(a, b) {
		return storageidentity.ErrMismatch
	}
	return nil
}

func TestBoundLegacyMigrationPreservesVerifiedIdentityAndStableID(t *testing.T) {
	r, p, base := setup(t)
	location := dir(t, base, "bound")
	binding, err := p.Capture(context.Background(), location)
	if err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(map[string]any{"path": location, "binding": binding})
	if err := os.WriteFile(filepath.Join(filepath.Dir(r.file), "shared-root.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := r.ImportLegacy(filepath.Join(filepath.Dir(r.file), "shared-root.json")); err != nil {
		t.Fatal(err)
	}
	items := r.List()
	if len(items) != 1 || items[0].Pending || !items[0].Compatibility {
		t.Fatalf("owner binding lost: %+v", items)
	}
	lease, err := r.Acquire(context.Background(), items[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	lease.Close()
	p.fail = true
	reloaded, err := OpenWithProvider(filepath.Dir(r.file), p, base)
	if err != nil {
		t.Fatal(err)
	}
	if reloaded.List()[0].ID != items[0].ID {
		t.Fatal("logical ID changed")
	}
	if _, err := reloaded.Acquire(context.Background(), items[0].ID); !errors.Is(err, ErrOffline) {
		t.Fatalf("offline binding not preserved: %v", err)
	}
}
func setup(t *testing.T) (*Registry, *provider, string) {
	t.Helper()
	base := t.TempDir()
	source := filepath.Join(base, "volumes")
	if err := os.Mkdir(source, 0700); err != nil {
		t.Fatal(err)
	}
	data := filepath.Join(base, "data")
	if err := os.Mkdir(data, 0700); err != nil {
		t.Fatal(err)
	}
	p := &provider{}
	reg, err := OpenWithProvider(data, p, source)
	if err != nil {
		t.Fatal(err)
	}
	return reg, p, source
}
func dir(t *testing.T, base, rel string) string {
	t.Helper()
	path := filepath.Join(base, rel)
	if err := os.MkdirAll(path, 0700); err != nil {
		t.Fatal(err)
	}
	canonical, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	return canonical
}
func TestRegistryPersistenceLeaseAndOverlap(t *testing.T) {
	ctx := context.Background()
	reg, p, base := setup(t)
	a := dir(t, base, "disk-a")
	b := dir(t, base, "disk-b")
	nested := dir(t, a, "nested")
	first, err := reg.Add(ctx, "照片", a)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := reg.Add(ctx, "重叠目录", nested); !errors.Is(err, ErrOverlap) {
		t.Fatalf("nested: %v", err)
	}
	second, err := reg.Add(ctx, "影视", b)
	if err != nil {
		t.Fatal(err)
	}
	if first.ID == second.ID || len(reg.List()) != 2 {
		t.Fatal("IDs/entries")
	}
	lease, err := reg.Acquire(ctx, first.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !lease.Valid(ctx) {
		t.Fatal("valid lease marked invalid")
	}
	if err := reg.Remove(first.ID); !errors.Is(err, ErrBusy) {
		t.Fatalf("active lease removed: %v", err)
	}
	if _, err := reg.Rebind(ctx, first.ID, b); !errors.Is(err, ErrBusy) {
		t.Fatalf("active rebind: %v", err)
	}
	if err := lease.Close(); err != nil {
		t.Fatal(err)
	}
	if err := lease.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := OpenWithProvider(filepath.Dir(reg.file), p, base)
	if err != nil {
		t.Fatal(err)
	}
	if got := reopened.List(); len(got) != 2 || got[0].ID == got[1].ID {
		t.Fatalf("persist %v", got)
	}
	if err := reg.Remove(second.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := reg.Rebind(ctx, first.ID, b); !errors.Is(err, ErrDifferentDirectory) {
		t.Fatalf("an unrelated physical folder inherited root grants: %v", err)
	}
	updated, err := reg.Rebind(ctx, first.ID, a)
	if err != nil {
		t.Fatal(err)
	}
	if updated.Generation != 2 {
		t.Fatal("generation did not increment")
	}
	if err := reg.Remove(first.ID); err != nil {
		t.Fatal(err)
	}
}
func TestRegistryFailClosed(t *testing.T) {
	ctx := context.Background()
	r, p, base := setup(t)
	a := dir(t, base, "disk-a")
	if _, err := r.Add(ctx, "escape", filepath.Dir(base)); !errors.Is(err, ErrNotAllowed) {
		t.Fatalf("boundary: %v", err)
	}
	first, err := r.Add(ctx, "photos", a)
	if err != nil {
		t.Fatal(err)
	}
	p.fail = true
	if _, err := r.Acquire(ctx, first.ID); !errors.Is(err, ErrOffline) {
		t.Fatalf("offline: %v", err)
	}
	p.fail = false
	// Path replaced with a different directory object must fail closed even
	// when a new folder carries the same name.
	if err := os.Rename(a, a+"-old"); err != nil {
		t.Fatal(err)
	}
	offline, err := OpenWithProvider(filepath.Dir(r.file), p, base)
	if err != nil || len(offline.List()) != 1 {
		t.Fatalf("offline volume lost registry: %v", err)
	}
	if _, err := offline.Acquire(ctx, first.ID); !errors.Is(err, ErrOffline) {
		t.Fatalf("offline root should reject lease: %v", err)
	}
	if err := os.Mkdir(a, 0700); err != nil {
		t.Fatal(err)
	}
	// Same pathname is now bound to a NEW inode. A lease must be refused.
	if _, err := r.Acquire(ctx, first.ID); !errors.Is(err, ErrOffline) {
		t.Fatalf("replaced: %v", err)
	}
	if _, err := r.Rebind(ctx, first.ID, a); !errors.Is(err, ErrDifferentDirectory) {
		t.Fatalf("same-path different inode inherited previous permissions: %v", err)
	}
	if err := os.WriteFile(r.file, []byte("{broken"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := OpenWithProvider(filepath.Dir(r.file), p, base); !errors.Is(err, ErrInvalid) {
		t.Fatalf("corrupt registry must refuse: %v", err)
	}
}

func TestAbandonedTemporaryFileDoesNotBlockRegistryChanges(t *testing.T) {
	r, _, base := setup(t)
	stale := r.file + ".tmp"
	if err := os.WriteFile(stale, []byte("interrupted write"), 0600); err != nil {
		t.Fatal(err)
	}
	item, err := r.Add(context.Background(), "disk", dir(t, base, "disk"))
	if err != nil {
		t.Fatalf("abandoned writer blocked registration: %v", err)
	}
	if err := r.Remove(item.ID); err != nil {
		t.Fatal(err)
	}
	if bytes, err := os.ReadFile(stale); err != nil || string(bytes) != "interrupted write" {
		t.Fatal("unrelated abandoned file was modified")
	}
}

func TestDirectorySyncFailureRefusesAccessUntilReload(t *testing.T) {
	r, p, base := setup(t)
	item, err := r.Add(context.Background(), "disk", dir(t, base, "disk"))
	if err != nil {
		t.Fatal(err)
	}
	lease, err := r.Acquire(context.Background(), item.ID)
	if err != nil {
		t.Fatal(err)
	}
	r.syncDirectory = func(*os.File) error { return errors.New("simulated directory sync failure") }
	secondLocation := dir(t, base, "second")
	if _, err := r.Add(context.Background(), "second", secondLocation); !errors.Is(err, ErrPersistence) {
		t.Fatalf("uncertain publication not reported: %v", err)
	}
	if lease.Valid(context.Background()) {
		t.Fatal("existing lease stayed valid after uncertain publication")
	}
	lease.Close()
	if _, err := r.Acquire(context.Background(), item.ID); !errors.Is(err, ErrPersistence) {
		t.Fatalf("root remained available: %v", err)
	}
	if err := r.Remove(item.ID); !errors.Is(err, ErrPersistence) {
		t.Fatalf("mutation after uncertain publication: %v", err)
	}
	reloaded, err := OpenWithProvider(filepath.Dir(r.file), p, base)
	if err != nil {
		t.Fatal(err)
	}
	if len(reloaded.List()) != 2 {
		t.Fatal("reload did not resolve to the actually published state")
	}
}

type switchingProvider struct {
	*provider
	beforeVerify func(int)
	afterVerify  func(int)
	calls        int
}

func (p *switchingProvider) Verify(ctx context.Context, b storageidentity.Binding) error {
	p.calls++
	if p.beforeVerify != nil {
		p.beforeVerify(p.calls)
	}
	err := p.provider.Verify(ctx, b)
	if p.afterVerify != nil {
		p.afterVerify(p.calls)
	}
	return err
}

func TestAcquireRejectsReplacementDescriptorAfterPathRestored(t *testing.T) {
	r, p, base := setup(t)
	location := dir(t, base, "disk")
	replacement := dir(t, base, "replacement")
	item, err := r.Add(context.Background(), "disk", location)
	if err != nil {
		t.Fatal(err)
	}
	old := location + "-original"
	move := func(from, to string) {
		t.Helper()
		if err := os.Rename(from, to); err != nil {
			t.Fatal(err)
		}
	}
	swapping := &switchingProvider{provider: p}
	swapping.afterVerify = func(call int) {
		if call == 1 {
			move(location, old)
			move(replacement, location)
		}
	}
	swapping.beforeVerify = func(call int) {
		if call == 2 {
			move(location, replacement)
			move(old, location)
		}
	}
	r.provider = swapping
	if lease, err := r.Acquire(context.Background(), item.ID); !errors.Is(err, ErrOffline) {
		if lease != nil {
			lease.Close()
		}
		t.Fatalf("replacement descriptor accepted after path restored: %v", err)
	}
	r.provider = p
	if _, err := r.Rebind(context.Background(), item.ID, location); err != nil {
		t.Fatalf("failed acquisition leaked its lease: %v", err)
	}
}

func TestSharedRootCannotExposePrivateMetadataOrAncestor(t *testing.T) {
	r, _, _ := setup(t)
	data := filepath.Dir(r.file)
	data, _ = filepath.EvalSymlinks(data)
	parent := filepath.Dir(data)
	r.allowed = append(r.allowed, parent, data)
	cache := dir(t, data, "cache")
	for _, target := range []string{parent, data, cache} {
		if _, err := r.Add(context.Background(), "private", target); !errors.Is(err, ErrNotAllowed) {
			t.Fatalf("private metadata overlap accepted: %s %v", target, err)
		}
	}
	defaultShare := dir(t, data, "SharedFiles")
	if _, err := r.Add(context.Background(), "default", defaultShare); err != nil {
		t.Fatalf("safe default share rejected: %v", err)
	}
}
func TestRegistryRejectCorruptOverlappingAndEmptyConfig(t *testing.T) {
	r, p, base := setup(t)
	if err := os.WriteFile(r.file, []byte("{}"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := OpenWithProvider(filepath.Dir(r.file), p, base); !errors.Is(err, ErrInvalid) {
		t.Fatalf("wrong version %v", err)
	}
	for _, bad := range []string{strings.Repeat("x", 128*1024+1), "{\"version\":1,\"roots\":[{\"rootID\":\"fake\"}]}"} {
		if err := os.WriteFile(r.file, []byte(bad), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := OpenWithProvider(filepath.Dir(r.file), p, base); !errors.Is(err, ErrInvalid) {
			t.Fatalf("accepted malformed registry %v", err)
		}
	}
	if err := os.Remove(r.file); err != nil {
		t.Fatal(err)
	}
	a := dir(t, base, "ok")
	if _, err := r.Add(context.Background(), "Valid", a); err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(r.file)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(content, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded["version"] != float64(1) {
		t.Fatal("registry version")
	}
}
