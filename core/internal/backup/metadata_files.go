package backup

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path"
	"strings"
	"syscall"
)

const (
	maxRegisteredMetadataRoots = 16
	maxMetadataEntries         = 55 // seven legacy metadata files plus three databases per root
	maxRollbackMetadataEntries = 64
	maxRollbackStateFiles      = 192 // three names per SQLite database, with room for fixed metadata
	maxMetadataManifestBytes   = 128 << 10
	maxRootRegistryBytes       = 128 << 10
	maxRecoveryJournalBytes    = 256 << 10
	maxMetadataSnapshotBytes   = int64(2) << 30
)

var fixedMetadataTables = map[string]string{
	"accounts.sqlite": "users",
	"gallery.sqlite":  "assets",
	"cinema.sqlite":   "films",
	"tasks.sqlite":    "task_journal",
}

// A standalone settings snapshot must include the account database or it
// cannot restore the NAS owner's identity and permissions.
func metadataCatalogHasAccounts(entries []File) bool {
	for _, entry := range entries {
		if entry.Path == "accounts.sqlite" {
			return true
		}
	}
	return false
}

type metadataRootRegistry struct {
	Version int `json:"version"`
	Roots   *[]struct {
		RootID string `json:"rootID"`
	} `json:"roots"`
}

// readRegisteredRootIDs reads only the bounded registry envelope. Missing is
// a valid legacy state; a malformed registry is never treated as an empty one.
func readRegisteredRootIDs(root *os.Root) ([]string, bool, error) {
	info, err := root.Lstat("shared-roots.json")
	if errors.Is(err, os.ErrNotExist) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	if !info.Mode().IsRegular() {
		return nil, true, ErrInvalid
	}
	raw, err := readRootFileBounded(root, "shared-roots.json", maxRootRegistryBytes)
	if err != nil {
		return nil, true, err
	}
	var registry metadataRootRegistry
	if json.Unmarshal(raw, &registry) != nil || registry.Version != 1 || registry.Roots == nil ||
		len(*registry.Roots) > maxRegisteredMetadataRoots {
		return nil, true, ErrInvalid
	}
	seen := make(map[string]bool, len(*registry.Roots))
	ids := make([]string, 0, len(*registry.Roots))
	for _, root := range *registry.Roots {
		if !validMetadataRootID(root.RootID) || seen[root.RootID] {
			return nil, true, ErrInvalid
		}
		seen[root.RootID] = true
		ids = append(ids, root.RootID)
	}
	return ids, true, nil
}

func readRootFileBounded(root *os.Root, name string, limit int64) ([]byte, error) {
	info, err := root.Lstat(name)
	if err != nil {
		return nil, err
	}
	return readRootFileWithIdentity(root, name, limit, info)
}

func readRootFileWithIdentity(root *os.Root, name string, limit int64, info os.FileInfo) ([]byte, error) {
	if !info.Mode().IsRegular() || info.Size() < 0 || info.Size() > limit {
		return nil, ErrTooLarge
	}
	file, err := openCheckedBackupFile(root, name, info)
	if err != nil {
		return nil, err
	}
	data, readErr := io.ReadAll(io.LimitReader(file, limit+1))
	closeErr := file.Close()
	if readErr != nil {
		return nil, readErr
	}
	if closeErr != nil {
		return nil, closeErr
	}
	if int64(len(data)) > limit {
		return nil, ErrTooLarge
	}
	if int64(len(data)) != info.Size() {
		return nil, ErrInvalid
	}
	return data, nil
}

