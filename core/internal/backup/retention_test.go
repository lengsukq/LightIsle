package backup

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lengsukq/lightisle/core/internal/files"
)

const retentionTestUUID = "11111111-2222-4333-8444-555555555555"

func retentionTestReader(string) (diskutilVolumeInfo, error) {
	return diskutilVolumeInfo{UUID: retentionTestUUID, MountPoint: "/"}, nil
}

func newRetentionTestService(t *testing.T) (*Service, *files.Manager, string) {
	t.Helper()
	base := t.TempDir()
	share, err := files.NewManager(base)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = share.Close() })
	if err := os.WriteFile(filepath.Join(base, "SharedFiles", "source.txt"), []byte("first"), 0600); err != nil {
		t.Fatal(err)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	destination, err := os.MkdirTemp(home, "lightisle-retention-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(destination) })
	service := New(share)
	service.readVolumeInfo = retentionTestReader
	t.Cleanup(service.Close)
	return service, share, destination
}

func runRetentionBackup(t *testing.T, service *Service, destination, planID string, keep int) Status {
	t.Helper()
	if err := service.StartScheduledBackup(destination, planID, keep); err != nil {
		t.Fatal(err)
	}
	return await(t, service)
}

func readSnapshotManifest(t *testing.T, directory string) Manifest {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(directory, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var manifest Manifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatal(err)
	}
	return manifest
}

func rewriteSnapshotManifest(t *testing.T, directory string, update func(*Manifest)) {
	t.Helper()
	manifest := readSnapshotManifest(t, directory)
	update(&manifest)
	data, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "manifest.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
}

func TestScheduledRetentionDeletesOnlyExactPlanAndSourceRoot(t *testing.T) {
	service, _, destination := newRetentionTestService(t)

	if err := service.StartBackup(destination); err != nil {
		t.Fatal(err)
	}
	manual := await(t, service)
	if manual.LastError != "" || manual.LastSnapshot == "" {
		t.Fatalf("manual backup failed: %+v", manual)
	}

	otherPlan := runRetentionBackup(t, service, destination, "other-plan", 1)
	if otherPlan.LastError != "" || otherPlan.LastSnapshot == "" {
		t.Fatalf("other plan backup failed: %+v", otherPlan)
	}

	first := runRetentionBackup(t, service, destination, "retention-plan", 1)
	if first.LastError != "" || first.LastSnapshot == "" || first.RetentionError != "" {
		t.Fatalf("first plan backup failed: %+v", first)
	}
	firstPath := first.LastSnapshot
	if !validSourceRootID(readSnapshotManifest(t, firstPath).SourceRootID) {
		t.Fatal("scheduled snapshot has no stable source-root identity")
	}

	foreignRoot := runRetentionBackup(t, service, destination, "retention-plan", 0)
	if foreignRoot.LastError != "" || foreignRoot.LastSnapshot == "" {
		t.Fatalf("second plan backup failed: %+v", foreignRoot)
	}
	foreignRootPath := foreignRoot.LastSnapshot
	rewriteSnapshotManifest(t, foreignRootPath, func(manifest *Manifest) {
		manifest.PlanID = "retention-plan"
		manifest.SourceRootID = formatSourceRootID("22222222-3333-4444-8555-666666666666", directoryIdentity{
			ID: "0000000000000001", BirthSec: 1, BirthNsec: 1, Generation: 1,
		})
	})

	latest := runRetentionBackup(t, service, destination, "retention-plan", 1)
	if latest.LastError != "" || latest.LastSnapshot == "" || latest.RetentionError != "" || latest.RetentionRemoved != 1 {
		t.Fatalf("rotation result: %+v", latest)
	}
	for name, shouldExist := range map[string]bool{
		firstPath:              false,
		foreignRootPath:        true,
		manual.LastSnapshot:    true,
		otherPlan.LastSnapshot: true,
		latest.LastSnapshot:    true,
	} {
		_, err := os.Stat(name)
		if shouldExist && err != nil {
			t.Errorf("snapshot should be preserved %q: %v", name, err)
		}
		if !shouldExist && !errors.Is(err, os.ErrNotExist) {
			t.Errorf("old owned snapshot should be removed %q: %v", name, err)
		}
	}
}

func TestScheduledRetentionOffAndFailedBackupPreserveSnapshots(t *testing.T) {
	service, share, destination := newRetentionTestService(t)
	first := runRetentionBackup(t, service, destination, "retention-off", 1)
	if first.LastError != "" || first.LastSnapshot == "" {
		t.Fatalf("initial backup failed: %+v", first)
	}
	off := runRetentionBackup(t, service, destination, "retention-off", 0)
	if off.LastError != "" || off.LastSnapshot == "" || off.RetentionRemoved != 0 {
		t.Fatalf("retention-off backup failed: %+v", off)
	}
	if _, err := os.Stat(first.LastSnapshot); err != nil {
		t.Fatalf("retention off removed an existing snapshot: %v", err)
	}
	if err := share.Close(); err != nil {
		t.Fatal(err)
	}
	failed := runRetentionBackup(t, service, destination, "retention-off", 1)
	if failed.LastError == "" || failed.LastSnapshot != "" {
		t.Fatalf("offline backup unexpectedly succeeded: %+v", failed)
	}
	for _, snapshot := range []string{first.LastSnapshot, off.LastSnapshot} {
		if _, err := os.Stat(snapshot); err != nil {
			t.Fatalf("failed backup pruned prior snapshot %q: %v", snapshot, err)
		}
	}
}

func TestScheduledRetentionCanBeEnabledAfterRetentionOffSnapshots(t *testing.T) {
	service, _, destination := newRetentionTestService(t)
	manual := service.StartBackup(destination)
	if manual != nil {
		t.Fatal(manual)
	}
	manualSnapshot := await(t, service)
	if manualSnapshot.LastError != "" || manualSnapshot.LastSnapshot == "" {
		t.Fatalf("manual backup failed: %+v", manualSnapshot)
	}

	foreignPlan := runRetentionBackup(t, service, destination, "another-plan", 0)
	if foreignPlan.LastError != "" || foreignPlan.LastSnapshot == "" {
		t.Fatalf("foreign plan backup failed: %+v", foreignPlan)
	}

	first := runRetentionBackup(t, service, destination, "retention-later-on", 0)
	second := runRetentionBackup(t, service, destination, "retention-later-on", 0)
	if first.LastError != "" || first.LastSnapshot == "" || second.LastError != "" || second.LastSnapshot == "" {
		t.Fatalf("retention-off plan backups failed: first=%+v second=%+v", first, second)
	}
	firstManifest := readSnapshotManifest(t, first.LastSnapshot)
	secondManifest := readSnapshotManifest(t, second.LastSnapshot)
	if firstManifest.PlanID != "retention-later-on" || secondManifest.PlanID != "retention-later-on" ||
		!validSourceRootID(firstManifest.SourceRootID) || firstManifest.SourceRootID != secondManifest.SourceRootID {
		t.Fatalf("retention-off snapshots lack stable plan ownership: first=%+v second=%+v", firstManifest, secondManifest)
	}

	latest := runRetentionBackup(t, service, destination, "retention-later-on", 1)
	if latest.LastError != "" || latest.LastSnapshot == "" || latest.RetentionError != "" || latest.RetentionRemoved != 2 {
		t.Fatalf("enabling retention did not rotate old plan snapshots: %+v", latest)
	}
	for path, shouldExist := range map[string]bool{
		manualSnapshot.LastSnapshot: true,
		foreignPlan.LastSnapshot:    true,
		first.LastSnapshot:          false,
		second.LastSnapshot:         false,
		latest.LastSnapshot:         true,
	} {
		_, err := os.Stat(path)
		if shouldExist && err != nil {
			t.Errorf("snapshot should be preserved %q: %v", path, err)
		}
		if !shouldExist && !errors.Is(err, os.ErrNotExist) {
			t.Errorf("old snapshot should be removed after retention is enabled %q: %v", path, err)
		}
	}
}

func TestScheduledRetentionRejectsUnlistedContentAndPreservesNewBackup(t *testing.T) {
	service, _, destination := newRetentionTestService(t)
	first := runRetentionBackup(t, service, destination, "retention-extra", 1)
	if first.LastError != "" || first.LastSnapshot == "" {
		t.Fatalf("initial backup failed: %+v", first)
	}
	if err := os.WriteFile(filepath.Join(first.LastSnapshot, "unlisted.txt"), []byte("keep me"), 0600); err != nil {
		t.Fatal(err)
	}
	latest := runRetentionBackup(t, service, destination, "retention-extra", 1)
	if latest.LastError != "" || latest.LastSnapshot == "" || latest.RetentionError == "" || latest.RetentionRemoved != 0 {
		t.Fatalf("unsafe cleanup was not reported separately: %+v", latest)
	}
	if _, err := os.Stat(first.LastSnapshot); err != nil {
		t.Fatalf("untrusted prior snapshot was deleted: %v", err)
	}
	if _, err := os.Stat(latest.LastSnapshot); err != nil {
		t.Fatalf("completed new backup is missing: %v", err)
	}
}

func TestScheduledRetentionWithoutStableSourceIdentityKeepsOldSnapshots(t *testing.T) {
	service, _, destination := newRetentionTestService(t)
	first := runRetentionBackup(t, service, destination, "retention-no-source-id", 1)
	if first.LastError != "" || first.LastSnapshot == "" {
		t.Fatalf("initial backup failed: %+v", first)
	}
	sourcePath, online := service.files.State()
	if !online {
		t.Fatal("share unexpectedly offline")
	}
	resolvedSource, err := filepath.EvalSymlinks(sourcePath)
	if err != nil {
		t.Fatal(err)
	}
	service.readVolumeInfo = func(folder string) (diskutilVolumeInfo, error) {
		if folder == resolvedSource {
			return diskutilVolumeInfo{}, errors.New("source volume UUID unavailable")
		}
		return retentionTestReader(folder)
	}
	latest := runRetentionBackup(t, service, destination, "retention-no-source-id", 1)
	if latest.LastError != "" || latest.LastSnapshot == "" || latest.RetentionError == "" {
		t.Fatalf("identity failure was not isolated from backup success: %+v", latest)
	}
	if _, err := os.Stat(first.LastSnapshot); err != nil {
		t.Fatalf("identity failure pruned an old snapshot: %v", err)
	}
	if manifest := readSnapshotManifest(t, latest.LastSnapshot); manifest.SourceRootID != "" || manifest.PlanID != "retention-no-source-id" {
		t.Fatalf("missing source identity was claimed: %+v", manifest)
	}
	off := runRetentionBackup(t, service, destination, "retention-no-source-id", 0)
	if off.LastError != "" || off.LastSnapshot == "" || off.RetentionError != "" {
		t.Fatalf("retention-off backup should succeed without a cleanup warning: %+v", off)
	}
	if manifest := readSnapshotManifest(t, off.LastSnapshot); manifest.SourceRootID != "" || manifest.PlanID != "retention-no-source-id" {
		t.Fatalf("retention-off snapshot claimed an unavailable source identity: %+v", manifest)
	}
}

func TestScheduledBackupRechecksDestinationIdentity(t *testing.T) {
	service, _, destination := newRetentionTestService(t)
	identity, err := volumeDirectoryIdentity(destination, retentionTestReader)
	if err != nil {
		t.Fatal(err)
	}
	schedule := Schedule{
		Enabled: true, Destination: destination, PlanID: "retention-schedule", RetentionCount: 1,
		DestinationVolumeUUID: identity.VolumeUUID, DestinationDirectoryID: identity.ID,
		DestinationDirectoryBirthSec: identity.BirthSec, DestinationDirectoryBirthNsec: identity.BirthNsec,
		DestinationDirectoryGeneration: identity.Generation,
	}
	if err := service.StartScheduledBackupForSchedule(schedule); err != nil {
		t.Fatal(err)
	}
	created := await(t, service)
	if created.LastError != "" || created.LastSnapshot == "" {
		t.Fatalf("identity-bound backup failed: %+v", created)
	}
	before := created.LastSnapshot
	schedule.DestinationDirectoryID = "0000000000000001"
	if err := service.StartScheduledBackupForSchedule(schedule); err != nil {
		t.Fatal(err)
	}
	changed := await(t, service)
	if changed.LastError == "" || changed.LastSnapshot != "" {
		t.Fatalf("changed destination identity was accepted: %+v", changed)
	}
	if _, err := os.Stat(before); err != nil {
		t.Fatalf("identity mismatch affected the previous backup: %v", err)
	}
}

func TestSnapshotInventoryExposesOptionalPlanOwnership(t *testing.T) {
	service, _, destination := newRetentionTestService(t)
	manual := service.StartBackup(destination)
	if manual != nil {
		t.Fatal(manual)
	}
	manualStatus := await(t, service)
	if manualStatus.LastError != "" {
		t.Fatalf("manual backup failed: %+v", manualStatus)
	}
	planned := runRetentionBackup(t, service, destination, "inventory-plan", 1)
	if planned.LastError != "" || planned.LastSnapshot == "" {
		t.Fatalf("scheduled backup failed: %+v", planned)
	}
	inventory, err := service.ListSnapshots(context.Background(), destination)
	if err != nil {
		t.Fatal(err)
	}
	var manualFound, plannedFound bool
	for _, snapshot := range inventory.Snapshots {
		switch snapshot.Path {
		case manualStatus.LastSnapshot:
			manualFound = snapshot.PlanID == "" && snapshot.SourceRootID == ""
		case planned.LastSnapshot:
			plannedFound = snapshot.PlanID == "inventory-plan" && validSourceRootID(snapshot.SourceRootID)
		}
	}
	if !manualFound || !plannedFound {
		t.Fatalf("inventory ownership fields missing: %+v", inventory)
	}
}

func TestScheduledRetentionLimitFailsBeforeDeleting(t *testing.T) {
	service, _, destination := newRetentionTestService(t)
	first := runRetentionBackup(t, service, destination, "retention-limit", 1)
	if first.LastError != "" || first.LastSnapshot == "" {
		t.Fatalf("initial backup failed: %+v", first)
	}
	for index := 0; index < maxRetentionEntries; index++ {
		name := filepath.Join(destination, fmt.Sprintf("filler-%04d", index))
		if err := os.WriteFile(name, nil, 0600); err != nil {
			t.Fatal(err)
		}
	}
	latest := runRetentionBackup(t, service, destination, "retention-limit", 1)
	if latest.LastError != "" || latest.LastSnapshot == "" || latest.RetentionError != ErrRetentionScanLimit.Error() {
		t.Fatalf("scan limit was not reported: %+v", latest)
	}
	if _, err := os.Stat(first.LastSnapshot); err != nil {
		t.Fatalf("scan limit removed an old snapshot: %v", err)
	}
}

func TestRetentionCancelledPreflightDeletesNothing(t *testing.T) {
	service, _, destination := newRetentionTestService(t)
	first := runRetentionBackup(t, service, destination, "retention-cancel", 0)
	second := runRetentionBackup(t, service, destination, "retention-cancel", 0)
	if first.LastSnapshot == "" || second.LastSnapshot == "" {
		t.Fatal("test snapshots were not created")
	}
	_, online := service.files.State()
	if !online {
		t.Fatal("share unexpectedly offline")
	}
	sourcePath, _ := service.files.State()
	sourceID, err := sourceRootIdentity(sourcePath, retentionTestReader)
	if err != nil {
		t.Fatal(err)
	}
	for _, snapshot := range []string{first.LastSnapshot, second.LastSnapshot} {
		rewriteSnapshotManifest(t, snapshot, func(manifest *Manifest) {
			manifest.PlanID = "retention-cancel"
			manifest.SourceRootID = sourceID
		})
	}
	destinationIdentity, err := volumeDirectoryIdentity(destination, retentionTestReader)
	if err != nil {
		t.Fatal(err)
	}
	destinationRoot, err := os.OpenRoot(destination)
	if err != nil {
		t.Fatal(err)
	}
	defer destinationRoot.Close()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	removed, err := retainScheduledSnapshots(ctx, destinationRoot, destination, filepath.Base(second.LastSnapshot), "retention-cancel", sourceID, 1, &destinationIdentity, retentionTestReader)
	if !errors.Is(err, context.Canceled) || removed != 0 {
		t.Fatalf("canceled retention proceeded: removed=%d err=%v", removed, err)
	}
	for _, snapshot := range []string{first.LastSnapshot, second.LastSnapshot} {
		if _, err := os.Stat(snapshot); err != nil {
			t.Fatalf("canceled retention removed a snapshot: %v", err)
		}
	}
}

func retentionQuarantineFixture(t *testing.T, planID string) (*Service, string, Status, Status, string, destinationIdentity, *os.Root) {
	t.Helper()
	service, _, destination := newRetentionTestService(t)
	old := runRetentionBackup(t, service, destination, planID, 0)
	latest := runRetentionBackup(t, service, destination, planID, 0)
	if old.LastError != "" || old.LastSnapshot == "" || latest.LastError != "" || latest.LastSnapshot == "" {
		t.Fatalf("retention fixture backups failed: old=%+v latest=%+v", old, latest)
	}
	sourceID := readSnapshotManifest(t, latest.LastSnapshot).SourceRootID
	if !validSourceRootID(sourceID) {
		t.Fatalf("retention fixture has no source identity: %q", sourceID)
	}
	destinationID, err := volumeDirectoryIdentity(destination, retentionTestReader)
	if err != nil {
		t.Fatal(err)
	}
	root, err := os.OpenRoot(destination)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = root.Close() })
	return service, destination, old, latest, sourceID, destinationID, root
}

