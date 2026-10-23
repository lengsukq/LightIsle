package backup

import (
	"bytes"
	"context"
	cryptorand "crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	maxRetentionEntries       = 4096
	maxRetentionSnapshots     = 128
	maxRetentionManifestBytes = int64(8 << 20)
	maxRetentionTotalManifest = int64(64 << 20)
	maxRetentionTreeEntries   = 40000
	maxRetentionVerifyBytes   = int64(50) << 30
	retentionScanTimeBudget   = 10 * time.Second
)

var (
	ErrRetentionInvalid             = errors.New("backup_retention_invalid")
	ErrRetentionIdentityUnavailable = errors.New("backup_retention_identity_unavailable")
	ErrRetentionScanLimit           = errors.New("backup_retention_scan_limit")
	ErrRetentionSnapshotUntrusted   = errors.New("backup_retention_snapshot_untrusted")
	ErrRetentionSnapshotChanged     = errors.New("backup_retention_snapshot_changed")
	ErrRetentionExclusiveRename     = errors.New("backup_retention_exclusive_rename_unavailable")
	ErrBackupSourceChanged          = errors.New("backup_source_identity_changed")
)

type retentionCandidate struct {
	name        string
	info        os.FileInfo
	manifest    Manifest
	manifestRaw []byte
}

type retentionQuarantineHooks struct {
	beforeRename func(candidateName string) error
	afterRename  func(candidateName, quarantineName string) error
}

func sourceRootIdentity(source string, reader func(string) (diskutilVolumeInfo, error)) (string, error) {
	resolved, err := filepath.EvalSymlinks(source)
	if err != nil {
		return "", ErrRetentionIdentityUnavailable
	}
	identity, err := captureDestinationIdentity(resolved, reader)
	if err != nil {
		return "", ErrRetentionIdentityUnavailable
	}
	return formatSourceRootID(identity.VolumeUUID, identity.directoryIdentity), nil
}

func formatSourceRootID(volumeUUID string, identity directoryIdentity) string {
	return fmt.Sprintf("fsr1:%s:%s:%d:%d:%d", strings.ToUpper(volumeUUID), identity.ID,
		identity.BirthSec, identity.BirthNsec, identity.Generation)
}

func validSourceRootID(value string) bool {
	parts := strings.Split(value, ":")
	if len(parts) != 6 || parts[0] != "fsr1" || !validUUID(parts[1]) || len(parts[2]) != 16 {
		return false
	}
	if _, err := hex.DecodeString(parts[2]); err != nil {
		return false
	}
	birthSec, err := strconv.ParseInt(parts[3], 10, 64)
	if err != nil {
		return false
	}
	nsec, err := strconv.ParseInt(parts[4], 10, 64)
	if err != nil || nsec < 0 || nsec >= 1_000_000_000 {
		return false
	}
	generation, err := strconv.ParseUint(parts[5], 10, 32)
	if err != nil || generation > uint64(^uint32(0)) {
		return false
	}
	return validDirectoryIdentity(directoryIdentity{
		ID: parts[2], BirthSec: birthSec, BirthNsec: nsec, Generation: uint32(generation),
	})
}

func volumeDirectoryIdentity(folder string, reader func(string) (diskutilVolumeInfo, error)) (destinationIdentity, error) {
	return captureDestinationIdentity(folder, reader)
}

func verifyPinnedDestination(root *os.Root, destination string, expected destinationIdentity, reader func(string) (diskutilVolumeInfo, error)) error {
	opened, err := root.Stat(".")
	if err != nil {
		return ErrDestinationFolderChanged
	}
	current, err := os.Stat(destination)
	if err != nil || !os.SameFile(opened, current) {
		return ErrDestinationFolderChanged
	}
	observed, err := volumeDirectoryIdentity(destination, reader)
	if err != nil || observed != expected {
		return ErrDestinationFolderChanged
	}
	return nil
}