// A replaced FIFO must not hang backup verification. Read only the same
// regular file whose type and metadata were checked before opening.
func openCheckedBackupFile(root *os.Root, name string, info os.FileInfo) (*os.File, error) {
	if !info.Mode().IsRegular() {
		return nil, ErrInvalid
	}
	file, err := root.OpenFile(name, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	opened, err := file.Stat()
	if err != nil || !opened.Mode().IsRegular() || !os.SameFile(info, opened) {
		file.Close()
		return nil, ErrInvalid
	}
	if opened.Size() != info.Size() {
		file.Close()
		return nil, ErrInvalid
	}
	return file, nil
}

func metadataRootIDsFromSnapshot(ctx context.Context, snapshot *os.Root, entries []File) ([]string, error) {
	for _, entry := range entries {
		if entry.Path != "shared-roots.json" {
			continue
		}
		if err := verifyEntry(ctx, snapshot, path.Join("metadata", entry.Path), entry); err != nil {
			return nil, err
		}
		metadataRoot, err := snapshot.OpenRoot("metadata")
		if err != nil {
			return nil, err
		}
		defer metadataRoot.Close()
		ids, present, err := readRegisteredRootIDs(metadataRoot)
		if err != nil || !present {
			if err == nil {
				err = ErrInvalid
			}
			return nil, err
		}
		return ids, nil
	}
	return nil, nil
}

func validMetadataRootID(id string) bool {
	if len(id) != 32 || strings.ToLower(id) != id {
		return false
	}
	decoded, err := hex.DecodeString(id)
	return err == nil && len(decoded) == 16
}

func rootMetadataName(kind, rootID string) string {
	return kind + "-root-" + rootID + ".sqlite"
}

func rootMetadataTable(name string) (string, bool) {
	for _, kind := range []string{"gallery", "cinema", "tasks"} {
		prefix := kind + "-root-"
		if !strings.HasPrefix(name, prefix) || !strings.HasSuffix(name, ".sqlite") {
			continue
		}
		id := strings.TrimSuffix(strings.TrimPrefix(name, prefix), ".sqlite")
		if validMetadataRootID(id) {
			switch kind {
			case "gallery":
				return "assets", true
			case "cinema":
				return "films", true
			case "tasks":
				return "task_journal", true
			}
		}
	}
	return "", false
}

func metadataNamesForRootIDs(ids []string) []string {
	names := []string{"accounts.sqlite", "gallery.sqlite", "cinema.sqlite", "tasks.sqlite",
		"shared-root.json", "shared-roots.json", "config-backup-schedule.json"}
	for _, id := range ids {
		names = append(names, rootMetadataName("gallery", id), rootMetadataName("cinema", id), rootMetadataName("tasks", id))
	}
	return names
}

func metadataTableForName(name string, registered map[string]bool) (string, bool) {
	if table, ok := fixedMetadataTables[name]; ok {
		return table, true
	}
	if table, ok := rootMetadataTable(name); ok {
		prefix := strings.SplitN(name, "-root-", 2)
		if len(prefix) == 2 {
			id := strings.TrimSuffix(prefix[1], ".sqlite")
			return table, registered[id]
		}
	}
	switch name {
	case "shared-root.json", "shared-roots.json", "config-backup-schedule.json":
		return "", true
	default:
		return "", false
	}
}

func registeredIDSet(ids []string) map[string]bool {
	set := make(map[string]bool, len(ids))
	for _, id := range ids {
		set[id] = true
	}
	return set
}

func validateMetadataCatalog(entries []File, ids []string) error {
	if len(entries) < 1 || len(entries) > maxMetadataEntries || len(ids) > maxRegisteredMetadataRoots {
		return ErrInvalid
	}
	registered := registeredIDSet(ids)
	seen := make(map[string]bool, len(entries))
	var total int64
	for _, entry := range entries {
		if _, ok := metadataTableForName(entry.Path, registered); !ok || seen[entry.Path] ||
			entry.Size < 0 || entry.Size > maxBytes || len(entry.SHA256) != 64 || !validSHA256(entry.SHA256) {
			return ErrInvalid
		}
		seen[entry.Path] = true
		total += entry.Size
		if total > maxMetadataSnapshotBytes {
			return ErrTooLarge
		}
	}
	return nil
}
