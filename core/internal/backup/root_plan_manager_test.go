//go:build darwin

package backup

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
)

type rootPlanTestFixture struct {
	base        string
	private     string
	source      string
	destination string
	registry    *roots.Registry
	root        roots.Root
	volume      *atomic.Value
	provider    *rootPlanTestProvider
	reader      func(string) (diskutilVolumeInfo, error)
}

type rootPlanTestProvider struct {
	registry *roots.Registry
	dataDir  string
	reader   func(string) (diskutilVolumeInfo, error)
	calls    atomic.Int32
	closed   atomic.Int32
	last     atomic.Pointer[Service]
}

func newRootPlanTestFixture(t *testing.T) *rootPlanTestFixture {
	t.Helper()
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	base, err := os.MkdirTemp(home, ".lightisle-root-plan-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(base) })
	private := filepath.Join(base, "private")
	source := filepath.Join(base, "share")
	destination := filepath.Join(base, "backups")
	for _, dir := range []string{private, source, destination} {
		if err := os.Mkdir(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(source, "important.txt"), []byte("root plan"), 0600); err != nil {
		t.Fatal(err)
	}
	registry, err := roots.OpenWithProvider(private, backupTestIdentityProvider{}, home)
	if err != nil {
		t.Fatal(err)
	}
	root, err := registry.Add(context.Background(), "Share", source)
	if err != nil {
		t.Fatal(err)
	}
	volume := &atomic.Value{}
	volume.Store("12345678-1234-1234-1234-123456789ABC")
	reader := func(path string) (diskutilVolumeInfo, error) {
		return diskutilVolumeInfo{UUID: volume.Load().(string), MountPoint: "/"}, nil
	}
	provider := &rootPlanTestProvider{registry: registry, dataDir: private, reader: reader}
	return &rootPlanTestFixture{base: base, private: private, source: source, destination: destination,
		registry: registry, root: root, volume: volume, provider: provider, reader: reader}
}

func (p *rootPlanTestProvider) acquire(ctx context.Context, id string, generation uint64) (*RootBackupLease, error) {
	p.calls.Add(1)
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	var root *roots.Root
	for _, item := range p.registry.List() {
		if item.ID == id {
			copy := item
			root = &copy
			break
		}
	}
	if root == nil {
		return nil, roots.ErrMissing
	}
	if root.Generation != generation {
		return nil, roots.ErrStale
	}
	rootLease, err := p.registry.Acquire(ctx, id)
	if err != nil {
		return nil, err
	}
	manager, err := files.NewPinnedManager(rootLease.Root, root.Binding)
	if err != nil {
		_ = rootLease.Close()
		return nil, err
	}
	service, err := NewForRoot(manager, p.dataDir, *root, p.registry)
	if err != nil {
		_ = manager.Close()
		_ = rootLease.Close()
		return nil, err
	}
	service.readVolumeInfo = p.reader
	p.last.Store(service)
	return &RootBackupLease{Root: *root, Service: service, Close: func() error {
		p.closed.Add(1)
		service.Close()
		return errors.Join(manager.Close(), rootLease.Close())
	}}, nil
}

func (f *rootPlanTestFixture) newManager(t *testing.T) *RootPlanManager {
	t.Helper()
	manager, err := NewRootPlanManager(f.private, f.registry, f.provider.acquire)
	if err != nil {
		t.Fatal(err)
	}
	manager.readVolumeInfo = f.reader
	f.setReader(manager)
	t.Cleanup(func() { _ = manager.Close() })
	return manager
}

func (f *rootPlanTestFixture) setReader(manager *RootPlanManager) {
	manager.mu.Lock()
	defer manager.mu.Unlock()
	for _, scheduler := range manager.plans {
		scheduler.readVolumeInfo = f.reader
	}
}

func (f *rootPlanTestFixture) configure(t *testing.T, manager *RootPlanManager) Schedule {
	t.Helper()
	if err := manager.Configure(context.Background(), f.root.ID, f.root.Generation, f.destination, 24, 2); err != nil {
		t.Fatal(err)
	}
	schedule, err := manager.Status(f.root.ID, f.root.Generation)
	if err != nil {
		t.Fatal(err)
	}
	return schedule
}

func forceRootPlanDue(t *testing.T, manager *RootPlanManager, id string) *Scheduler {
	t.Helper()
	manager.mu.RLock()
	scheduler := manager.plans[id]
	manager.mu.RUnlock()
	if scheduler == nil {
		t.Fatal("root plan scheduler missing")
	}
	scheduler.mu.Lock()
	scheduler.config.NextRun = time.Now().Add(-time.Second).Unix()
	if _, err := scheduler.writeLocked(); err != nil {
		scheduler.mu.Unlock()
		t.Fatal(err)
	}
	scheduler.mu.Unlock()
	scheduler.runDue(time.Now())
	return scheduler
}

func waitForRootPlan(t *testing.T, predicate func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if predicate() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("root plan condition did not complete")
}

func TestRootPlanManagerLoadsOfflineRootAndRetriesAfterReconnect(t *testing.T) {
	fixture := newRootPlanTestFixture(t)
	manager := fixture.newManager(t)
	initial, err := manager.Status(fixture.root.ID, fixture.root.Generation)
	if err != nil || initial.Enabled || initial.RootID != fixture.root.ID || initial.RootGeneration != fixture.root.Generation {
		t.Fatalf("root without a plan should have a bound disabled status: %+v %v", initial, err)
	}
	configured := fixture.configure(t, manager)
	if configured.PlanID == "" || !configured.Enabled || configured.RetentionCount != 2 {
		t.Fatalf("plan was not configured: %+v", configured)
	}
	if err := manager.Close(); err != nil {
		t.Fatal(err)
	}

	offline := filepath.Join(fixture.base, "offline-share")
	if err := os.Rename(fixture.source, offline); err != nil {
		t.Fatal(err)
	}
	reopened := fixture.newManager(t)
	callsBeforeLoad := fixture.provider.calls.Load()
	loaded, err := reopened.Status(fixture.root.ID, fixture.root.Generation)
	if err != nil || !loaded.Enabled || loaded.PlanID != configured.PlanID || fixture.provider.calls.Load() != callsBeforeLoad {
		t.Fatalf("startup touched an offline source or lost its plan: %+v calls=%d/%d err=%v", loaded, callsBeforeLoad, fixture.provider.calls.Load(), err)
	}

	failed := forceRootPlanDue(t, reopened, fixture.root.ID).Status()
	if failed.LastError == "" || failed.LastAttempt == 0 || failed.NextRun <= failed.LastAttempt {
		t.Fatalf("offline dispatch failure was not visible and scheduled for retry: %+v", failed)
	}
	if err := os.Rename(offline, fixture.source); err != nil {
		t.Fatal(err)
	}
	forceRootPlanDue(t, reopened, fixture.root.ID)
	waitForRootPlan(t, func() bool {
		service := fixture.provider.last.Load()
		return service != nil && !service.Status().Running && service.Status().LastSnapshot != ""
	})
	waitForRootPlan(t, func() bool { return fixture.provider.closed.Load() >= 2 })
	completed := fixture.provider.last.Load().Status()
	if completed.LastError != "" || completed.LastSnapshot == "" {
		t.Fatalf("reconnected root backup failed: %+v", completed)
	}
	manifest := readSnapshotManifest(t, completed.LastSnapshot)
	if manifest.PlanID != configured.PlanID || manifest.LogicalRootID != fixture.root.ID ||
		manifest.RootGeneration != fixture.root.Generation || !validSourceRootID(manifest.SourceRootID) {
		t.Fatalf("scheduled snapshot lost root/plan identity: %+v", manifest)
	}
	if err := reopened.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestRootPlanManagerDisableOfflinePersistsAcrossRestart(t *testing.T) {
	fixture := newRootPlanTestFixture(t)
	manager := fixture.newManager(t)
	fixture.configure(t, manager)
	if err := manager.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(fixture.source, filepath.Join(fixture.base, "offline-share")); err != nil {
		t.Fatal(err)
	}
	reopened := fixture.newManager(t)
	calls := fixture.provider.calls.Load()
	if err := reopened.Disable(fixture.root.ID, fixture.root.Generation); err != nil {
		t.Fatal(err)
	}
	if fixture.provider.calls.Load() != calls {
		t.Fatal("offline disable unexpectedly acquired root services")
	}
	if err := reopened.Close(); err != nil {
		t.Fatal(err)
	}
	restarted := fixture.newManager(t)
	status, err := restarted.Status(fixture.root.ID, fixture.root.Generation)
	if err != nil || status.Enabled || status.RootID != fixture.root.ID || status.RootGeneration != fixture.root.Generation {
		t.Fatalf("offline disable was not persisted: %+v %v", status, err)
	}
	if fixture.provider.calls.Load() != calls {
		t.Fatal("status or restart unexpectedly acquired root services")
	}
	if err := restarted.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(filepath.Join(fixture.base, "offline-share"), fixture.source); err != nil {
		t.Fatal(err)
	}
}

func TestRootPlanManagerRejectsDestinationVolumeAndDirectoryReplacement(t *testing.T) {
	fixture := newRootPlanTestFixture(t)
	manager := fixture.newManager(t)
	fixture.configure(t, manager)
	fixture.volume.Store("AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")
	volumeFailure := forceRootPlanDue(t, manager, fixture.root.ID).Status()
	if volumeFailure.LastError != ErrDestinationVolumeMismatch.Error() {
		t.Fatalf("same path on a replacement volume was accepted: %+v", volumeFailure)
	}
	fixture.volume.Store("12345678-1234-1234-1234-123456789ABC")
	if err := os.RemoveAll(fixture.destination); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(fixture.destination, 0700); err != nil {
		t.Fatal(err)
	}
	directoryFailure := forceRootPlanDue(t, manager, fixture.root.ID).Status()
	if directoryFailure.LastError != ErrDestinationFolderChanged.Error() {
		t.Fatalf("same path with a replacement directory was accepted: %+v", directoryFailure)
	}
	if err := manager.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestRootPlanManagerGenerationChangeDoesNotInheritAndArchives(t *testing.T) {
	fixture := newRootPlanTestFixture(t)
	manager := fixture.newManager(t)
	configured := fixture.configure(t, manager)
	if err := manager.Close(); err != nil {
		t.Fatal(err)
	}
	newRoot, err := fixture.registry.Rebind(context.Background(), fixture.root.ID, fixture.source, fixture.root.Binding)
	if err != nil {
		t.Fatal(err)
	}
	restarted := fixture.newManager(t)
	status, err := restarted.Status(newRoot.ID, newRoot.Generation)
	if err != nil || status.Enabled || status.RootID != newRoot.ID || status.RootGeneration != newRoot.Generation ||
		status.PlanID != "" || status.Destination != "" || status.RetentionCount != 0 {
		t.Fatalf("new generation inherited an old plan: %+v %v", status, err)
	}
	entries, err := os.ReadDir(filepath.Join(fixture.private, rootPlanDirectoryName, rootPlanArchiveName))
	if err != nil || len(entries) != 1 {
		t.Fatalf("old generation plan was not archived: entries=%v err=%v", entries, err)
	}
	raw, err := os.ReadFile(filepath.Join(fixture.private, rootPlanDirectoryName, rootPlanArchiveName, entries[0].Name()))
	if err != nil {
		t.Fatal(err)
	}
	var archived Schedule
	if err := json.Unmarshal(raw, &archived); err != nil {
		t.Fatal(err)
	}
	if archived.RootGeneration != fixture.root.Generation || archived.Enabled || archived.PlanID != configured.PlanID ||
		archived.LastError != ErrRootChanged.Error() {
		t.Fatalf("archived schedule does not record deactivation: %+v", archived)
	}
	if err := restarted.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestRootPlanManagerIsolatesCorruptPlanAndOwnerReconfigurationRecovers(t *testing.T) {
	fixture := newRootPlanTestFixture(t)
	otherPath := filepath.Join(fixture.base, "other-share")
	if err := os.Mkdir(otherPath, 0700); err != nil {
		t.Fatal(err)
	}
	otherRoot, err := fixture.registry.Add(context.Background(), "Other", otherPath)
	if err != nil {
		t.Fatal(err)
	}
	planDir := filepath.Join(fixture.private, rootPlanDirectoryName)
	if err := os.Mkdir(planDir, 0700); err != nil {
		t.Fatal(err)
	}
	corruptPath := filepath.Join(planDir, planFileName(fixture.root.ID, fixture.root.Generation))
	if err := os.WriteFile(corruptPath, []byte("not-json"), 0644); err != nil {
		t.Fatal(err)
	}
	manager := fixture.newManager(t)
	corrupt, err := manager.Status(fixture.root.ID, fixture.root.Generation)
	if err != nil || corrupt.Enabled || corrupt.LastError != ErrRootPlanConfigInvalid.Error() || corrupt.LastErrorDetail == "" {
		t.Fatalf("bad plan did not produce a disabled, recoverable status: %+v %v", corrupt, err)
	}
	other, err := manager.Status(otherRoot.ID, otherRoot.Generation)
	if err != nil || other.Enabled || other.LastError != "" {
		t.Fatalf("one root's bad plan blocked another root: %+v %v", other, err)
	}
	if err := manager.Configure(context.Background(), fixture.root.ID, fixture.root.Generation, fixture.destination, 24, 1); err != nil {
		t.Fatalf("owner reconfiguration did not recover a private corrupt file: %v", err)
	}
	recovered, err := manager.Status(fixture.root.ID, fixture.root.Generation)
	if err != nil || !recovered.Enabled || recovered.LastError != "" || recovered.PlanID == "" {
		t.Fatalf("reconfigured plan did not recover: %+v %v", recovered, err)
	}
	entries, err := os.ReadDir(filepath.Join(planDir, rootPlanArchiveName))
	if err != nil || len(entries) != 1 {
		t.Fatalf("corrupt file was not preserved in the private archive: entries=%v err=%v", entries, err)
	}
	archived, err := os.ReadFile(filepath.Join(planDir, rootPlanArchiveName, entries[0].Name()))
	if err != nil || string(archived) != "not-json" {
		t.Fatalf("corrupt file contents were not preserved: %q %v", archived, err)
	}
	other, err = manager.Status(otherRoot.ID, otherRoot.Generation)
	if err != nil || other.LastError != "" {
		t.Fatalf("recovery still affected the other root: %+v %v", other, err)
	}
	if err := manager.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestRootPlanManagerDoesNotFollowOrOverwriteSymlinkPlan(t *testing.T) {
	fixture := newRootPlanTestFixture(t)
	otherPath := filepath.Join(fixture.base, "other-share")
	if err := os.Mkdir(otherPath, 0700); err != nil {
		t.Fatal(err)
	}
	otherRoot, err := fixture.registry.Add(context.Background(), "Other", otherPath)
	if err != nil {
		t.Fatal(err)
	}
	planDir := filepath.Join(fixture.private, rootPlanDirectoryName)
	if err := os.Mkdir(planDir, 0700); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(fixture.base, "outside-plan.json")
	secret := []byte(`{"enabled":true,"destination":"do-not-follow"}`)
	if err := os.WriteFile(target, secret, 0600); err != nil {
		t.Fatal(err)
	}
	symlink := filepath.Join(planDir, planFileName(fixture.root.ID, fixture.root.Generation))
	if err := os.Symlink(target, symlink); err != nil {
		t.Fatal(err)
	}
	manager := fixture.newManager(t)
	status, err := manager.Status(fixture.root.ID, fixture.root.Generation)
	if err != nil || status.Enabled || status.LastError != ErrRootPlanConfigUnsafe.Error() || status.LastErrorDetail == "" {
		t.Fatalf("symlink plan was not isolated as unsafe: %+v %v", status, err)
	}
	if err := manager.Configure(context.Background(), fixture.root.ID, fixture.root.Generation, fixture.destination, 24, 1); !errors.Is(err, ErrRootPlanConfigUnsafe) {
		t.Fatalf("owner configuration followed/replaced a symlink plan: %v", err)
	}
	linkInfo, err := os.Lstat(symlink)
	if err != nil || linkInfo.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("symlink plan was changed: info=%v err=%v", linkInfo, err)
	}
	got, err := os.ReadFile(target)
	if err != nil || string(got) != string(secret) {
		t.Fatalf("symlink target was followed or overwritten: %q %v", got, err)
	}
	other, err := manager.Status(otherRoot.ID, otherRoot.Generation)
	if err != nil || other.LastError != "" {
		t.Fatalf("symlink plan blocked another root: %+v %v", other, err)
	}
	if err := manager.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestRootPlanArchiveIsBounded(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "archive")
	if err := os.Mkdir(directory, 0700); err != nil {
		t.Fatal(err)
	}
	for index := 0; index < rootPlanArchiveLimit+8; index++ {
		name := filepath.Join(directory, strconv.Itoa(index)+".json")
		if err := os.WriteFile(name, []byte("{}"), 0600); err != nil {
			t.Fatal(err)
		}
		time.Sleep(time.Millisecond)
	}
	if err := trimRootPlanArchive(directory); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(directory)
	if err != nil || len(entries) != rootPlanArchiveLimit {
		t.Fatalf("archive was not trimmed to its bound: count=%d err=%v", len(entries), err)
	}
}

func TestRootPlanSchedulerCloseCancelsJobBeforeReleasingLease(t *testing.T) {
	planCtx, cancelPlan := context.WithCancel(context.Background())
	service := New(nil)
	jobCanceled := make(chan struct{})
	released := make(chan struct{})
	completion, err := service.startWithCompletion("backup", "unused", func(ctx context.Context, _ string) (string, error) {
		jobCtx, cancelJobCtx := context.WithCancel(ctx)
		stopPlanAfterFunc := context.AfterFunc(planCtx, cancelJobCtx)
		defer func() {
			stopPlanAfterFunc()
			cancelJobCtx()
		}()
		<-jobCtx.Done()
		close(jobCanceled)
		return "", jobCtx.Err()
	})
	if err != nil {
		t.Fatal(err)
	}
	scheduler := &Scheduler{
		rootPlan: true, ctx: planCtx, cancel: cancelPlan,
		path:       filepath.Join(t.TempDir(), "plan.json"),
		rootRecord: roots.Root{ID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", Generation: 1},
		config:     Schedule{RootID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", RootGeneration: 1},
	}
	scheduler.trackScheduledJob(completion, func() error {
		close(released)
		return nil
	})
	if err := scheduler.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-jobCanceled:
	default:
		t.Fatal("Close returned without cancelling the active backup")
	}
	select {
	case <-released:
	default:
		t.Fatal("Close returned before releasing the root provider lease")
	}
	service.Close()
}