func syncBackupRoot(root *os.Root) error {
	directory, err := root.Open(".")
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

func retainScheduledSnapshots(ctx context.Context, root *os.Root, destination, currentName, planID, sourceRootID string, keep int, expectedDestination *destinationIdentity, reader func(string) (diskutilVolumeInfo, error)) (int, error) {
	return retainScheduledSnapshotsWithHooks(ctx, root, destination, currentName, planID, sourceRootID, keep, expectedDestination, reader, nil)
}

func retainScheduledSnapshotsWithHooks(ctx context.Context, root *os.Root, destination, currentName, planID, sourceRootID string, keep int, expectedDestination *destinationIdentity, reader func(string) (diskutilVolumeInfo, error), hooks *retentionQuarantineHooks) (int, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if keep < 1 || keep > maximumScheduledRetention || !validPlanID(planID) || !validSourceRootID(sourceRootID) {
		return 0, ErrRetentionInvalid
	}
	if expectedDestination == nil {
		return 0, ErrRetentionIdentityUnavailable
	}
	if err := verifyPinnedDestination(root, destination, *expectedDestination, reader); err != nil {
		return 0, err
	}
	deadline := time.Now().Add(retentionScanTimeBudget)
	entries, err := boundedRootEntries(ctx, root, deadline)
	if err != nil {
		return 0, err
	}
	names := make([]string, 0, 16)
	for _, entry := range entries {
		if !strings.HasPrefix(entry.Name(), "LightIsle-Backup-") {
			continue
		}
		if len(names) == maxRetentionSnapshots {
			return 0, ErrRetentionScanLimit
		}
		names = append(names, entry.Name())
	}
	sort.Strings(names)

	owners := make([]retentionCandidate, 0, len(names))
	manifestBytes := int64(0)
	currentFound := false
	for _, name := range names {
		if err := ctx.Err(); err != nil {
			return 0, err
		}
		if time.Now().After(deadline) {
			return 0, ErrRetentionScanLimit
		}
		candidate, err := inspectRetentionCandidate(root, name, manifestBytes)
		if err != nil {
			return 0, err
		}
		manifestBytes += int64(len(candidate.manifestRaw))
		if manifestBytes > maxRetentionTotalManifest {
			return 0, ErrRetentionScanLimit
		}
		if candidate.manifest.PlanID != planID || candidate.manifest.SourceRootID != sourceRootID {
			continue
		}
		if candidate.manifest.Format != format || candidate.manifest.Created <= 0 || candidate.manifest.Source == "" || len(candidate.manifest.Source) > 1024 {
			return 0, ErrRetentionSnapshotUntrusted
		}
		if name == currentName {
			currentFound = true
		}
		owners = append(owners, candidate)
	}
	if !currentFound {
		return 0, ErrRetentionSnapshotUntrusted
	}
	sort.Slice(owners, func(i, j int) bool {
		if owners[i].manifest.Created != owners[j].manifest.Created {
			return owners[i].manifest.Created > owners[j].manifest.Created
		}
		if owners[i].name == currentName {
			return true
		}
		if owners[j].name == currentName {
			return false
		}
		return owners[i].name > owners[j].name
	})
	currentRank := -1
	for index, candidate := range owners {
		if candidate.name == currentName {
			currentRank = index
			break
		}
	}
	if currentRank < 0 || currentRank >= keep {
		return 0, ErrRetentionSnapshotUntrusted
	}
	if len(owners) <= keep {
		return 0, nil
	}
	targets := append([]retentionCandidate(nil), owners[keep:]...)
	// Remove the oldest first so cancellation or a later filesystem error leaves
	// the newest excess snapshots available for recovery.
	for left, right := 0, len(targets)-1; left < right; left, right = left+1, right-1 {
		targets[left], targets[right] = targets[right], targets[left]
	}

	var verifyBytes int64
	for _, candidate := range targets {
		if err := ctx.Err(); err != nil {
			return 0, err
		}
		size := manifestSize(candidate.manifest)
		if size < 0 || size > maxRetentionVerifyBytes-verifyBytes {
			return 0, ErrRetentionScanLimit
		}
		verifyBytes += size
		if err := verifyRetentionCandidate(ctx, root, candidate); err != nil {
			return 0, err
		}
	}

	removed := 0
	for _, candidate := range targets {
		if err := ctx.Err(); err != nil {
			return removed, err
		}
		if err := verifyPinnedDestination(root, destination, *expectedDestination, reader); err != nil {
			return removed, err
		}
		if err := verifyRetentionCandidate(ctx, root, candidate); err != nil {
			return removed, err
		}
		if err := verifyPinnedDestination(root, destination, *expectedDestination, reader); err != nil {
			return removed, err
		}
		currentInfo, statErr := root.Lstat(candidate.name)
		if statErr != nil || currentInfo.Mode()&os.ModeSymlink != 0 || !currentInfo.IsDir() || !os.SameFile(candidate.info, currentInfo) {
			return removed, ErrRetentionSnapshotChanged
		}
		if err := ctx.Err(); err != nil {
			return removed, err
		}
		if hooks != nil && hooks.beforeRename != nil {
			if err := hooks.beforeRename(candidate.name); err != nil {
				return removed, err
			}
		}
		quarantineName, err := newRetentionQuarantineName()
		if err != nil {
			return removed, err
		}
		if err := retentionRenameNoReplace(root, candidate.name, quarantineName); err != nil {
			return removed, err
		}
		quarantinePath := filepath.Join(destination, quarantineName)
		quarantineInfo, statErr := root.Lstat(quarantineName)
		restore := func(cause error) error {
			return restoreRetentionQuarantine(root, candidate.name, quarantineName, destination, quarantineInfo, cause)
		}
		if statErr != nil {
			return removed, fmt.Errorf("backup_retention_quarantine_identity_unavailable: %s: %w", quarantinePath, statErr)
		}
		if err := syncBackupRoot(root); err != nil {
			return removed, restore(fmt.Errorf("backup_retention_quarantine_sync_failed: %w", err))
		}
		currentQuarantineInfo, err := root.Lstat(quarantineName)
		if err != nil || currentQuarantineInfo.Mode()&os.ModeSymlink != 0 || !currentQuarantineInfo.IsDir() ||
			!os.SameFile(quarantineInfo, currentQuarantineInfo) || !os.SameFile(candidate.info, currentQuarantineInfo) {
			return removed, restore(ErrRetentionSnapshotChanged)
		}
		if hooks != nil && hooks.afterRename != nil {
			if err := hooks.afterRename(candidate.name, quarantineName); err != nil {
				return removed, restore(err)
			}
		}
		if err := ctx.Err(); err != nil {
			return removed, restore(err)
		}
		if err := verifyPinnedDestination(root, destination, *expectedDestination, reader); err != nil {
			return removed, restore(err)
		}
		quarantined := candidate
		quarantined.name = quarantineName
		if err := verifyRetentionCandidate(ctx, root, quarantined); err != nil {
			return removed, restore(err)
		}
		if err := verifyPinnedDestination(root, destination, *expectedDestination, reader); err != nil {
			return removed, restore(err)
		}
		currentQuarantineInfo, err = root.Lstat(quarantineName)
		if err != nil || currentQuarantineInfo.Mode()&os.ModeSymlink != 0 || !currentQuarantineInfo.IsDir() ||
			!os.SameFile(quarantineInfo, currentQuarantineInfo) || !os.SameFile(candidate.info, currentQuarantineInfo) {
			return removed, restore(ErrRetentionSnapshotChanged)
		}
		if err := ctx.Err(); err != nil {
			return removed, restore(err)
		}
		if err := root.RemoveAll(quarantineName); err != nil {
			return removed, fmt.Errorf("backup_retention_quarantine_cleanup_failed: %s: %w", quarantinePath, err)
		}
		removed++
		if err := syncBackupRoot(root); err != nil {
			return removed, fmt.Errorf("backup_retention_sync_failed: %w", err)
		}
		if err := ctx.Err(); err != nil {
			return removed, err
		}
	}
	return removed, nil
}

func newRetentionQuarantineName() (string, error) {
	var random [16]byte
	if _, err := cryptorand.Read(random[:]); err != nil {
		return "", err
	}
	return ".lightisle-retention-" + hex.EncodeToString(random[:]), nil
}

func restoreRetentionQuarantine(root *os.Root, candidateName, quarantineName, destination string, expectedQuarantine os.FileInfo, cause error) error {
	quarantinePath := filepath.Join(destination, quarantineName)
	info, err := root.Lstat(quarantineName)
	if err != nil || expectedQuarantine == nil || !os.SameFile(expectedQuarantine, info) {
		return fmt.Errorf("%w: backup_retention_quarantine_identity_changed: %s", cause, quarantinePath)
	}
	if err := retentionRenameNoReplace(root, quarantineName, candidateName); err != nil {
		return fmt.Errorf("%w: backup_retention_restore_failed; quarantine preserved at %s: %v", cause, quarantinePath, err)
	}
	restored, err := root.Lstat(candidateName)
	if err != nil || !os.SameFile(expectedQuarantine, restored) {
		return fmt.Errorf("%w: backup_retention_restore_identity_failed: %s", cause, filepath.Join(destination, candidateName))
	}
	if err := syncBackupRoot(root); err != nil {
		return fmt.Errorf("%w: backup_retention_restore_sync_failed: %s: %v", cause, filepath.Join(destination, candidateName), err)
	}
	return cause
}

func boundedRootEntries(ctx context.Context, root *os.Root, deadline time.Time) ([]os.DirEntry, error) {
	directory, err := root.Open(".")
	if err != nil {
		return nil, err
	}
	defer directory.Close()
	entries := make([]os.DirEntry, 0, 64)
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if time.Now().After(deadline) {
			return nil, ErrRetentionScanLimit
		}
		remaining := maxRetentionEntries - len(entries)
		batchSize := 128
		if remaining == 0 {
			more, readErr := directory.ReadDir(1)
			if len(more) > 0 {
				return nil, ErrRetentionScanLimit
			}
			if readErr != nil && !errors.Is(readErr, io.EOF) {
				return nil, readErr
			}
			return entries, nil
		}
		if remaining < batchSize {
			batchSize = remaining
		}
		batch, readErr := directory.ReadDir(batchSize)
		entries = append(entries, batch...)
		if errors.Is(readErr, io.EOF) {
			return entries, nil
		}
		if readErr != nil {
			return nil, readErr
		}
	}
}

