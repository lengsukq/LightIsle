package backup

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

// NewForRoot creates a v2 service tied to one registered logical root. New
// remains the legacy v1 entry point so single-root schedules keep their
// existing manifest and retention semantics.
func NewForRoot(manager *files.Manager, dataDir string, record roots.Root, registry *roots.Registry) (*Service, error) {
	if manager == nil || registry == nil || dataDir == "" || !validMetadataRootID(record.ID) ||
		record.Generation == 0 || record.Pending || record.Binding.Validate() != nil || record.Path != record.Binding.Path {
		return nil, ErrInvalid
	}
	resolvedData, err := filepath.EvalSymlinks(dataDir)
	if err != nil || resolvedData != filepath.Clean(dataDir) {
		return nil, ErrInvalid
	}
	service := New(manager, resolvedData)
	service.rootRegistry = registry
	service.rootRecord = record
	lease, err := service.acquireBoundRoot(context.Background())
	if err != nil {
		service.Close()
		return nil, err
	}
	defer lease.Close()
	if err := service.validateBoundRoot(context.Background(), lease); err != nil {
		service.Close()
		return nil, err
	}
	return service, nil
}

// ProtectDestinations adds a destination-only guard to a legacy v1 service.
// It deliberately does not turn that service into a root-scoped v2 service.
// Install it before starting jobs; the guard rechecks every destination at
// operation start and immediately before publishing output.
func (s *Service) ProtectDestinations(registry *roots.Registry) error {
	if registry == nil {
		return ErrInvalid
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.status.Running {
		return ErrBusy
	}
	if s.rootRegistry != nil && s.rootRegistry != registry {
		return ErrInvalid
	}
	s.protectedRegistry = registry
	return nil
}

// CheckDestination canonicalizes a backup destination and applies any
// installed root/data-directory protection policy. It is safe to call from
// native root-registration flows before changing the registry.
func (s *Service) CheckDestination(folder string) (string, error) {
	resolved, err := authorizedFolder(folder)
	if err != nil {
		return "", err
	}
	if s.destinationRegistry() != nil {
		if err := s.ensureExternalFolderDisjoint(resolved); err != nil {
			return "", err
		}
	}
	return resolved, nil
}

func (s *Service) destinationRegistry() *roots.Registry {
	if s.rootRegistry != nil {
		return s.rootRegistry
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.protectedRegistry
}

func (s *Service) acquireBoundRoot(ctx context.Context) (*roots.Lease, error) {
	if s.rootRegistry == nil {
		return nil, ErrInvalid
	}
	lease, err := s.rootRegistry.Acquire(ctx, s.rootRecord.ID)
	if err != nil {
		return nil, errors.Join(ErrRootChanged, err)
	}
	if err := s.validateBoundRoot(ctx, lease); err != nil {
		_ = lease.Close()
		return nil, err
	}
	return lease, nil
}

func sameRootRecord(a, b roots.Root) bool {
	return a.ID == b.ID && a.Path == b.Path && a.Generation == b.Generation &&
		a.Name == b.Name && a.Pending == b.Pending && a.Compatibility == b.Compatibility &&
		storageidentity.Equal(a.Binding, b.Binding)
}

func (s *Service) validateBoundRoot(ctx context.Context, lease *roots.Lease) error {
	if s.rootRegistry == nil || lease == nil || lease.Root == nil ||
		lease.Binding.Path != s.rootRecord.Path || !storageidentity.Equal(lease.Binding, s.rootRecord.Binding) {
		return ErrRootChanged
	}
	var current *roots.Root
	registered := s.rootRegistry.List()
	for i := range registered {
		if registered[i].ID == s.rootRecord.ID {
			current = &registered[i]
			break
		}
	}
	if current == nil || !sameRootRecord(*current, s.rootRecord) || current.Pending || !lease.Valid(ctx) {
		return ErrRootChanged
	}
	managerPath, online := s.files.State()
	if !online || managerPath != s.rootRecord.Path {
		return ErrRootChanged
	}
	managerLocation, err := os.Stat(managerPath)
	if err != nil {
		return ErrRootChanged
	}
	opened, err := lease.Root.Stat(".")
	if err != nil || !os.SameFile(managerLocation, opened) {
		return ErrRootChanged
	}
	if err := s.validateRegisteredRootIDs(registered); err != nil {
		return err
	}
	return nil
}

func (s *Service) validateRegisteredRootIDs(registered []roots.Root) error {
	dataRoot, err := os.OpenRoot(s.dataDir)
	if err != nil {
		return err
	}
	defer dataRoot.Close()
	ids, present, err := readRegisteredRootIDs(dataRoot)
	if err != nil || !present || len(ids) != len(registered) {
		return ErrInvalid
	}
	seen := make(map[string]bool, len(ids))
	for _, id := range ids {
		seen[id] = true
	}
	for _, root := range registered {
		if !seen[root.ID] {
			return ErrRootChanged
		}
	}
	return nil
}

func (s *Service) validateStagedRootCatalog(ctx context.Context, destination *os.Root, stage string, manifest Manifest) error {
	if len(manifest.Metadata) == 0 {
		return ErrInvalid
	}
	staged, err := destination.OpenRoot(stage)
	if err != nil {
		return err
	}
	defer staged.Close()
	if err := s.validateSnapshotRootCatalog(ctx, staged, manifest); err != nil {
		return err
	}
	return nil
}

func (s *Service) validateSnapshotRootCatalog(ctx context.Context, snapshot *os.Root, manifest Manifest) error {
	ids, err := metadataRootIDsFromSnapshot(ctx, snapshot, manifest.Metadata)
	if err != nil || validateMetadataCatalog(manifest.Metadata, ids) != nil {
		return ErrInvalid
	}
	var registryEntry *File
	for i := range manifest.Metadata {
		if manifest.Metadata[i].Path == "shared-roots.json" {
			registryEntry = &manifest.Metadata[i]
			break
		}
	}
	if registryEntry == nil {
		return ErrInvalid
	}
	if err := verifyEntry(ctx, snapshot, filepath.Join("metadata", registryEntry.Path), *registryEntry); err != nil {
		return ErrInvalid
	}
	metadataRoot, err := snapshot.OpenRoot("metadata")
	if err != nil {
		return ErrInvalid
	}
	defer metadataRoot.Close()
	raw, err := readRootFileBounded(metadataRoot, "shared-roots.json", maxRootRegistryBytes)
	if err != nil {
		return ErrInvalid
	}
	var state struct {
		Version int           `json:"version"`
		Roots   *[]roots.Root `json:"roots"`
	}
	if json.Unmarshal(raw, &state) != nil || state.Version != 1 || state.Roots == nil ||
		len(*state.Roots) > maxRegisteredMetadataRoots {
		return ErrInvalid
	}
	seen := make(map[string]bool, len(*state.Roots))
	for _, record := range *state.Roots {
		if !validMetadataRootID(record.ID) || seen[record.ID] || record.Generation == 0 ||
			record.Path == "" || !filepath.IsAbs(record.Path) || filepath.Clean(record.Path) != record.Path ||
			record.Path != record.Binding.Path {
			return ErrInvalid
		}
		if record.Pending {
			if record.Binding.VolumeUUID != "" {
				return ErrInvalid
			}
		} else if record.Binding.Validate() != nil {
			return ErrInvalid
		}
		seen[record.ID] = true
	}
	current := s.rootRegistry.List()
	if len(current) != len(*state.Roots) {
		return ErrRootSnapshotMismatch
	}
	byID := make(map[string]roots.Root, len(current))
	for _, record := range current {
		byID[record.ID] = record
	}
	for _, record := range *state.Roots {
		currentRecord, ok := byID[record.ID]
		if !ok || !sameRootRecord(currentRecord, record) {
			return ErrRootSnapshotMismatch
		}
	}
	return nil
}

func sourceRootIDForBinding(binding storageidentity.Binding) (string, error) {
	if err := binding.Validate(); err != nil || binding.Generation > uint64(^uint32(0)) {
		return "", ErrInvalid
	}
	identity := directoryIdentity{
		ID: fmt.Sprintf("%016x", binding.DirectoryID), BirthSec: binding.BirthSec,
		BirthNsec: binding.BirthNsec, Generation: uint32(binding.Generation),
	}
	value := formatSourceRootID(binding.VolumeUUID, identity)
	if !validSourceRootID(value) {
		return "", ErrInvalid
	}
	return value, nil
}

func (s *Service) validateRootManifest(manifest Manifest, binding storageidentity.Binding) error {
	physicalID, err := sourceRootIDForBinding(binding)
	if err != nil || manifest.LogicalRootID != s.rootRecord.ID ||
		manifest.RootGeneration != s.rootRecord.Generation || manifest.SourceRootID != physicalID {
		return ErrRootSnapshotMismatch
	}
	return nil
}

func (s *Service) validateExternalFolder(ctx context.Context, folder string, opened *os.Root) (string, error) {
	resolved, err := authorizedFolder(folder)
	if err != nil {
		return "", err
	}
	if err := s.ensureExternalFolderDisjoint(resolved); err != nil {
		return "", err
	}
	if opened != nil {
		openedInfo, openErr := opened.Stat(".")
		pathInfo, statErr := os.Stat(resolved)
		if openErr != nil || statErr != nil || !os.SameFile(openedInfo, pathInfo) {
			return "", ErrInvalid
		}
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	return resolved, nil
}

func pathsOverlap(a, b string) bool {
	a, b = filepath.Clean(a), filepath.Clean(b)
	return inside(a, b) || inside(b, a)
}

func (s *Service) ensureExternalFolderDisjoint(folder string) error {
	registry := s.destinationRegistry()
	if registry == nil {
		return nil
	}
	for _, root := range registry.List() {
		if pathsOverlap(folder, root.Path) {
			return ErrRootDestinationOverlap
		}
		if folderInfo, err := os.Stat(folder); err == nil {
			if rootInfo, rootErr := os.Stat(root.Path); rootErr == nil && os.SameFile(folderInfo, rootInfo) {
				return ErrRootDestinationOverlap
			}
		}
	}
	if s.dataDir == "" {
		return nil
	}
	privateDir, err := filepath.EvalSymlinks(s.dataDir)
	if err != nil {
		return ErrInvalid
	}
	if pathsOverlap(folder, privateDir) {
		return ErrPrivateDestinationOverlap
	}
	folderInfo, folderErr := os.Stat(folder)
	privateInfo, privateErr := os.Stat(privateDir)
	if folderErr == nil && privateErr == nil && os.SameFile(folderInfo, privateInfo) {
		return ErrPrivateDestinationOverlap
	}
	return nil
}
