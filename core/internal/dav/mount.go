package dav

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"os"
	"path"
	"strconv"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/roots"
)

const defaultDAVPrefix = "/dav/"
const registeredDAVPrefix = "/dav-roots/"

type davMount struct {
	prefix string
	root   roots.Root
}

func (m davMount) relative(urlPath string) string {
	prefix := m.prefix
	if prefix == "" {
		prefix = defaultDAVPrefix
	}
	return strings.TrimPrefix(urlPath, prefix)
}

func (m davMount) destination(r *http.Request) (string, error) {
	target, err := url.Parse(r.Header.Get("Destination"))
	if err != nil || target.User != nil || target.RawQuery != "" || target.Fragment != "" ||
		(target.Scheme != "" && target.Scheme != "http" && target.Scheme != "https") ||
		(target.Host != "" && !strings.EqualFold(target.Host, r.Host)) ||
		!strings.HasPrefix(target.Path, m.prefix) {
		return "", os.ErrInvalid
	}
	return normalizeDAVName(m.relative(target.Path))
}

func (s *Service) selectMount(r *http.Request, user auth.User) (davMount, error) {
	if s.registry == nil {
		return davMount{prefix: defaultDAVPrefix}, nil
	}
	mount := davMount{prefix: defaultDAVPrefix}
	if strings.HasPrefix(r.URL.Path, defaultDAVPrefix) || r.URL.Path == "/dav" {
		root, err := s.registry.LegacyDAV()
		if err != nil {
			return davMount{}, err
		}
		mount.root = root
	} else {
		relative, ok := strings.CutPrefix(r.URL.Path, registeredDAVPrefix)
		id, suffix, separator := strings.Cut(relative, "/")
		generationText, _, slash := strings.Cut(suffix, "/")
		generation, err := strconv.ParseUint(generationText, 10, 64)
		if !ok || !separator || !slash || err != nil || generation == 0 ||
			strconv.FormatUint(generation, 10) != generationText {
			return davMount{}, roots.ErrMissing
		}
		root, found := s.registry.Lookup(id)
		if !found || !s.store.CanAccessRootForUser(user.ID, id, ".", false, true) {
			return davMount{}, roots.ErrMissing
		}
		if root.Generation != generation {
			return davMount{}, roots.ErrStale
		}
		mount.root = root
		mount.prefix = registeredDAVPrefix + id + "/" + generationText + "/"
	}
	return mount, nil
}

func writeMountError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, roots.ErrMissing):
		jsonError(w, http.StatusNotFound, "dav_mount_not_found")
	case errors.Is(err, roots.ErrStale):
		jsonError(w, http.StatusConflict, "dav_remount_required")
	default:
		jsonError(w, http.StatusServiceUnavailable, "share_root_offline")
	}
}

func mutationDirectories(method, source, destination string) []string {
	switch method {
	case http.MethodPut, http.MethodDelete, "MKCOL":
		return []string{path.Dir(strings.TrimSuffix(source, "/"))}
	case "COPY":
		return []string{path.Dir(destination)}
	case "MOVE":
		from, to := path.Dir(strings.TrimSuffix(source, "/")), path.Dir(destination)
		if from != to {
			return []string{from, to}
		}
		return []string{to}
	}
	return nil
}

func (s *Service) openRequestRoot(ctx context.Context, mount davMount) (*rootHandle, error) {
	if s.registry != nil {
		selected := mount.root
		lease, err := s.registry.Acquire(ctx, selected.ID)
		if err != nil {
			return nil, ErrUnavailable
		}
		if lease.Binding != selected.Binding {
			_ = lease.Close()
			return nil, ErrUnavailable
		}
		pinned, err := files.NewPinnedManager(lease.Root, lease.Binding)
		if err != nil {
			_ = lease.Close()
			return nil, ErrUnavailable
		}
		davLease, err := pinned.AcquireDAVRootLease()
		if err != nil {
			_ = pinned.Close()
			_ = lease.Close()
			return nil, ErrUnavailable
		}
		current := func() bool {
			active, ok := s.registry.Lookup(selected.ID)
			if !ok || active.Generation != selected.Generation {
				return false
			}
			if mount.prefix == defaultDAVPrefix {
				active, err := s.registry.LegacyDAV()
				if err != nil || active.ID != selected.ID || active.Generation != selected.Generation {
					return false
				}
			}
			return lease.Valid(context.Background()) && davLease.IsCurrent()
		}
		if !current() {
			_ = davLease.Close()
			_ = pinned.Close()
			_ = lease.Close()
			return nil, ErrUnavailable
		}
		return &rootHandle{
			rootID: selected.ID, generation: selected.Generation, path: selected.Path,
			file: davLease.Root, rootFS: lease.Root, info: davLease.Info,
			validate: current, trash: davLease.MoveToTrash, replace: davLease.ReplaceFile,
			release: func() {
				_ = davLease.Close()
				_ = pinned.Close()
				_ = lease.Close()
			},
		}, nil
	}
	if s.lease != nil {
		lease, err := s.lease()
		if err != nil || lease == nil || lease.Root == nil || !lease.IsCurrent() {
			if lease != nil {
				_ = lease.Close()
			}
			return nil, ErrUnavailable
		}
		return &rootHandle{
			path:     lease.Path,
			file:     lease.Root,
			info:     lease.Info,
			validate: lease.IsCurrent,
			trash:    lease.MoveToTrash,
			release:  func() { _ = lease.Close() },
		}, nil
	}
	if s.root == nil {
		return nil, ErrUnavailable
	}
	rootPath, online := s.root()
	if !online {
		return nil, ErrUnavailable
	}
	rootFile, err := openRootDirectory(rootPath)
	if err != nil {
		return nil, err
	}
	info, err := rootFile.Stat()
	if err != nil {
		rootFile.Close()
		return nil, err
	}
	root := &rootHandle{path: rootPath, file: rootFile, info: info}
	root.validate = func() bool {
		currentPath, currentOnline := s.root()
		if !currentOnline || currentPath != rootPath {
			return false
		}
		current, openErr := openRootDirectory(rootPath)
		if openErr != nil {
			return false
		}
		defer current.Close()
		currentInfo, statErr := current.Stat()
		return statErr == nil && sameIdentity(info, currentInfo)
	}
	if !root.current() {
		root.close()
		return nil, ErrUnavailable
	}
	return root, nil
}

// x/net recursively copies directories and may remove an existing target
// before traversing. Reject either direction of overlap before dispatch.
func overlappingDAVPaths(root *os.File, fromPath, toPath string) bool {
	from, fromErr := normalizeDAVName(fromPath)
	to, toErr := normalizeDAVName(toPath)
	if fromErr != nil || toErr != nil {
		return false
	}
	if from == "." || to == "." {
		return true
	}
	sourceParts, targetParts := strings.Split(from, "/"), strings.Split(to, "/")
	depth := min(len(sourceParts), len(targetParts))
	sourcePrefix, targetPrefix := strings.Join(sourceParts[:depth], "/"), strings.Join(targetParts[:depth], "/")
	if strings.EqualFold(sourcePrefix, targetPrefix) {
		return true
	}
	// APFS can resolve differently normalized Unicode names to the same
	// directory. Compare identities as well as the request spelling.
	source, sourceErr := secureStat(root, sourcePrefix)
	target, targetErr := secureStat(root, targetPrefix)
	return sourceErr == nil && targetErr == nil && sameIdentity(source, target)
}