func inspectRetentionCandidate(root *os.Root, name string, manifestBytes int64) (retentionCandidate, error) {
	info, err := root.Lstat(name)
	if err != nil {
		return retentionCandidate{}, ErrRetentionSnapshotChanged
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return retentionCandidate{}, ErrRetentionSnapshotUntrusted
	}
	snapshot, err := root.OpenRoot(name)
	if err != nil {
		return retentionCandidate{}, ErrRetentionSnapshotChanged
	}
	defer snapshot.Close()
	openedInfo, err := snapshot.Stat(".")
	if err != nil || !os.SameFile(info, openedInfo) {
		return retentionCandidate{}, ErrRetentionSnapshotChanged
	}
	manifest, raw, err := readRetentionManifest(snapshot)
	if err != nil {
		return retentionCandidate{}, fmt.Errorf("%w: %v", ErrRetentionSnapshotUntrusted, err)
	}
	if int64(len(raw)) > maxRetentionTotalManifest-manifestBytes {
		return retentionCandidate{}, ErrRetentionScanLimit
	}
	return retentionCandidate{name: name, info: info, manifest: manifest, manifestRaw: raw}, nil
}

func readRetentionManifest(root *os.Root) (Manifest, []byte, error) {
	info, err := root.Lstat("manifest.json")
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Size() < 0 || info.Size() > maxRetentionManifestBytes {
		return Manifest{}, nil, ErrRetentionSnapshotUntrusted
	}
	file, err := root.Open("manifest.json")
	if err != nil {
		return Manifest{}, nil, err
	}
	defer file.Close()
	openedInfo, err := file.Stat()
	if err != nil || !os.SameFile(info, openedInfo) {
		return Manifest{}, nil, ErrRetentionSnapshotChanged
	}
	raw, err := io.ReadAll(io.LimitReader(file, maxRetentionManifestBytes+1))
	if err != nil {
		return Manifest{}, nil, err
	}
	if int64(len(raw)) > maxRetentionManifestBytes || int64(len(raw)) != openedInfo.Size() {
		return Manifest{}, nil, ErrRetentionSnapshotUntrusted
	}
	var manifest Manifest
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&manifest); err != nil {
		return Manifest{}, nil, ErrRetentionSnapshotUntrusted
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return Manifest{}, nil, ErrRetentionSnapshotUntrusted
	}
	if err := validateInventoryManifest(manifest); err != nil {
		return Manifest{}, nil, err
	}
	return manifest, raw, nil
}

