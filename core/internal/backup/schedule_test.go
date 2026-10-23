package backup

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
)

func TestScheduledBackupPersistsAndStops(t *testing.T) {
	work := t.TempDir()
	manager, err := files.NewManager(work)
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	source := filepath.Join(work, "SharedFiles")
	if err := os.WriteFile(filepath.Join(source, "important.txt"), []byte("schedule test"), 0600); err != nil {
		t.Fatal(err)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	destination, err := os.MkdirTemp(home, "lightisle-schedule-test-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(destination)
	service := New(manager, work)
	defer service.Close()
	scheduler, err := NewScheduler(service, work)
	if err != nil {
		t.Fatal(err)
	}
	if err := scheduler.Configure(source, 24); err == nil {
		t.Fatal("scheduled backup into source accepted")
	}
	if err := scheduler.Configure(destination, 12); err == nil {
		t.Fatal("unsupported hourly schedule accepted")
	}
	if err := scheduler.Configure(destination, 24); err != nil {
		t.Fatal(err)
	}
	state := scheduler.Status()
	if !state.Enabled || state.EveryHours != 24 || state.NextRun <= time.Now().Unix() {
		t.Fatalf("wrong scheduled time: %+v", state)
	}
	scheduler.runDue(time.Unix(state.NextRun+1, 0))
	done := await(t, service)
	if done.LastError != "" || done.LastSnapshot == "" {
		t.Fatalf("scheduled backup failed: %+v", done)
	}
	if scheduler.Status().LastAttempt == 0 {
		t.Fatal("scheduled run not persisted")
	}
	rawSchedule, err := os.ReadFile(filepath.Join(done.LastSnapshot, "metadata", "backup-schedule.json"))
	if err != nil {
		t.Fatal(err)
	}
	var archived Schedule
	if err := json.Unmarshal(rawSchedule, &archived); err != nil || archived != scheduler.Status() {
		t.Fatalf("backup archived stale schedule: %+v %v", archived, err)
	}
	scheduler.Close()
	reopened, err := NewScheduler(service, work)
	if err != nil {
		t.Fatal(err)
	}
	if !reopened.Status().Enabled || reopened.Status().LastAttempt == 0 {
		t.Fatal("schedule not persisted")
	}
	if err := reopened.Disable(); err != nil {
		t.Fatal(err)
	}
	if reopened.Status().Enabled {
		t.Fatal("disable failed")
	}
	reopened.Close()
}

func TestScheduledBackupMissingDestinationPersistsFailureAndRecovers(t *testing.T) {
	work := t.TempDir()
	manager, err := files.NewManager(work)
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	destination, err := os.MkdirTemp(home, "lightisle-schedule-failure-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(destination)
	service := New(manager)
	defer service.Close()
	scheduler, err := NewScheduler(service, work)
	if err != nil {
		t.Fatal(err)
	}
	defer scheduler.Close()
	if err := scheduler.Configure(destination, 24); err != nil {
		t.Fatal(err)
	}
	due := time.Unix(scheduler.Status().NextRun+1, 0)
	if err := os.Remove(destination); err != nil {
		t.Fatal(err)
	}
	scheduler.runDue(due)
	failed := scheduler.Status()
	if failed.LastError != ErrDestinationVolumeUnavailable.Error() || failed.LastAttempt != due.Unix() || failed.NextRun <= due.Unix() {
		t.Fatalf("failed dispatch was not recorded: %+v", failed)
	}
	if service.Status().Running {
		t.Fatal("missing destination dispatched backup")
	}
	scheduler.runDue(due.Add(time.Minute))
	if scheduler.Status() != failed {
		t.Fatal("failed schedule retried before next cycle")
	}
	scheduler.Close()
	reopened, err := NewScheduler(service, work)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	if reopened.Status() != failed {
		t.Fatalf("failed dispatch lost on restart: %+v", reopened.Status())
	}
	if err := os.Mkdir(destination, 0700); err != nil {
		t.Fatal(err)
	}
	reopened.runDue(time.Unix(failed.NextRun+1, 0))
	changed := reopened.Status()
	if changed.LastError != ErrDestinationFolderChanged.Error() || service.Status().Running || service.Status().LastSnapshot != "" {
		t.Fatalf("replaced destination directory was not held for reconfirmation: %+v", changed)
	}
	if err := reopened.ConfigureWithRetention(destination, 24, 0); err != nil {
		t.Fatalf("reconfirm replacement destination: %v", err)
	}
	stateBeforeRetry := reopened.Status()
	retryAt := failed.LastAttempt + 1
	if retryAt <= stateBeforeRetry.NextRun {
		retryAt = stateBeforeRetry.NextRun + 1
	}
	reopened.runDue(time.Unix(retryAt, 0))
	if done := await(t, service); done.LastError != "" || done.LastSnapshot == "" {
		t.Fatalf("explicitly reconfirmed schedule did not recover: %+v", done)
	}
	if got := reopened.Status(); got.LastError != "" || got.LastAttempt <= failed.LastAttempt {
		t.Fatalf("successful dispatch did not clear failure: %+v", got)
	}
}

func TestLegacyScheduleRequiresExplicitDestinationReconfirmation(t *testing.T) {
	work := t.TempDir()
	manager, err := files.NewManager(work)
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	service := New(manager)
	defer service.Close()
	legacy := Schedule{Enabled: true, EveryHours: 24, Destination: filepath.Join(work, "old-destination"), NextRun: time.Now().Add(-time.Hour).Unix()}
	raw, err := json.Marshal(legacy)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(work, "backup-schedule.json"), raw, 0600); err != nil {
		t.Fatal(err)
	}
	scheduler, err := NewScheduler(service, work)
	if err != nil {
		t.Fatal(err)
	}
	defer scheduler.Close()
	state := scheduler.Status()
	if !state.Enabled || state.DestinationIdentityStatus != destinationIdentityConfirmationRequired ||
		state.LastError != ErrDestinationConfirmationRequired.Error() || state.NextRun != 0 {
		t.Fatalf("legacy schedule did not request reconfirmation: %+v", state)
	}
	persistedRaw, err := os.ReadFile(filepath.Join(work, "backup-schedule.json"))
	if err != nil {
		t.Fatal(err)
	}
	var persisted Schedule
	if err := json.Unmarshal(persistedRaw, &persisted); err != nil || persisted != state {
		t.Fatalf("legacy confirmation requirement was not persisted: %+v %v", persisted, err)
	}
	scheduler.readVolumeInfo = testVolumeInfo
	scheduler.runDue(time.Now().Add(24 * time.Hour))
	if state := scheduler.Status(); state.DestinationIdentityStatus != destinationIdentityConfirmationRequired ||
		state.LastError != ErrDestinationConfirmationRequired.Error() || service.Status().Running {
		t.Fatalf("legacy schedule was silently rebound or dispatched: %+v", state)
	}
}

func TestScheduledBackupRejectsSamePathOnDifferentVolume(t *testing.T) {
	work := t.TempDir()
	manager, err := files.NewManager(work)
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	service := New(manager)
	defer service.Close()
	destination := temporaryHomeDirectory(t)
	volumeUUID := "11111111-2222-3333-4444-555555555555"
	scheduler := newInjectedScheduler(service, filepath.Join(work, "schedule.json"), func(string) (diskutilVolumeInfo, error) {
		return diskutilVolumeInfo{UUID: volumeUUID, MountPoint: "/"}, nil
	})
	defer scheduler.Close()
	if err := scheduler.ConfigureWithRetention(destination, 24, 0); err != nil {
		t.Fatal(err)
	}
	volumeUUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	scheduler.runDue(time.Unix(scheduler.Status().NextRun+1, 0))
	state := scheduler.Status()
	if state.LastError != ErrDestinationVolumeMismatch.Error() || service.Status().Running || service.Status().LastSnapshot != "" {
		t.Fatalf("same path on a different volume was accepted: %+v", state)
	}
}

func TestScheduledBackupRejectsReplacedDestinationDirectory(t *testing.T) {
	work := t.TempDir()
	manager, err := files.NewManager(work)
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	service := New(manager)
	defer service.Close()
	destination := temporaryHomeDirectory(t)
	scheduler := newInjectedScheduler(service, filepath.Join(work, "schedule.json"), testVolumeInfo)
	defer scheduler.Close()
	if err := scheduler.ConfigureWithRetention(destination, 24, 0); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(destination); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(destination, 0700); err != nil {
		t.Fatal(err)
	}
	scheduler.runDue(time.Unix(scheduler.Status().NextRun+1, 0))
	state := scheduler.Status()
	if state.LastError != ErrDestinationFolderChanged.Error() || service.Status().Running || service.Status().LastSnapshot != "" {
		t.Fatalf("replacement directory at same path was accepted: %+v", state)
	}
}

func TestParseDiskutilVolumeInfo(t *testing.T) {
	data := []byte(`<?xml version="1.0"?><plist><dict><key>Nested</key><array><dict><key>VolumeUUID</key><string>ffffffff-ffff-ffff-ffff-ffffffffffff</string></dict></array><key>VolumeUUID</key><string>12345678-abcd-1234-abcd-1234567890ab</string><key>MountPoint</key><string>/Volumes/Backup</string></dict></plist>`)
	info, err := parseDiskutilVolumeInfo(data)
	if err != nil || info.UUID != "12345678-abcd-1234-abcd-1234567890ab" || info.MountPoint != "/Volumes/Backup" {
		t.Fatalf("parsed diskutil plist = %+v, %v", info, err)
	}
	if _, err := parseDiskutilVolumeInfo([]byte(`<plist><dict><key>DeviceIdentifier</key><string>disk4s1</string><key>MountPoint</key><string>/Volumes/Backup</string></dict></plist>`)); err == nil {
		t.Fatal("diskutil plist without VolumeUUID accepted")
	}
}

func TestDirectoryIdentityRequiresFilesystemGenerationEvidence(t *testing.T) {
	if validDirectoryIdentity(directoryIdentity{ID: "0000000000000001"}) {
		t.Fatal("inode-only directory identity accepted without birthtime or generation")
	}
	for _, identity := range []directoryIdentity{
		{ID: "0000000000000001", BirthSec: 1},
		{ID: "0000000000000001", BirthNsec: 1},
		{ID: "0000000000000001", Generation: 1},
	} {
		if !validDirectoryIdentity(identity) {
			t.Fatalf("filesystem-backed directory identity rejected: %+v", identity)
		}
	}
	if validDirectoryIdentity(directoryIdentity{ID: "not-an-inode", BirthSec: 1}) {
		t.Fatal("malformed inode identity accepted")
	}
}

func TestReadDiskutilVolumeInfoOnCurrentMac(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("diskutil is available only on macOS")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	info, err := readDiskutilVolumeInfo(home)
	if err != nil || !validUUID(info.UUID) || !filepath.IsAbs(info.MountPoint) {
		t.Fatalf("read current system volume identity: %+v, %v", info, err)
	}
	identity, err := captureDestinationIdentity(home, nil)
	if err != nil || !validUUID(identity.VolumeUUID) || !validDirectoryIdentity(identity.directoryIdentity) {
		t.Fatalf("capture full identity for current home firmlink: %+v, %v", identity, err)
	}
}

func testVolumeInfo(string) (diskutilVolumeInfo, error) {
	return diskutilVolumeInfo{UUID: "11111111-2222-3333-4444-555555555555", MountPoint: "/"}, nil
}

func newInjectedScheduler(service *Service, path string, reader func(string) (diskutilVolumeInfo, error)) *Scheduler {
	ctx, cancel := context.WithCancel(context.Background())
	scheduler := &Scheduler{service: service, ctx: ctx, cancel: cancel, path: path, readVolumeInfo: reader}
	return scheduler
}

func temporaryHomeDirectory(t *testing.T) string {
	t.Helper()
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	destination, err := os.MkdirTemp(home, "lightisle-schedule-identity-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(destination) })
	return destination
}

func TestScheduledBackupRejectsRedirectedDestination(t *testing.T) {
	work := t.TempDir()
	manager, err := files.NewManager(work)
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	base, err := os.MkdirTemp(home, "lightisle-schedule-redirect-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(base)
	destination := filepath.Join(base, "selected")
	other := filepath.Join(base, "other")
	for _, folder := range []string{destination, other} {
		if err := os.Mkdir(folder, 0700); err != nil {
			t.Fatal(err)
		}
	}
	service := New(manager)
	defer service.Close()
	scheduler, err := NewScheduler(service, work)
	if err != nil {
		t.Fatal(err)
	}
	defer scheduler.Close()
	if err := scheduler.Configure(destination, 24); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(destination); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(other, destination); err != nil {
		t.Fatal(err)
	}
	scheduler.runDue(time.Unix(scheduler.Status().NextRun+1, 0))
	if got := scheduler.Status(); got.LastError != ErrInvalid.Error() || got.LastAttempt == 0 {
		t.Fatalf("redirected destination not rejected: %+v", got)
	}
	entries, err := os.ReadDir(other)
	if err != nil || len(entries) != 0 {
		t.Fatalf("backup written to redirected destination: %v %v", entries, err)
	}
}

func TestSchedulePersistenceFailureKeepsMemoryAtRenameCommit(t *testing.T) {
	work := t.TempDir()
	manager, err := files.NewManager(work)
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	service := New(manager)
	defer service.Close()
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	destination, err := os.MkdirTemp(home, "lightisle-schedule-commit-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(destination)
	// This scheduler has no ticker, so fault injection cannot overlap a worker.
	scheduler := &Scheduler{service: service, ctx: context.Background(), path: filepath.Join(work, "backup-schedule.json")}
	if err := scheduler.Configure(destination, 24); err != nil {
		t.Fatal(err)
	}
	syncFailure := errors.New("injected_directory_sync_failure")
	scheduler.syncParentDir = func(string) error { return syncFailure }
	if err := scheduler.Configure(destination, 168); !errors.Is(err, syncFailure) {
		t.Fatalf("missing post-rename durability warning: %v", err)
	}
	assertDiskMatchesMemory := func() {
		t.Helper()
		raw, err := os.ReadFile(scheduler.path)
		if err != nil {
			t.Fatal(err)
		}
		var persisted Schedule
		if err := json.Unmarshal(raw, &persisted); err != nil || persisted != scheduler.Status() {
			t.Fatalf("memory diverged from replaced configuration: %+v %+v %v", scheduler.Status(), persisted, err)
		}
	}
	assertDiskMatchesMemory()
	if scheduler.Status().EveryHours != 168 {
		t.Fatal("configure restored old in-memory state after successful rename")
	}
	if err := scheduler.Disable(); !errors.Is(err, syncFailure) {
		t.Fatalf("missing disable durability warning: %v", err)
	}
	assertDiskMatchesMemory()
	if scheduler.Status().Enabled {
		t.Fatal("disable kept running a configuration already disabled on disk")
	}
	// A failed rename never commits, so the previous in-memory state remains.
	scheduler.path = filepath.Join(work, "directory-not-file")
	if err := os.Mkdir(scheduler.path, 0700); err != nil {
		t.Fatal(err)
	}
	if err := scheduler.Configure(destination, 24); err == nil || scheduler.Status().Enabled {
		t.Fatalf("uncommitted configure changed memory: %+v %v", scheduler.Status(), err)
	}
}