func TestRetentionQuarantineRejectsReplacedCandidateAndRestoresForeignDirectory(t *testing.T) {
	_, destination, old, latest, sourceID, destinationID, root := retentionQuarantineFixture(t, "retention-quarantine-replace")
	displaced := filepath.Join(destination, ".test-displaced-original")
	foreignMarker := "foreign organizer data"
	removed, err := retainScheduledSnapshotsWithHooks(context.Background(), root, destination,
		filepath.Base(latest.LastSnapshot), "retention-quarantine-replace", sourceID, 1, &destinationID, retentionTestReader,
		&retentionQuarantineHooks{beforeRename: func(candidateName string) error {
			if candidateName != filepath.Base(old.LastSnapshot) {
				return fmt.Errorf("unexpected deletion candidate: %s", candidateName)
			}
			if err := os.Rename(filepath.Join(destination, candidateName), displaced); err != nil {
				return err
			}
			if err := os.Mkdir(filepath.Join(destination, candidateName), 0700); err != nil {
				return err
			}
			return os.WriteFile(filepath.Join(destination, candidateName, "foreign.txt"), []byte(foreignMarker), 0600)
		}})
	if !errors.Is(err, ErrRetentionSnapshotChanged) || removed != 0 {
		t.Fatalf("replaced candidate was not rejected: removed=%d err=%v", removed, err)
	}
	if manifest := readSnapshotManifest(t, displaced); manifest.PlanID != "retention-quarantine-replace" {
		t.Fatalf("original snapshot was lost during replacement: %+v", manifest)
	}
	foreign, err := os.ReadFile(filepath.Join(destination, filepath.Base(old.LastSnapshot), "foreign.txt"))
	if err != nil || string(foreign) != foreignMarker {
		t.Fatalf("foreign replacement was not restored intact: %q %v", foreign, err)
	}
	if _, err := os.Stat(latest.LastSnapshot); err != nil {
		t.Fatalf("current snapshot was affected: %v", err)
	}
	for _, entry := range mustReadDir(t, destination) {
		if strings.HasPrefix(entry.Name(), ".lightisle-retention-") {
			t.Fatalf("quarantine remained after successful restoration: %s", entry.Name())
		}
	}
}