func verifyRetentionCandidate(ctx context.Context, destinationRoot *os.Root, candidate retentionCandidate) error {
	currentInfo, err := destinationRoot.Lstat(candidate.name)
	if err != nil || currentInfo.Mode()&os.ModeSymlink != 0 || !currentInfo.IsDir() || !os.SameFile(candidate.info, currentInfo) {
		return ErrRetentionSnapshotChanged
	}
	snapshot, err := destinationRoot.OpenRoot(candidate.name)
	if err != nil {
		return ErrRetentionSnapshotChanged
	}
	defer snapshot.Close()
	openedInfo, err := snapshot.Stat(".")
	if err != nil || !os.SameFile(currentInfo, openedInfo) {
		return ErrRetentionSnapshotChanged
	}
	manifest, raw, err := readRetentionManifest(snapshot)
	if err != nil || !bytes.Equal(raw, candidate.manifestRaw) || manifest.PlanID != candidate.manifest.PlanID ||
		manifest.SourceRootID != candidate.manifest.SourceRootID || manifest.Created != candidate.manifest.Created {
		return ErrRetentionSnapshotChanged
	}
	if err := verifyControlledSnapshotTree(ctx, snapshot, manifest); err != nil {
		return err
	}
	for _, entry := range manifest.Files {
		if err := verifyEntry(ctx, snapshot, path.Join("data", entry.Path), entry); err != nil {
			return fmt.Errorf("%w: file %q: %v", ErrRetentionSnapshotUntrusted, entry.Path, err)
		}
	}
	for _, entry := range manifest.Metadata {
		if err := verifyEntry(ctx, snapshot, path.Join("metadata", entry.Path), entry); err != nil {
			return fmt.Errorf("%w: metadata %q: %v", ErrRetentionSnapshotUntrusted, entry.Path, err)
		}
	}
	return nil
}

