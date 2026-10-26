package backup

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const (
	maxInventoryEntries       = 4096
	maxInventorySnapshots     = 128
	maxInventoryManifestBytes = int64(8 << 20)
	maxInventoryTotalManifest = int64(64 << 20)
	inventoryTimeBudget       = time.Second
)

var ErrInventoryUnavailable = errors.New("backup_inventory_unavailable")

// SnapshotInventory describes recognizable snapshots directly inside one
// destination folder. SizeBytes is the sum declared by each manifest;
// Integrity is never "verified" because listing does not hash snapshot data.
type SnapshotInventory struct {
	Destination    string           `json:"destination"`
	Snapshots      []SnapshotRecord `json:"snapshots"`
	Truncated      bool             `json:"truncated"`
	ScannedEntries int              `json:"scannedEntries"`
}

type SnapshotRecord struct {
	Name            string `json:"name"`
	BackupType      string `json:"backupType,omitempty"`
	Path            string `json:"path"`
	Version         string `json:"version"`
	CreatedAt       int64  `json:"createdAt"`
	SizeBytes       int64  `json:"sizeBytes"`
	PlanID          string `json:"planID,omitempty"`
	SourceRootID    string `json:"sourceRootID,omitempty"`
	LogicalRootID   string `json:"logicalRootID,omitempty"`
	RootGeneration  uint64 `json:"rootGeneration,omitempty"`
	Integrity       string `json:"integrity"`
	IntegrityDetail string `json:"integrityDetail,omitempty"`
}

// ListSnapshots reads a bounded number of top-level LightIsle snapshot
// manifests. It never hashes contents, deletes snapshots, or follows
// candidate/manifest symlinks. The caller can offer full verification
// separately through VerifySnapshot.
func (s *Service) ListSnapshots(ctx context.Context, destination string) (SnapshotInventory, error) {
	inventory := SnapshotInventory{Snapshots: []SnapshotRecord{}}
	if ctx == nil {
		ctx = context.Background()
	}
	if destination == "" {
		return inventory, ErrInvalid
	}
	resolved, err := s.CheckDestination(destination)
	if err != nil {
		return inventory, err
	}
	if filepath.Clean(destination) != resolved {
		return inventory, ErrInvalid
	}
	source, online := s.files.State()
	if !online {
		return inventory, ErrOffline
	}
	source, err = filepath.EvalSymlinks(source)
	if err != nil {
		return inventory, ErrOffline
	}
	if err := disjoint(source, resolved); err != nil {
		return inventory, ErrInvalid
	}
	inventory.Destination = resolved

	root, err := os.OpenRoot(resolved)
	if err != nil {
		return inventory, ErrInventoryUnavailable
	}
	defer root.Close()
	directory, err := root.Open(".")
	if err != nil {
		return inventory, ErrInventoryUnavailable
	}
	defer directory.Close()

	deadline := time.Now().Add(inventoryTimeBudget)
	candidates := make([]string, 0, 16)
	for {
		if ctx.Err() != nil || time.Now().After(deadline) {
			inventory.Truncated = true
			break
		}
		remaining := maxInventoryEntries - inventory.ScannedEntries
		if remaining <= 0 {
			more, readErr := directory.ReadDir(1)
			if len(more) > 0 {
				inventory.Truncated = true
			} else if readErr != nil && !errors.Is(readErr, io.EOF) {
				return inventory, ErrInventoryUnavailable
			}
			break
		}
		batchSize := 128
		if remaining < batchSize {
			batchSize = remaining
		}
		entries, readErr := directory.ReadDir(batchSize)
		inventory.ScannedEntries += len(entries)
		for _, entry := range entries {
			if !strings.HasPrefix(entry.Name(), "LightIsle-Backup-") {
				continue
			}
			if len(candidates) == maxInventorySnapshots {
				inventory.Truncated = true
				break
			}
			candidates = append(candidates, entry.Name())
		}
		if inventory.Truncated {
			break
		}
		if errors.Is(readErr, io.EOF) {
			break
		}
		if readErr != nil {
			return inventory, ErrInventoryUnavailable
		}
		if inventory.ScannedEntries == maxInventoryEntries {
			continue
		}
	}

	// Snapshot names include their UTC creation time, so this processes newer
	// snapshots first when a manifest read budget is exhausted.
	sort.Sort(sort.Reverse(sort.StringSlice(candidates)))
	manifestBytes := int64(0)
	for i, name := range candidates {
		if ctx.Err() != nil || time.Now().After(deadline) {
			inventory.Truncated = true
			for _, pending := range candidates[i:] {
				inventory.Snapshots = append(inventory.Snapshots, SnapshotRecord{
					Name: pending, Path: filepath.Join(resolved, pending),
					Integrity: "not_verified_limit", IntegrityDetail: "scan_time_limit",
				})
			}
			break
		}
		record, consumed := inspectSnapshot(root, resolved, name, manifestBytes)
		manifestBytes += consumed
		inventory.Snapshots = append(inventory.Snapshots, record)
		if manifestBytes >= maxInventoryTotalManifest {
			inventory.Truncated = true
		}
	}
	sort.SliceStable(inventory.Snapshots, func(i, j int) bool {
		left, right := inventory.Snapshots[i], inventory.Snapshots[j]
		if left.CreatedAt != right.CreatedAt {
			return left.CreatedAt > right.CreatedAt
		}
		return left.Name > right.Name
	})
	return inventory, nil
}

