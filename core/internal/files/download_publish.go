package files

import (
	"errors"
	"io"
	"os"
	"path"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

var (
	ErrDownloadRootUnavailable = errors.New("download_root_unavailable")
	ErrDownloadRootChanged     = errors.New("download_root_changed")
)

// DownloadRootBinding returns the identity of the currently online share.
// Download tasks persist this exact value; a later share selection does not
// transfer a task's write authorization to the newly selected volume.
func (m *Manager) DownloadRootBinding() (storageidentity.Binding, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if m.binding == nil || !m.onlineLocked() {
		return storageidentity.Binding{}, ErrDownloadRootUnavailable
	}
	binding := *m.binding
	if binding.Validate() != nil {
		return storageidentity.Binding{}, ErrDownloadRootUnavailable
	}
	return binding, nil
}

// PublishDownload holds the share-root read lock from identity validation
// through the complete exclusive, durable upload. beforeCommit is called only
// after source has been read to EOF, immediately before Store.Upload publishes
// its no-replace link. Callers use it to re-check authorization and context.
func (m *Manager) PublishDownload(
	expected storageidentity.Binding,
	target string,
	source io.Reader,
	beforeCommit func() error,
) (int64, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if err := m.checkDownloadBindingLocked(expected); err != nil {
		return 0, err
	}
	if source == nil {
		return 0, ErrPath
	}
	if err := ensureDownloadParents(m.store, target); err != nil {
		return 0, err
	}
	checkedTarget, err := m.store.safePath(target, false, true)
	if err != nil {
		return 0, err
	}
	// Local staged bytes bypass the HTTP request cap: a finished multi-gigabyte
	// download must publish, while each file was already checked against the
	// download task ceiling before this call.
	return m.store.PublishLocal(checkedTarget, &downloadCommitReader{source: source, beforeCommit: beforeCommit})
}

// InspectDownload securely opens a regular share file under the expected root
// and keeps root switching blocked until inspect returns. A missing file is
// returned as os.ErrNotExist so callers can safely retry the journaled target.
func (m *Manager) InspectDownload(
	expected storageidentity.Binding,
	target string,
	inspect func(io.Reader, int64) error,
) error {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if err := m.checkDownloadBindingLocked(expected); err != nil {
		return err
	}
	if inspect == nil {
		return ErrPath
	}
	file, info, err := m.store.Read(target)
	if err != nil {
		return err
	}
	defer file.Close()
	return inspect(file, info.Size())
}

func (m *Manager) checkDownloadBindingLocked(expected storageidentity.Binding) error {
	if expected.Validate() != nil {
		return ErrDownloadRootChanged
	}
	if m.binding == nil {
		return ErrDownloadRootUnavailable
	}
	if *m.binding != expected {
		return ErrDownloadRootChanged
	}
	if !m.onlineLocked() {
		return ErrDownloadRootUnavailable
	}
	return nil
}

func ensureDownloadParents(store *Store, target string) error {
	clean, err := validate(target, false)
	if err != nil {
		return err
	}
	parent := path.Dir(clean)
	if parent == "." {
		return nil
	}
	var current strings.Builder
	for _, segment := range strings.Split(parent, "/") {
		if current.Len() > 0 {
			current.WriteByte('/')
		}
		current.WriteString(segment)
		name := current.String()
		info, statErr := store.Stat(name)
		if statErr == nil {
			if !info.IsDir() {
				return ErrType
			}
			continue
		}
		if !errors.Is(statErr, os.ErrNotExist) {
			return statErr
		}
		if mkdirErr := store.Mkdir(name); mkdirErr != nil {
			// Another writer may have created this directory after Stat. Accept
			// only a real directory after rechecking through the safe Store API.
			info, statErr = store.Stat(name)
			if statErr != nil || !info.IsDir() {
				return mkdirErr
			}
		}
	}
	return nil
}

type downloadCommitReader struct {
	source       io.Reader
	beforeCommit func() error
	checkedEOF   bool
}

func (r *downloadCommitReader) Read(buffer []byte) (int, error) {
	n, err := r.source.Read(buffer)
	if errors.Is(err, io.EOF) && !r.checkedEOF {
		r.checkedEOF = true
		if r.beforeCommit != nil {
			if checkErr := r.beforeCommit(); checkErr != nil {
				return n, checkErr
			}
		}
	}
	return n, err
}

var _ io.Reader = (*downloadCommitReader)(nil)