func verifyControlledSnapshotTree(ctx context.Context, root *os.Root, manifest Manifest) error {
	expectedDirs := make(map[string]struct{}, len(manifest.Dirs)+4)
	expectedFiles := map[string]struct{}{"manifest.json": {}}
	addDir := func(name string) error {
		if name == "" || name == "." {
			return nil
		}
		if len(expectedDirs) >= maxRetentionTreeEntries {
			return ErrRetentionScanLimit
		}
		expectedDirs[name] = struct{}{}
		parent := path.Dir(name)
		for parent != "." && parent != "/" {
			if len(expectedDirs) >= maxRetentionTreeEntries {
				return ErrRetentionScanLimit
			}
			expectedDirs[parent] = struct{}{}
			parent = path.Dir(parent)
		}
		return nil
	}
	addFile := func(name string) error {
		if len(expectedFiles)+len(expectedDirs) >= maxRetentionTreeEntries {
			return ErrRetentionScanLimit
		}
		expectedFiles[name] = struct{}{}
		return addDir(path.Dir(name))
	}
	for _, name := range manifest.Dirs {
		if err := addDir(path.Join("data", name)); err != nil {
			return err
		}
	}
	for _, entry := range manifest.Files {
		if err := addFile(path.Join("data", entry.Path)); err != nil {
			return err
		}
	}
	for _, entry := range manifest.Metadata {
		if err := addFile(path.Join("metadata", entry.Path)); err != nil {
			return err
		}
	}
	seenDirs := make(map[string]struct{}, len(expectedDirs))
	seenFiles := make(map[string]struct{}, len(expectedFiles))
	queue := []string{"."}
	visited := 0
	for len(queue) > 0 {
		if err := ctx.Err(); err != nil {
			return err
		}
		current := queue[0]
		queue = queue[1:]
		var expectedDirInfo os.FileInfo
		if current != "." {
			var statErr error
			expectedDirInfo, statErr = root.Lstat(current)
			if statErr != nil || expectedDirInfo.Mode()&os.ModeSymlink != 0 || !expectedDirInfo.IsDir() {
				return ErrRetentionSnapshotUntrusted
			}
		}
		directory, err := root.Open(current)
		if err != nil {
			return ErrRetentionSnapshotUntrusted
		}
		info, err := directory.Stat()
		if err != nil || !info.IsDir() || (expectedDirInfo != nil && !os.SameFile(expectedDirInfo, info)) {
			directory.Close()
			return ErrRetentionSnapshotUntrusted
		}
		for {
			if err := ctx.Err(); err != nil {
				directory.Close()
				return err
			}
			batch, readErr := directory.ReadDir(128)
			for _, entry := range batch {
				visited++
				if visited > maxRetentionTreeEntries {
					directory.Close()
					return ErrRetentionScanLimit
				}
				relative := entry.Name()
				if current != "." {
					relative = path.Join(current, relative)
				}
				actual, statErr := root.Lstat(relative)
				if statErr != nil || actual.Mode()&os.ModeSymlink != 0 {
					directory.Close()
					return ErrRetentionSnapshotUntrusted
				}
				if actual.IsDir() {
					if _, ok := expectedDirs[relative]; !ok {
						directory.Close()
						return ErrRetentionSnapshotUntrusted
					}
					seenDirs[relative] = struct{}{}
					queue = append(queue, relative)
					continue
				}
				if !actual.Mode().IsRegular() {
					directory.Close()
					return ErrRetentionSnapshotUntrusted
				}
				if _, ok := expectedFiles[relative]; !ok {
					directory.Close()
					return ErrRetentionSnapshotUntrusted
				}
				seenFiles[relative] = struct{}{}
			}
			if errors.Is(readErr, io.EOF) {
				break
			}
			if readErr != nil {
				directory.Close()
				return readErr
			}
		}
		if err := directory.Close(); err != nil {
			return err
		}
	}
	if len(seenDirs) != len(expectedDirs) || len(seenFiles) != len(expectedFiles) {
		return ErrRetentionSnapshotUntrusted
	}
	return nil
}
