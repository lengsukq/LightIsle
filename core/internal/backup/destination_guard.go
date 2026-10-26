package backup

import (
	"context"
	"os"
	"path/filepath"

	"github.com/lengsukq/lightisle/core/internal/roots"
)

// ProtectDestinations prevents configuration backups from being written into
// NAS data roots or the app's live SQLite directory.
func (s *Service) ProtectDestinations(registry *roots.Registry) error {
	if registry == nil {
		return ErrInvalid
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.status.Running {
		return ErrBusy
	}
	s.protectedRegistry = registry
	return nil
}

func (s *Service) CheckDestination(folder string) (string, error) {
	resolved, err := authorizedFolder(folder)
	if err != nil {
		return "", err
	}
	if err := s.ensureExternalFolderDisjoint(resolved); err != nil {
		return "", err
	}
	return resolved, nil
}

func (s *Service) destinationRegistry() *roots.Registry {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.protectedRegistry
}

// Check the opened directory against its current path before and after
// snapshot work. A swapped symlink must never redirect the backup.
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
		currentInfo, statErr := os.Stat(resolved)
		if openErr != nil || statErr != nil || !os.SameFile(openedInfo, currentInfo) {
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
	if registry := s.destinationRegistry(); registry != nil {
		for _, root := range registry.List() {
			if pathsOverlap(folder, root.Path) {
				return ErrRootDestinationOverlap
			}
			if fi, e := os.Stat(folder); e == nil {
				if rootInfo, err := os.Stat(root.Path); err == nil && os.SameFile(fi, rootInfo) {
					return ErrRootDestinationOverlap
				}
			}
		}
	}
	if s.dataDir == "" {
		return nil
	}
	private, err := filepath.EvalSymlinks(s.dataDir)
	if err != nil {
		return ErrInvalid
	}
	if pathsOverlap(folder, private) {
		return ErrPrivateDestinationOverlap
	}
	current, ce := os.Stat(folder)
	privateInfo, pe := os.Stat(private)
	if ce == nil && pe == nil && os.SameFile(current, privateInfo) {
		return ErrPrivateDestinationOverlap
	}
	return nil
}