func TestRetentionQuarantineRevalidatesUnknownFileAndRestores(t *testing.T) {
	_, destination, old, latest, sourceID, destinationID, root := retentionQuarantineFixture(t, "retention-quarantine-unknown")
	removed, err := retainScheduledSnapshotsWithHooks(context.Background(), root, destination,
		filepath.Base(latest.LastSnapshot), "retention-quarantine-unknown", sourceID, 1, &destinationID, retentionTestReader,
		&retentionQuarantineHooks{afterRename: func(_, quarantineName string) error {
			quarantine, err := root.OpenRoot(quarantineName)
			if err != nil {
				return err
			}
			defer quarantine.Close()
			file, err := quarantine.OpenFile("unlisted.txt", os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
			if err != nil {
				return err
			}
			if _, err := file.Write([]byte("preserve")); err != nil {
				_ = file.Close()
				return err
			}
			return file.Close()
		}})
	if !errors.Is(err, ErrRetentionSnapshotUntrusted) || removed != 0 {
		t.Fatalf("quarantine tree was not revalidated: removed=%d err=%v", removed, err)
	}
	if _, err := os.Stat(old.LastSnapshot); err != nil {
		t.Fatalf("untrusted snapshot was not restored: %v", err)
	}
	if data, err := os.ReadFile(filepath.Join(old.LastSnapshot, "unlisted.txt")); err != nil || string(data) != "preserve" {
		t.Fatalf("new unknown content was not preserved: %q %v", data, err)
	}
	if _, err := os.Stat(latest.LastSnapshot); err != nil {
		t.Fatalf("current snapshot was affected: %v", err)
	}
}

func TestRetentionQuarantineCancellationRestoresOriginalName(t *testing.T) {
	_, destination, old, latest, sourceID, destinationID, root := retentionQuarantineFixture(t, "retention-quarantine-cancel")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	removed, err := retainScheduledSnapshotsWithHooks(ctx, root, destination,
		filepath.Base(latest.LastSnapshot), "retention-quarantine-cancel", sourceID, 1, &destinationID, retentionTestReader,
		&retentionQuarantineHooks{afterRename: func(_, _ string) error {
			cancel()
			return nil
		}})
	if !errors.Is(err, context.Canceled) || removed != 0 {
		t.Fatalf("canceled quarantine was not restored: removed=%d err=%v", removed, err)
	}
	if _, err := os.Stat(old.LastSnapshot); err != nil {
		t.Fatalf("original snapshot name was not restored: %v", err)
	}
	if _, err := os.Stat(latest.LastSnapshot); err != nil {
		t.Fatalf("current snapshot was affected: %v", err)
	}
	for _, entry := range mustReadDir(t, destination) {
		if strings.HasPrefix(entry.Name(), ".lightisle-retention-") {
			t.Fatalf("quarantine remained after cancellation recovery: %s", entry.Name())
		}
	}
}

func TestRetentionQuarantineRestoreFailurePreservesAndReportsQuarantine(t *testing.T) {
	_, destination, old, latest, sourceID, destinationID, root := retentionQuarantineFixture(t, "retention-quarantine-restore-failure")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	foreignMarker := "new destination entry"
	removed, err := retainScheduledSnapshotsWithHooks(ctx, root, destination,
		filepath.Base(latest.LastSnapshot), "retention-quarantine-restore-failure", sourceID, 1, &destinationID, retentionTestReader,
		&retentionQuarantineHooks{afterRename: func(candidateName, _ string) error {
			if err := os.Mkdir(filepath.Join(destination, candidateName), 0700); err != nil {
				return err
			}
			if err := os.WriteFile(filepath.Join(destination, candidateName, "foreign.txt"), []byte(foreignMarker), 0600); err != nil {
				return err
			}
			cancel()
			return nil
		}})
	if !errors.Is(err, context.Canceled) || removed != 0 {
		t.Fatalf("quarantine recovery failure was not reported: removed=%d err=%v", removed, err)
	}
	if _, err := os.Stat(filepath.Join(destination, filepath.Base(old.LastSnapshot), "foreign.txt")); err != nil {
		t.Fatalf("foreign replacement was overwritten: %v", err)
	}
	var preserved string
	for _, entry := range mustReadDir(t, destination) {
		if strings.HasPrefix(entry.Name(), ".lightisle-retention-") {
			preserved = filepath.Join(destination, entry.Name())
			break
		}
	}
	if preserved == "" || !strings.Contains(err.Error(), preserved) {
		t.Fatalf("recovery error does not identify preserved quarantine: path=%q err=%v", preserved, err)
	}
	if manifest := readSnapshotManifest(t, preserved); manifest.PlanID != "retention-quarantine-restore-failure" {
		t.Fatalf("quarantined original snapshot was lost: %+v", manifest)
	}
	if _, err := os.Stat(latest.LastSnapshot); err != nil {
		t.Fatalf("current snapshot was affected: %v", err)
	}
}

func mustReadDir(t *testing.T, directory string) []os.DirEntry {
	t.Helper()
	entries, err := os.ReadDir(directory)
	if err != nil {
		t.Fatal(err)
	}
	return entries
}
