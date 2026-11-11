package dav

import (
	"bytes"
	"context"
	"errors"
	"io/fs"
	"net/http"
	"os"
	"path"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
	"golang.org/x/net/webdav"
)

// Run the protocol's recursive COPY against a hidden sibling directory. The
// requested destination does not appear until all files and reservations are
// ready. Keep any accepted DAV lock held through the final publication.
func serveDirectoryCopy(w http.ResponseWriter, r *http.Request, handler *webdav.Handler, state *requestState, target string) bool {
	if state.method != "COPY" || state.root.rootFS == nil {
		return false
	}
	base := &grantedFS{service: state.service}
	_, source, err := base.authorize(r.Context(), state.mount.relative(r.URL.Path), false)
	if err != nil {
		return false
	}
	info, err := secureStat(state.root.file, source)
	if err != nil || !info.IsDir() {
		return false
	}
	if !state.service.canAccess(state, source, false, false) {
		jsonError(w, http.StatusForbidden, "dav_access_denied")
		return true
	}
	tree := &directoryCopy{grantedFS: base, state: state, source: source, target: target}
	var unlocks []func()
	state.copyUnlocks = &unlocks
	defer func() {
		state.copyUnlocks = nil
		for _, unlock := range unlocks {
			unlock()
		}
		tree.close()
	}()
	handler.FileSystem = tree
	response := &copyResponse{header: make(http.Header)}
	handler.ServeHTTP(response, r)
	if response.status < 200 || response.status >= 300 {
		for name, values := range response.header {
			w.Header()[name] = values
		}
		w.WriteHeader(response.status)
		_, _ = w.Write(response.body.Bytes())
		return true
	}
	if err := tree.publish(); err != nil {
		if errors.Is(err, fs.ErrExist) {
			jsonError(w, http.StatusPreconditionFailed, "dav_destination_exists")
		} else if tree.published {
			jsonError(w, http.StatusInternalServerError, "storage_accounting_uncertain")
		} else {
			jsonError(w, http.StatusConflict, "dav_copy_unavailable")
		}
		return true
	}
	w.WriteHeader(http.StatusCreated)
	return true
}

type copyResponse struct {
	header http.Header
	status int
	body   bytes.Buffer
}

func (w *copyResponse) Header() http.Header    { return w.header }
func (w *copyResponse) WriteHeader(status int) { w.status = status }
func (w *copyResponse) Write(p []byte) (int, error) {
	if w.body.Len()+len(p) > 4096 {
		return 0, fs.ErrInvalid
	}
	return w.body.Write(p)
}

type directoryCopy struct {
	*grantedFS
	state      *requestState
	source     string
	target     string
	stage      string
	stageInfo  os.FileInfo
	parentInfo os.FileInfo
	dirs       []string
	files      []*directoryCopyFile
	published  bool
}

func (t *directoryCopy) destination(name string) (string, bool) {
	if name == t.target {
		return t.stage, true
	}
	if child, ok := strings.CutPrefix(name, t.target+"/"); ok {
		return path.Join(t.stage, child), true
	}
	return "", false
}

func (t *directoryCopy) Stat(ctx context.Context, raw string) (os.FileInfo, error) {
	_, name, err := t.authorize(ctx, raw, false)
	if err != nil {
		return nil, err
	}
	staged, target := t.destination(name)
	if !target || t.stage == "" {
		return t.grantedFS.Stat(ctx, raw)
	}
	return secureStat(t.state.root.file, staged)
}

func (t *directoryCopy) Mkdir(ctx context.Context, raw string, _ os.FileMode) error {
	_, name, err := t.authorize(ctx, raw, true)
	if err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if name == t.target && t.stage == "" {
		parent, _, err := openParentNoFollow(t.state.root.file, name)
		if err != nil {
			return err
		}
		defer parent.Close()
		parentInfo, err := parent.Stat()
		if err != nil {
			return err
		}
		staging, err := randomDAVName()
		if err != nil {
			return err
		}
		if err := mkdirAt(parent, staging, 0700); err != nil {
			return err
		}
		info, err := statAtNoFollow(parent, staging)
		if err != nil {
			_ = unlinkAt(parent, staging, true)
			return err
		}
		t.stage = path.Join(path.Dir(name), staging)
		t.stageInfo, t.parentInfo = info, parentInfo
		t.dirs = append(t.dirs, name)
		return nil
	}
	staged, ok := t.destination(name)
	if !ok || t.stage == "" {
		return os.ErrPermission
	}
	parent, leaf, err := openParentNoFollow(t.state.root.file, staged)
	if err != nil {
		return err
	}
	defer parent.Close()
	if err := mkdirAt(parent, leaf, 0700); err != nil {
		return err
	}
	t.dirs = append(t.dirs, name)
	return nil
}

