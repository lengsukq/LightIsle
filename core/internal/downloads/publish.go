package downloads

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/lengsukq/lightisle/core/internal/files"
	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

const maxStagedFiles = 4096

func (m *Manager) canResumePublish(task Task) (bool, error) {
	if task.Phase != phasePublishing || !task.rootBound {
		return false, nil
	}
	if err := m.requireTaskRoot(task); err != nil {
		return false, err
	}
	if !m.opts.CanImport(task.Owner, task.Destination) {
		return false, ErrPermission
	}
	paths, err := stagedRegularFiles(m.stagingDir(task.ID))
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	return len(paths) > 0, err
}

func (m *Manager) publicationTargetExists(root storageidentity.Binding, target string) (bool, error) {
	err := m.opts.Publisher.InspectDownload(root, target, func(_ io.Reader, _ int64) error { return nil })
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	return err == nil, err
}

func stagedRegularFiles(folder string) ([]string, error) {
	var filesFound []string
	err := filepath.WalkDir(folder, func(name string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			return nil
		}
		if !entry.Type().IsRegular() {
			return ErrInput // Never follow symlinks, pipes or device files.
		}
		filesFound = append(filesFound, name)
		if len(filesFound) > maxStagedFiles {
			return ErrBusy
		}
		return nil
	})
	return filesFound, err
}

func (m *Manager) importDownloadLocked(id string) {
	task, gid, err := m.rowByIDUnscoped(id)
	if err != nil || task.Status == StatusCancelled || task.Status == StatusCompleted {
		return
	}
	if err := m.requireTaskRoot(task); err != nil {
		m.failTask(id, downloadRootError(err), gid)
		return
	}
	if !m.opts.CanImport(task.Owner, task.Destination) {
		m.failTask(id, ErrPermission.Error(), gid)
		return
	}
	if err := m.publishStaged(task); err != nil {
		reason := "download_publish_failed"
		switch {
		case errors.Is(err, ErrPermission):
			reason = ErrPermission.Error()
		case errors.Is(err, files.ErrSize):
			reason = "download_too_large"
		case errors.Is(err, ErrRootChanged), errors.Is(err, ErrRootUnavailable):
			reason = downloadRootError(err)
		case errors.Is(err, errRecoveryRequired):
			reason = "download_publish_recovery_required"
		case errors.Is(err, os.ErrNotExist):
			reason = "download_staging_lost"
		}
		m.failTask(id, reason, gid)
	}
}

var errRecoveryRequired = errors.New("download_publish_recovery_required")

func (m *Manager) publishStaged(task Task) error {
	staging := m.stagingDir(task.ID)
	sources, err := stagedRegularFiles(staging)
	if err != nil {
		return err
	}
	if len(sources) == 0 {
		return errors.New("download_produced_no_files")
	}
	// Persist the publishing phase BEFORE writing to any destination. Any
	// failure or daemon crash thereafter must retain staged sources.
	if err := m.update(task.ID, "phase", phasePublishing, "gid", ""); err != nil {
		return err
	}
	firstName := ""
	for _, source := range sources {
		relative, err := filepath.Rel(staging, source)
		if err != nil {
			return err
		}
		relative = filepath.ToSlash(relative)
		target := path.Join(task.Destination, relative)
		if task.Destination == "." {
			target = path.Clean(relative)
		}
		size, digest, err := hashStaged(source)
		if err != nil {
			return err
		}
		if size > maxTaskBytes {
			return ErrInput
		}
		committedTarget, err := m.publishOne(task, relative, source, target, size, digest)
		if err != nil {
			return err
		}
		if firstName == "" {
			firstName = path.Base(committedTarget)
		}
	}
	now := time.Now().Unix()
	if err := m.update(task.ID, "status", StatusCompleted, "filename", firstName, "gid", "",
		"completed_at", now, "error", ""); err != nil {
		return err
	}
	if m.opts.OnTaskDone != nil {
		m.opts.OnTaskDone(firstName)
	}
	// The complete state is already durable; failed cleanup is retryable and
	// must not make the completed publication appear to have failed.
	_ = os.RemoveAll(staging)
	return nil
}

func hashStaged(source string) (int64, string, error) {
	file, err := os.Open(source)
	if err != nil {
		return 0, "", err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return 0, "", ErrInput
	}
	hash := sha256.New()
	size, err := io.CopyBuffer(hash, file, make([]byte, maxHashBuffer))
	if err != nil {
		return 0, "", err
	}
	if size != info.Size() {
		return 0, "", ErrInput
	}
	return size, hex.EncodeToString(hash.Sum(nil)), nil
}

