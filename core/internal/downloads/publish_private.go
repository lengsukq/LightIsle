package downloads

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path"
	"strconv"
	"strings"

	"github.com/lengsukq/lightisle/core/internal/auth"
	"github.com/lengsukq/lightisle/core/internal/files"
)

func (m *Manager) privatePublisher() *RegistryPublisher {
	publisher, ok := m.opts.Publisher.(*RegistryPublisher)
	if !ok || publisher.accounts == nil {
		return nil
	}
	return publisher
}

func (p *RegistryPublisher) privateActor(owner int64, root RootIdentity, name string) (auth.User, error) {
	if !p.RootIdentityCurrent(root) {
		return auth.User{}, ErrRootChanged
	}
	user, err := p.accounts.GetUser(owner)
	if err != nil || !p.accounts.CanAccessRootForUser(owner, root.ID, name, true, false) {
		return auth.User{}, ErrPermission
	}
	ok, err := p.accounts.CanWritePersonalStorageForUser(user, root.ID, root.Generation, name)
	if err != nil {
		return auth.User{}, err
	}
	if !ok {
		return auth.User{}, ErrPermission
	}
	return user, nil
}

func (m *Manager) publishPrivateDownload(task Task, sourceName, source, desired string, size int64, digest string) (string, error) {
	publisher := m.privatePublisher()
	if publisher == nil || !personalStorageDestination(task.Destination) || !strings.HasPrefix(desired, task.Destination+"/") {
		return "", ErrAccountingPending
	}
	root := RootIdentity{ID: task.RootID, Generation: task.RootGeneration, Binding: task.rootBinding}
	reservationKey := sha256.Sum256([]byte("private-download\x00" + task.ID + "\x00" + sourceName))
	reservationID := hex.EncodeToString(reservationKey[:16])
	var prior publication
	var expected string
	err := m.db.QueryRow(`SELECT p.target_path,p.size,p.sha256,p.state,COALESCE(o.identity,'')
		FROM download_publications p LEFT JOIN download_publication_objects o
		ON o.task_id=p.task_id AND o.source_path=p.source_path
		WHERE p.task_id=? AND p.source_path=?`, task.ID, sourceName).
		Scan(&prior.target, &prior.size, &prior.sha256, &prior.state, &expected)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	target := desired
	if err == nil {
		if prior.size != size || prior.sha256 != digest || prior.state == "recovery_required" ||
			!strings.HasPrefix(prior.target, task.Destination+"/") {
			return "", errRecoveryRequired
		}
		target = prior.target
	} else {
		target, err = m.privateDownloadTarget(task, desired)
		if err != nil {
			return "", err
		}
		if err := m.setPublicationState(task.ID, sourceName, target, size, digest, "pending"); err != nil {
			return "", err
		}
	}
	actor, err := publisher.privateActor(task.Owner, root, target)
	if err != nil {
		return "", err
	}
	finish := func(identity string) (bool, error) {
		err := publisher.InspectDownloadRoot(root, target, func(reader io.Reader, actualSize int64) error {
			file, ok := reader.(*os.File)
			if !ok || actualSize != size || identity == "" {
				return errRecoveryRequired
			}
			hash := sha256.New()
			n, err := io.Copy(hash, io.LimitReader(file, size+1))
			info, statErr := file.Stat()
			if err != nil || statErr != nil || n != size || hex.EncodeToString(hash.Sum(nil)) != digest ||
				!files.MediaFileHasSingleLink(info) || files.MediaFileIdentity(info) != identity {
				return errRecoveryRequired
			}
			if _, err := publisher.privateActor(task.Owner, root, target); err != nil {
				return err
			}
			charged, err := publisher.accounts.StorageFileIdentity(root.ID, root.Generation, target)
			if err != nil {
				return err
			}
			if charged == identity {
				return nil
			}
			if charged != "" {
				return errRecoveryRequired
			}
			prepared, err := publisher.accounts.PreparedStoragePublication(reservationID)
			if err != nil || prepared != identity {
				return errRecoveryRequired
			}
			return publisher.accounts.CommitStorageReservationWithIdentity(reservationID, identity)
		})
		if errors.Is(err, os.ErrNotExist) {
			return false, nil
		}
		return err == nil, err
	}
	recordSuccess := func() (string, error) {
		if err := m.setPublicationState(task.ID, sourceName, target, size, digest, "published"); err != nil {
			return "", err
		}
		publisher.mu.RLock()
		callback := publisher.onPublished
		publisher.mu.RUnlock()
		if callback != nil {
			callback(root.ID, target)
		}
		return target, nil
	}
	if prior.state != "" {
		published, err := finish(expected)
		if err != nil || prior.state == "published" && !published {
			if err == nil || errors.Is(err, errRecoveryRequired) {
				_ = m.setPublicationState(task.ID, sourceName, target, size, digest, "recovery_required")
				return "", errRecoveryRequired
			}
			return "", err
		}
		if published {
			return recordSuccess()
		}
	}
	id, tracked, err := publisher.accounts.ReserveStoragePublicationForUser(actor, root.ID, root.Generation, target, size, reservationID)
	if err != nil {
		return "", err
	}
	if !tracked || id != reservationID {
		return "", ErrAccountingPending
	}
	manager, release, current, err := publisher.pinnedRoot(root)
	if err != nil {
		return "", err
	}
	defer release()
	if dir, err := manager.Stat(task.Destination); err != nil || !dir.IsDir() {
		return "", ErrPermission
	}
	if err := m.setPublicationState(task.ID, sourceName, target, size, digest, "publishing"); err != nil {
		return "", err
	}
	input, err := os.Open(source)
	if err != nil {
		return "", err
	}
	defer input.Close()
	hash := sha256.New()
	written, err := manager.PublishDownloadPrepared(root.Binding, target,
		io.TeeReader(io.LimitReader(input, size+1), hash), func(info os.FileInfo) error {
			if !current() || info.Size() != size || hex.EncodeToString(hash.Sum(nil)) != digest {
				return errRecoveryRequired
			}
			if _, err := publisher.privateActor(task.Owner, root, target); err != nil {
				return err
			}
			expected = files.MediaFileIdentity(info)
			if expected == "" {
				return errRecoveryRequired
			}
			if err := publisher.accounts.PrepareStoragePublications("download_publish", []auth.StoragePublication{
				{ReservationID: reservationID, Identity: expected},
			}); err != nil {
				return err
			}
			_, err := m.db.Exec(`INSERT INTO download_publication_objects(task_id,source_path,identity)
				VALUES(?,?,?) ON CONFLICT(task_id,source_path) DO UPDATE SET identity=excluded.identity`, task.ID, sourceName, expected)
			if err != nil {
				return err
			}
			if !current() {
				return ErrRootChanged
			}
			return nil
		})
	if errors.Is(err, files.ErrExists) {
		// The exclusive filesystem publish explicitly did not replace the
		// destination. Preserve the original and stop retrying this path.
		if current() {
			_ = publisher.accounts.ReleaseStorageReservation(reservationID)
		}
		_ = m.setPublicationState(task.ID, sourceName, target, size, digest, "recovery_required")
		return "", errRecoveryRequired
	}
	if err != nil {
		return "", err
	}
	if written != size || !current() {
		return "", errRecoveryRequired
	}
	published, err := finish(expected)
	if err != nil {
		return "", err
	}
	if !published {
		return "", errRecoveryRequired
	}
	return recordSuccess()
}

func (m *Manager) privateDownloadTarget(task Task, desired string) (string, error) {
	ext := path.Ext(desired)
	for suffix := 1; suffix <= importSuffixMax; suffix++ {
		target := desired
		if suffix > 1 {
			target = strings.TrimSuffix(desired, ext) + " (" + strconv.Itoa(suffix) + ")" + ext
		}
		exists, err := m.publicationTargetExists(task, target)
		if err != nil {
			return "", err
		}
		if !exists {
			return target, nil
		}
	}
	return "", files.ErrExists
}
