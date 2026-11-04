package downloads

import (
	"context"
	"io"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

// RegistryPublisher is a rootID-backed download publisher. The staging
// journal still records a physical directory binding; no path-only legacy
// share manager can publish into the current NAS folder. Existing unbound
// tasks remain failed for explicit owner recovery.
//
// Publications are limited to the selected default root. A default-root
// change between download creation and publishing fails closed, rather than
// silently inheriting access to another disk.
type RegistryPublisher struct {
	registry *roots.Registry
}

func (p *RegistryPublisher) DownloadRootIdentity() (RootIdentity, error) {
	if p == nil || p.registry == nil {
		return RootIdentity{}, ErrRootUnavailable
	}
	root, ok := p.registry.Default()
	if !ok {
		return RootIdentity{}, ErrRootUnavailable
	}
	binding, err := p.DownloadRootBinding()
	if err != nil {
		return RootIdentity{}, err
	}
	identity := RootIdentity{ID: root.ID, Generation: root.Generation, Binding: binding}
	if !p.RootIdentityCurrent(identity) {
		return RootIdentity{}, ErrRootChanged
	}
	return identity, nil
}

func (p *RegistryPublisher) RootIdentityCurrent(expected RootIdentity) bool {
	if p == nil || p.registry == nil || expected.ID == "" || expected.Generation == 0 {
		return false
	}
	current, ok := p.registry.Default()
	return ok && current.ID == expected.ID &&
		current.Generation == expected.Generation && current.Binding == expected.Binding
}

func (p *RegistryPublisher) pinnedRoot(
	identity RootIdentity,
) (*files.Manager, func(), func() bool, error) {
	if !p.RootIdentityCurrent(identity) {
		return nil, nil, nil, ErrRootChanged
	}
	manager, release, valid, err := p.pinned(identity.Binding)
	if err != nil {
		return nil, nil, nil, err
	}
	if !p.RootIdentityCurrent(identity) {
		release()
		return nil, nil, nil, ErrRootChanged
	}
	return manager, release, func() bool {
		return valid() && p.RootIdentityCurrent(identity)
	}, nil
}

func (p *RegistryPublisher) PublishDownloadRoot(
	identity RootIdentity, target string, source io.Reader, beforeCommit func() error,
) (int64, error) {
	manager, release, valid, err := p.pinnedRoot(identity)
	if err != nil {
		return 0, err
	}
	defer release()
	return manager.PublishDownload(identity.Binding, target, source, func() error {
		if !valid() {
			return ErrRootChanged
		}
		if beforeCommit != nil {
			return beforeCommit()
		}
		return nil
	})
}

func (p *RegistryPublisher) InspectDownloadRoot(
	identity RootIdentity, target string, inspect func(io.Reader, int64) error,
) error {
	manager, release, valid, err := p.pinnedRoot(identity)
	if err != nil {
		return err
	}
	defer release()
	return manager.InspectDownload(identity.Binding, target, func(reader io.Reader, size int64) error {
		if !valid() {
			return ErrRootChanged
		}
		return inspect(reader, size)
	})
}

func NewRegistryPublisher(registry *roots.Registry) *RegistryPublisher {
	return &RegistryPublisher{registry: registry}
}

func (p *RegistryPublisher) DownloadRootBinding() (storageidentity.Binding, error) {
	if p == nil || p.registry == nil {
		return storageidentity.Binding{}, ErrRootUnavailable
	}
	root, ok := p.registry.Default()
	if !ok {
		return storageidentity.Binding{}, ErrRootUnavailable
	}
	lease, err := p.registry.Acquire(context.Background(), root.ID)
	if err != nil {
		return storageidentity.Binding{}, ErrRootUnavailable
	}
	defer lease.Close()
	if !p.selected(root.ID, root.Generation) || !lease.Valid(context.Background()) {
		return storageidentity.Binding{}, ErrRootChanged
	}
	return lease.Binding, nil
}

func (p *RegistryPublisher) selected(rootID string, generation uint64) bool {
	current, ok := p.registry.Default()
	return ok && current.ID == rootID && current.Generation == generation
}

func (p *RegistryPublisher) pinned(
	expected storageidentity.Binding,
) (*files.Manager, func(), func() bool, error) {
	if p == nil || p.registry == nil {
		return nil, nil, nil, ErrRootUnavailable
	}
	selected, ok := p.registry.Default()
	if !ok {
		return nil, nil, nil, ErrRootUnavailable
	}
	if selected.Binding != expected {
		return nil, nil, nil, ErrRootChanged
	}
	lease, err := p.registry.Acquire(context.Background(), selected.ID)
	if err != nil {
		return nil, nil, nil, ErrRootUnavailable
	}
	closeLease := func() { _ = lease.Close() }
	if lease.Binding != expected || !lease.Valid(context.Background()) ||
		!p.selected(selected.ID, selected.Generation) {
		closeLease()
		return nil, nil, nil, ErrRootChanged
	}
	manager, err := files.NewPinnedManager(lease.Root, lease.Binding)
	if err != nil {
		closeLease()
		return nil, nil, nil, ErrRootUnavailable
	}
	release := func() {
		_ = manager.Close()
		closeLease()
	}
	valid := func() bool {
		return p.selected(selected.ID, selected.Generation) && lease.Valid(context.Background())
	}
	return manager, release, valid, nil
}

func (p *RegistryPublisher) PublishDownload(
	expected storageidentity.Binding, target string, source io.Reader, beforeCommit func() error,
) (int64, error) {
	manager, release, valid, err := p.pinned(expected)
	if err != nil {
		return 0, err
	}
	defer release()
	return manager.PublishDownload(expected, target, source, func() error {
		if !valid() {
			return ErrRootChanged
		}
		if beforeCommit != nil {
			return beforeCommit()
		}
		return nil
	})
}

func (p *RegistryPublisher) InspectDownload(
	expected storageidentity.Binding, target string, inspect func(io.Reader, int64) error,
) error {
	manager, release, valid, err := p.pinned(expected)
	if err != nil {
		return err
	}
	defer release()
	return manager.InspectDownload(expected, target, func(reader io.Reader, size int64) error {
		if !valid() {
			return ErrRootChanged
		}
		return inspect(reader, size)
	})
}

var _ Publisher = (*RegistryPublisher)(nil)
var _ RootIdentityPublisher = (*RegistryPublisher)(nil)