func (m *Manager) publishOne(task Task, sourceName, source, desired string, size int64, digest string) (string, error) {
	var prior publication
	err := m.db.QueryRow("SELECT target_path,size,sha256,state FROM download_publications WHERE task_id=? AND source_path=?",
		task.ID, sourceName).Scan(&prior.target, &prior.size, &prior.sha256, &prior.state)
	hasPrior := err == nil
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	target := desired
	if hasPrior {
		target = prior.target
		if prior.size != size || prior.sha256 != digest || prior.state == "recovery_required" {
			return "", errRecoveryRequired
		}
		if prior.state == "publishing" || prior.state == "published" {
			same, exists, err := m.verifyPublication(task.rootBinding, target, size, digest)
			if err != nil {
				return "", err
			}
			if same {
				return target, m.setPublicationState(task.ID, sourceName, target, size, digest, "published")
			}
			if exists || prior.state == "published" {
				_ = m.setPublicationState(task.ID, sourceName, target, size, digest, "recovery_required")
				return "", errRecoveryRequired
			}
		}
		if prior.state == "pending" {
			// An earlier attempt reserved a target but did not publish it.
			// Foreign files at that path must be treated as collisions, not
			// as crash-recovered publications.
			hasPrior = false
			target = desired
		}
	}
	for suffix := 1; suffix <= importSuffixMax; suffix++ {
		if suffix > 1 && !hasPrior {
			ext := path.Ext(desired)
			target = strings.TrimSuffix(desired, ext) + " (" + strconv.Itoa(suffix) + ")" + ext
		}
		if !hasPrior {
			exists, err := m.publicationTargetExists(task.rootBinding, target)
			if err != nil {
				return "", err
			}
			if exists {
				continue
			}
		}
		if err := m.setPublicationState(task.ID, sourceName, target, size, digest, "pending"); err != nil {
			return "", err
		}
		if err := m.setPublicationState(task.ID, sourceName, target, size, digest, "publishing"); err != nil {
			return "", err
		}
		if !m.opts.CanImport(task.Owner, task.Destination) {
			return "", ErrPermission
		}
		handle, err := os.Open(source)
		if err != nil {
			return "", err
		}
		written, publishErr := m.opts.Publisher.PublishDownload(task.rootBinding, target, handle, func() error {
			if !m.opts.CanImport(task.Owner, task.Destination) {
				return ErrPermission
			}
			return nil
		})
		closeErr := handle.Close()
		if errors.Is(publishErr, files.ErrExists) && !hasPrior {
			// Publishing lost a race to an unrelated writer. Leave the
			// reservation in a retryable state before trying a new suffix.
			if err := m.setPublicationState(task.ID, sourceName, target, size, digest, "pending"); err != nil {
				return "", err
			}
			continue
		}
		if publishErr != nil {
			return "", publishErr
		}
		if closeErr != nil || written != size {
			_ = m.setPublicationState(task.ID, sourceName, target, size, digest, "recovery_required")
			return "", errRecoveryRequired
		}
		same, exists, err := m.verifyPublication(task.rootBinding, target, size, digest)
		if err != nil {
			return "", err
		}
		if !exists || !same {
			_ = m.setPublicationState(task.ID, sourceName, target, size, digest, "recovery_required")
			return "", errRecoveryRequired
		}
		return target, m.setPublicationState(task.ID, sourceName, target, size, digest, "published")
	}
	return "", files.ErrExists
}

func (m *Manager) setPublicationState(taskID, source, target string, size int64, digest, state string) error {
	_, err := m.db.Exec(`INSERT INTO download_publications
		(task_id,source_path,target_path,size,sha256,state,updated_at)
		VALUES(?,?,?,?,?,?,?)
		ON CONFLICT(task_id,source_path) DO UPDATE SET
		target_path=excluded.target_path,state=excluded.state,updated_at=excluded.updated_at`,
		taskID, source, target, size, digest, state, time.Now().Unix())
	return err
}

func (m *Manager) verifyPublication(root storageidentity.Binding, target string, expectedSize int64, digest string) (match, exists bool, err error) {
	err = m.opts.Publisher.InspectDownload(root, target, func(reader io.Reader, size int64) error {
		exists = true
		if size != expectedSize {
			return nil
		}
		hash := sha256.New()
		n, hashErr := io.CopyBuffer(hash, reader, make([]byte, maxHashBuffer))
		if hashErr == nil && n == expectedSize && hex.EncodeToString(hash.Sum(nil)) == digest {
			match = true
		}
		return hashErr
	})
	if errors.Is(err, os.ErrNotExist) {
		return false, false, nil
	}
	return match, exists, err
}
