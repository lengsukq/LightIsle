package backup

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path"
	"path/filepath"
	"time"
)

// Restore only application settings from a validated, already-open snapshot.
func (s *Service) StartMetadataRestore(snapshot string) error {
	if s.dataDir == "" {
		return ErrInvalid
	}
	if s.destinationRegistry() != nil {
		resolved, err := s.CheckDestination(snapshot)
		if err != nil {
			return err
		}
		snapshot = resolved
	}
	return s.start("restore", snapshot, func(ctx context.Context, destination string) (string, error) {
		return s.restoreMetadataOnly(ctx, destination)
	})
}

func parseManifest(root *os.Root) (Manifest, error) {
	data, err := readRootFileBounded(root, "manifest.json", maxManifest)
	if err != nil {
		return Manifest{}, err
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

// Verify and stage application metadata. Never replace a live SQLite database;
// recovered accounts and settings require an explicit, offline migration.
func (s *Service) restoreMetadata(ctx context.Context, input *os.Root, manifest Manifest, suffix string) (string, error) {
	if len(manifest.Metadata) == 0 || s.dataDir == "" {
		return "", nil
	}
	ids, err := metadataRootIDsFromSnapshot(ctx, input, manifest.Metadata)
	if err != nil {
		return "", err
	}
	if err := validateMetadataCatalog(manifest.Metadata, ids); err != nil {
		return "", err
	}
	root, err := os.OpenRoot(s.dataDir)
	if err != nil {
		return "", err
	}
	defer root.Close()
	stage := ".lightisle-metadata-" + suffix + ".partial"
	final := "LightIsle-RestoredMetadata-" + suffix
	if err = root.Mkdir(stage, 0700); err != nil {
		return "", err
	}
	defer root.RemoveAll(stage)
	for _, entry := range manifest.Metadata {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		in, err := input.Open(path.Join("metadata", entry.Path))
		if err != nil {
			return "", err
		}
		out, err := root.OpenFile(path.Join(stage, entry.Path), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			in.Close()
			return "", err
		}
		hash, copyErr := boundedCopy(ctx, out, in, entry.Size)
		closeErr := out.Close()
		in.Close()
		if copyErr != nil {
			return "", copyErr
		}
		if closeErr != nil {
			return "", closeErr
		}
		if hash != entry.SHA256 {
			return "", errors.New("metadata_checksum_mismatch")
		}
	}
	stagedRoot, err := root.OpenRoot(stage)
	if err != nil {
		return "", err
	}
	defer stagedRoot.Close()
	for i, entry := range manifest.Metadata {
		if entry.Path != "accounts.sqlite" {
			continue
		}
		if err := clearTransientCapabilities(ctx, filepath.Join(root.Name(), stage, entry.Path)); err != nil {
			return "", err
		}
		sha, size, err := hashRootFile(stagedRoot, entry.Path, maxBytes)
		if err != nil {
			return "", err
		}
		manifest.Metadata[i].SHA256 = sha
		manifest.Metadata[i].Size = size
	}
	if err := validateMetadataCatalog(manifest.Metadata, ids); err != nil {
		return "", err
	}
	// Retain per-file checksums in the isolated recovery directory. The
	// offline activation helper must revalidate these before touching any
	// running application's metadata.
	metadataManifest, err := json.Marshal(manifest.Metadata)
	if err != nil {
		return "", err
	}
	manifestFile, err := root.OpenFile(path.Join(stage, "metadata-manifest.json"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return "", err
	}
	_, err = manifestFile.Write(metadataManifest)
	if err == nil {
		err = manifestFile.Sync()
	}
	closeErr := manifestFile.Close()
	if err != nil {
		return "", err
	}
	if closeErr != nil {
		return "", closeErr
	}
	if err = root.Rename(stage, final); err != nil {
		return "", err
	}
	return filepath.Join(s.dataDir, final), nil
}

func (s *Service) restoreMetadataOnly(ctx context.Context, snapshot string) (string, error) {
	if s.dataDir == "" || (s.files == nil && s.protectedRegistry == nil) {
		return "", ErrInvalid
	}
	source, online := s.metadataSource()
	if !online {
		return "", ErrOffline
	}
	location, err := s.CheckDestination(snapshot)
	if err != nil {
		return "", err
	}
	if err := disjoint(source, location); err != nil {
		return "", err
	}
	input, err := os.OpenRoot(location)
	if err != nil {
		return "", err
	}
	defer input.Close()
	if s.destinationRegistry() != nil {
		if _, err := s.validateExternalFolder(ctx, location, input); err != nil {
			return "", err
		}
	}
	manifest, err := parseManifest(input)
	if err != nil {
		return "", err
	}
	if manifest.BackupType != MetadataBackupType || manifest.Format != format ||
		len(manifest.Files) != 0 || len(manifest.Dirs) != 0 || !metadataCatalogHasAccounts(manifest.Metadata) {
		return "", ErrInvalid
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if current, ok := s.metadataSource(); !ok || current != source {
		return "", ErrOffline
	}
	suffix := time.Now().UTC().Format("20060102-150405") + "-" + id()
	locationSaved, err := s.restoreMetadata(ctx, input, manifest, suffix)
	if err != nil {
		return "", err
	}
	if locationSaved == "" {
		return "", ErrInvalid
	}
	s.mu.Lock()
	s.status.RestoredMetadata = locationSaved
	s.mu.Unlock()
	return locationSaved, nil
}