func inspectSnapshot(root *os.Root, destination, name string, manifestBytes int64) (SnapshotRecord, int64) {
	record := SnapshotRecord{
		Name: name, Path: filepath.Join(destination, name), Integrity: "invalid",
	}
	info, err := root.Lstat(name)
	if err != nil {
		record.IntegrityDetail = "snapshot_unavailable"
		return record, 0
	}
	if info.Mode()&os.ModeSymlink != 0 {
		record.IntegrityDetail = "snapshot_symlink"
		return record, 0
	}
	if !info.IsDir() {
		record.IntegrityDetail = "snapshot_not_directory"
		return record, 0
	}
	snapshot, err := root.OpenRoot(name)
	if err != nil {
		record.IntegrityDetail = "snapshot_unavailable"
		return record, 0
	}
	defer snapshot.Close()
	openedInfo, err := snapshot.Stat(".")
	if err != nil || !os.SameFile(info, openedInfo) {
		record.IntegrityDetail = "snapshot_changed_during_scan"
		return record, 0
	}
	manifestInfo, err := snapshot.Lstat("manifest.json")
	if err != nil {
		record.IntegrityDetail = "manifest_missing"
		return record, 0
	}
	if manifestInfo.Mode()&os.ModeSymlink != 0 || !manifestInfo.Mode().IsRegular() {
		record.IntegrityDetail = "manifest_not_regular"
		return record, 0
	}
	if manifestInfo.Size() < 0 || manifestInfo.Size() > maxInventoryManifestBytes {
		record.Integrity = "not_verified_limit"
		record.IntegrityDetail = "manifest_size_limit"
		return record, 0
	}
	if manifestBytes+manifestInfo.Size() > maxInventoryTotalManifest {
		record.Integrity = "not_verified_limit"
		record.IntegrityDetail = "manifest_scan_budget"
		return record, 0
	}

	manifest, err := readInventoryManifest(snapshot, manifestInfo)
	if err != nil {
		if errors.Is(err, ErrTooLarge) {
			record.Integrity = "not_verified_limit"
			record.IntegrityDetail = "manifest_size_limit"
		} else {
			record.IntegrityDetail = "manifest_invalid"
		}
		return record, manifestInfo.Size()
	}
	record.Version = manifest.Format
	record.BackupType = manifest.BackupType
	record.CreatedAt = manifest.Created
	record.SizeBytes = manifestSize(manifest)
	record.PlanID = manifest.PlanID
	record.SourceRootID = manifest.SourceRootID
	record.LogicalRootID = manifest.LogicalRootID
	record.RootGeneration = manifest.RootGeneration
	if manifest.Created <= 0 || manifest.Source == "" || len(manifest.Source) > 1024 {
		record.IntegrityDetail = "snapshot_metadata_invalid"
		return record, manifestInfo.Size()
	}
	record.Integrity = "not_verified"
	record.IntegrityDetail = "checksums_not_checked"
	return record, manifestInfo.Size()
}