func (t *directoryCopy) OpenFile(ctx context.Context, raw string, flag int, perm os.FileMode) (webdav.File, error) {
	write := flag&(os.O_WRONLY|os.O_RDWR|os.O_APPEND|os.O_CREATE|os.O_TRUNC) != 0
	if !write {
		_, name, err := t.authorize(ctx, raw, false)
		if err != nil || !t.service.canAccess(t.state, name, false, false) {
			return nil, os.ErrPermission
		}
		return t.grantedFS.OpenFile(ctx, name, flag, perm)
	}
	_, name, err := t.authorize(ctx, raw, true)
	if err != nil {
		return nil, err
	}
	staged, ok := t.destination(name)
	source := t.state.currentCopy
	if !ok || t.stage == "" || source == nil || source.info == nil || !source.info.Mode().IsRegular() {
		return nil, os.ErrPermission
	}
	reservation, _, err := reservePersonalPut(t.state, name, nil)
	if err != nil {
		return nil, err
	}
	file := &directoryCopyFile{
		writeTxn: writeTxn{state: t.state, copyReadCount: t.state.copyCount()},
		source:   source.name, target: name, sourceInfo: source.info, reservation: reservation,
	}
	t.files = append(t.files, file)
	parent, leaf, err := openParentNoFollow(t.state.root.file, staged)
	if err != nil {
		return nil, err
	}
	defer parent.Close()
	fd, err := unixOpenAtStage(parent, leaf)
	if err != nil {
		return nil, err
	}
	file.stage = os.NewFile(fd, staged)
	return file, nil
}

type directoryCopyFile struct {
	writeTxn
	source, target, reservation string
	sourceInfo, resultInfo      os.FileInfo
}

func (f *directoryCopyFile) Close() (err error) {
	defer func() {
		err = errors.Join(err, f.stage.Close())
		f.stage = nil
	}()
	if f.writeErr != nil || !f.state.copyComplete(f.copyReadCount) {
		return errResourceChanged
	}
	info, err := f.stage.Stat()
	if err != nil || info.Size() != f.sourceInfo.Size() || !files.MediaFileHasSingleLink(info) {
		return errResourceChanged
	}
	if err := syncRegular(f.stage); err != nil {
		return err
	}
	f.resultInfo = info
	return nil
}

func (t *directoryCopy) publish() error {
	root := t.state.root
	if t.stage == "" || !root.current() || t.state.ctx.Err() != nil {
		return errResourceChanged
	}
	entries := make([]auth.StoragePublication, 0, len(t.files))
	for _, file := range t.files {
		source, err := secureStat(root.file, file.source)
		if err != nil || !sameFileVersion(source, file.sourceInfo) ||
			!t.service.canAccess(t.state, file.source, false, false) {
			return errResourceChanged
		}
		staged, _ := t.destination(file.target)
		info, err := secureStat(root.file, staged)
		if err != nil || !sameFileVersion(info, file.resultInfo) || !files.MediaFileHasSingleLink(info) {
			return errResourceChanged
		}
		if _, _, err := t.authorize(t.state.ctx, file.target, true); err != nil {
			return err
		}
		if file.reservation != "" {
			identity := files.MediaFileIdentity(info)
			if identity == "" {
				return errResourceChanged
			}
			entries = append(entries, auth.StoragePublication{ReservationID: file.reservation, Identity: identity})
		}
	}
	for i := len(t.dirs) - 1; i >= 0; i-- {
		name := t.dirs[i]
		if _, _, err := t.authorize(t.state.ctx, name, true); err != nil {
			return err
		}
		staged, _ := t.destination(name)
		dir, err := openDirectoryNoFollow(root.file, staged)
		if err != nil {
			return err
		}
		err = syncDirectory(dir)
		_ = dir.Close()
		if err != nil {
			return err
		}
	}
	parent, leaf, err := openParentNoFollow(root.file, t.target)
	if err != nil {
		return err
	}
	defer parent.Close()
	if !root.current() || t.state.ctx.Err() != nil || !sameDirectory(root.file, path.Dir(t.target), t.parentInfo) ||
		!sameIdentity(mustStat(parent), t.parentInfo) || !sameDirectory(root.file, t.stage, t.stageInfo) {
		return errResourceChanged
	}
	if err := t.service.store.PrepareStoragePublications("dav_copy", entries); err != nil {
		return err
	}
	if !root.current() || t.state.ctx.Err() != nil {
		return errResourceChanged
	}
	if err := renameAtNoReplace(parent, path.Base(t.stage), parent, leaf); err != nil {
		return err
	}
	t.published = true
	if err := syncDirectory(parent); err != nil {
		return err
	}
	if !root.current() || !sameDirectory(root.file, t.target, t.stageInfo) {
		return errResourceChanged
	}
	for _, file := range t.files {
		info, err := secureStat(root.file, file.target)
		if err != nil || !sameIdentity(info, file.resultInfo) || !files.MediaFileHasSingleLink(info) {
			return errResourceChanged
		}
	}
	return t.service.store.CommitStoragePublications(entries)
}

func (t *directoryCopy) close() {
	if t.published {
		return
	}
	if t.stage != "" {
		if !t.state.root.current() || !sameDirectory(t.state.root.file, t.stage, t.stageInfo) ||
			t.state.root.rootFS.RemoveAll(t.stage) != nil {
			return
		}
	}
	for _, file := range t.files {
		if file.reservation != "" {
			_ = t.service.store.ReleaseStorageReservation(file.reservation)
		}
	}
}
