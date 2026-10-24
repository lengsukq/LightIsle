package dav

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"syscall"

	"golang.org/x/net/webdav"

	"github.com/lengsukq/lightisle/core/internal/auth"
)

// writeReserve keeps WebDAV writes from running a volume to zero bytes, the
// same discipline as the resumable HTTP uploader.
const writeReserve = 64 << 20

// grantedFS delegates real filesystem work to webdav.Dir rooted at the
// current share root, after authorizing the request against the same
// per-user directory grants the web API enforces. DELETE is reinterpreted as
// "move to application trash" so WebDAV can never permanently destroy data.
type grantedFS struct {
	service *Service
}

func (f *grantedFS) inner() (webdav.Dir, error) {
	root, online := f.service.root()
	if !online {
		return "", ErrUnavailable
	}
	return webdav.Dir(root), nil
}

// authorize resolves the share root and checks grants for a webdav name.
func (f *grantedFS) authorize(ctx context.Context, name string, write bool) (webdav.Dir, error) {
	user, ok := userFrom(ctx)
	if !ok {
		return "", os.ErrPermission
	}
	dir, err := f.inner()
	if err != nil {
		return "", err
	}
	// Listing (read) may traverse ancestors of a granted subtree; writes never
	// do. Invalid names — including ".lightisle-" internals — fail the check.
	if !f.service.store.CanAccessForUser(user.ID, relativePath(name), write, !write) {
		return "", os.ErrPermission
	}
	return dir, nil
}

func (f *grantedFS) Mkdir(ctx context.Context, name string, perm os.FileMode) error {
	// The created directory is the write target: a member may create exactly
	// the granted subtree root, nothing above or beside it.
	dir, err := f.authorize(ctx, name, true)
	if err != nil {
		return err
	}
	return dir.Mkdir(ctx, name, perm)
}

func (f *grantedFS) OpenFile(ctx context.Context, name string, flag int, perm os.FileMode) (webdav.File, error) {
	write := flag&(os.O_WRONLY|os.O_RDWR|os.O_APPEND|os.O_CREATE|os.O_TRUNC) != 0
	dir, err := f.authorize(ctx, name, write)
	if err != nil {
		return nil, err
	}
	if write {
		if err := f.service.checkSpace(); err != nil {
			slog.Warn("dav write rejected", "name", name, "error", err)
			return nil, err
		}
		return dir.OpenFile(ctx, name, flag, perm)
	}
	file, err := dir.OpenFile(ctx, name, flag, perm)
	if err != nil {
		return nil, err
	}
	if info, statErr := file.Stat(); statErr == nil && info.IsDir() {
		// Members may traverse ancestors of a granted subtree, but the web
		// file API never shows them sibling entries. Directory listings get
		// the same per-entry filter so PROPFIND cannot leak other names.
		if user, ok := userFrom(ctx); ok && user.Role != auth.RoleAdmin {
			return &filteredDir{File: file, fs: f, user: user, name: name}, nil
		}
	}
	return file, nil
}

// RemoveAll serves DELETE and MOVE-overwrite by trashing the target through
// the application trash, never by unlinking it permanently.
func (f *grantedFS) RemoveAll(ctx context.Context, name string) error {
	if relativePath(name) == "." {
		return os.ErrPermission
	}
	if _, err := f.authorize(ctx, name, true); err != nil {
		return err
	}
	if f.service.trash == nil {
		return os.ErrPermission
	}
	return f.service.trash(relativePath(name))
}

func (f *grantedFS) Rename(ctx context.Context, oldName, newName string) error {
	dir, err := f.authorize(ctx, oldName, true)
	if err != nil {
		return err
	}
	if _, err := f.authorize(ctx, newName, true); err != nil {
		return err
	}
	return dir.Rename(ctx, oldName, newName)
}

func (f *grantedFS) Stat(ctx context.Context, name string) (os.FileInfo, error) {
	dir, err := f.authorize(ctx, name, false)
	if err != nil {
		return nil, err
	}
	return dir.Stat(ctx, name)
}

// checkSpace refuses writes when the share root volume is within the write
// reserve of being full. A failed probe must not block the write: diskfull
// conditions still surface through the OS on the actual write.
func (s *Service) checkSpace() error {
	root, online := s.root()
	if !online {
		return ErrUnavailable
	}
	var stat syscall.Statfs_t
	if err := syscall.Statfs(root, &stat); err != nil {
		return nil
	}
	free := uint64(stat.Bavail) * uint64(stat.Bsize)
	if free < writeReserve {
		return errors.New("insufficient storage space")
	}
	return nil
}

var _ webdav.FileSystem = (*grantedFS)(nil)

// filteredDir hides directory entries the account cannot see, mirroring the
// web list handler's per-entry canSee filter.
type filteredDir struct {
	webdav.File
	fs   *grantedFS
	user auth.User
	name string
}

func (d *filteredDir) Readdir(count int) ([]os.FileInfo, error) {
	entries, err := d.File.Readdir(count)
	if err != nil {
		return nil, err
	}
	visible := entries[:0]
	for _, entry := range entries {
		child := d.name + "/" + entry.Name()
		if d.fs.service.store.CanAccessForUser(d.user.ID, relativePath(child), false, true) {
			visible = append(visible, entry)
		}
	}
	return visible, nil
}

var _ webdav.File = (*filteredDir)(nil)