func readInventoryManifest(root *os.Root, expected os.FileInfo) (Manifest, error) {
	file, err := root.Open("manifest.json")
	if err != nil {
		return Manifest{}, err
	}
	defer file.Close()
	actual, err := file.Stat()
	if err != nil || !os.SameFile(expected, actual) {
		return Manifest{}, ErrInvalid
	}
	data, err := io.ReadAll(io.LimitReader(file, maxInventoryManifestBytes+1))
	if err != nil {
		return Manifest{}, err
	}
	if int64(len(data)) > maxInventoryManifestBytes {
		return Manifest{}, ErrTooLarge
	}
	if int64(len(data)) != actual.Size() {
		return Manifest{}, ErrInvalid
	}
	var manifest Manifest
	if json.Unmarshal(data, &manifest) != nil {
		return Manifest{}, ErrInvalid
	}
	if err := validateInventoryManifest(manifest); err != nil {
		return Manifest{}, err
	}
	return manifest, nil
}

// Keep manifest checks aligned with parseManifest while reading the manifest
// from an already-open, symlink-checked file descriptor.
func validateInventoryManifest(manifest Manifest) error {
	if manifest.Format != format && manifest.Format != legacyFormat {
		return ErrInvalid
	}
	if manifest.BackupType != "" && manifest.BackupType != MetadataBackupType {
		return ErrInvalid
	}
	if manifest.BackupType == MetadataBackupType && (manifest.Format != format || len(manifest.Files) != 0 || len(manifest.Dirs) != 0 || len(manifest.Metadata) == 0) {
		return ErrInvalid
	}
	if manifest.BackupType == MetadataBackupType && !metadataCatalogHasAccounts(manifest.Metadata) {
		return ErrInvalid
	}
	if len(manifest.Files)+len(manifest.Dirs)+len(manifest.Metadata) > maxFiles {
		return ErrTooLarge
	}
	paths := make(map[string]bool, len(manifest.Files)+len(manifest.Dirs)+len(manifest.Metadata))
	for _, name := range manifest.Dirs {
		if !safeName(name) || paths[name] {
			return ErrInvalid
		}
		paths[name] = true
	}
	var total int64
	for _, entry := range manifest.Files {
		if !safeName(entry.Path) || paths[entry.Path] || entry.Size < 0 || len(entry.SHA256) != 64 {
			return ErrInvalid
		}
		if _, err := hex.DecodeString(entry.SHA256); err != nil {
			return ErrInvalid
		}
		paths[entry.Path] = true
		total += entry.Size
		if total > maxBytes {
			return ErrTooLarge
		}
	}
	if manifest.PlanID != "" && (!validPlanID(manifest.PlanID) || manifest.Format != format) {
		return ErrInvalid
	}
	rootScoped := manifest.LogicalRootID != "" || manifest.RootGeneration != 0
	if rootScoped && (manifest.Format != format || !validMetadataRootID(manifest.LogicalRootID) ||
		manifest.RootGeneration == 0 || !validSourceRootID(manifest.SourceRootID)) {
		return ErrInvalid
	}
	if manifest.SourceRootID != "" &&
		((manifest.PlanID == "" && !rootScoped) || !validSourceRootID(manifest.SourceRootID)) {
		return ErrInvalid
	}
	if len(manifest.Metadata) > maxMetadataEntries {
		return ErrTooLarge
	}
	var metadataTotal int64
	for _, entry := range manifest.Metadata {
		if manifest.Format != format || !syntacticMetadataName(entry.Path) ||
			paths["metadata/"+entry.Path] || entry.Size < 0 ||
			entry.Size > maxBytes || len(entry.SHA256) != 64 {
			return ErrInvalid
		}
		metadataTotal += entry.Size
		if metadataTotal > maxMetadataSnapshotBytes {
			return ErrTooLarge
		}
		if _, err := hex.DecodeString(entry.SHA256); err != nil {
			return ErrInvalid
		}
		paths["metadata/"+entry.Path] = true
	}
	return nil
}

func syntacticMetadataName(name string) bool {
	if _, ok := fixedMetadataTables[name]; ok {
		return true
	}
	if _, ok := rootMetadataTable(name); ok {
		return true
	}
	switch name {
	case "shared-root.json", "shared-roots.json", "backup-schedule.json":
		return true
	default:
		return false
	}
}

func manifestSize(manifest Manifest) int64 {
	var total int64
	for _, entry := range manifest.Files {
		total += entry.Size
	}
	for _, entry := range manifest.Metadata {
		total += entry.Size
	}
	return total
}
