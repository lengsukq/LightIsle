package files

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"time"

	"github.com/lengsukq/lightisle/core/internal/storageidentity"
)

// MoveOut is a recoverable, owner-only COPY + VERIFIED PUBLISH + MOVE TO
// RECYCLE BIN operation. The source is NEVER permanently deleted. Power
// loss may leave both source and destination, but not neither. Recording
// every stage before irreversible steps enables a later operator to decide
// whether to retry or restore from trash without guessing at file identity.
//
// The initial implementation accepts regular FILES only. Moving a mutable
// directory tree safely requires per-child snapshots and a stronger journal.
type TransferReceipt struct {
	ID          string `json:"id"`
	Source      string `json:"source"`
	Destination string `json:"destination"`
	TrashID     string `json:"trashId,omitempty"`
	Phase       string `json:"phase"`
	Error       string `json:"error,omitempty"`
	StartedAt   int64  `json:"startedAt"`
	UpdatedAt   int64  `json:"updatedAt"`
	SourceSize  int64  `json:"sourceSize"`
}

type verifiedTrashResult struct {
	ID        string
	InTrash   bool
	Restored  bool
	Uncertain bool
}

func sameTransferFile(actual, expected os.FileInfo) bool {
	return actual != nil && expected != nil && actual.Mode().IsRegular() &&
		os.SameFile(actual, expected) && actual.Size() == expected.Size() &&
		actual.ModTime().Equal(expected.ModTime())
}

func hashStableFile(ctx context.Context, file *os.File, expected os.FileInfo) ([sha256.Size]byte, error) {
	var empty [sha256.Size]byte
	before, err := file.Stat()
	if err != nil {
		return empty, err
	}
	if !sameTransferFile(before, expected) {
		return empty, errors.New("transfer_file_metadata_changed_before_hash")
	}
	h := sha256.New()
	n, err := io.Copy(h, io.LimitReader(contextReader{ctx: ctx, file: file}, expected.Size()+1))
	if err != nil {
		return empty, err
	}
	if n != expected.Size() {
		return empty, errors.New("transfer_file_changed_during_verification")
	}
	after, err := file.Stat()
	if err != nil {
		return empty, err
	}
	if !sameTransferFile(after, before) {
		return empty, errors.New("transfer_file_metadata_changed_during_hash")
	}
	copy(empty[:], h.Sum(nil))
	return empty, nil
}

// Re-check both still-opened file instances immediately before hiding the
// source from the share. This catches a replacement or in-place corruption
// after CopyOut's own verification. Failure always retains the source.
func (s *Store) verifyPublishedMove(ctx context.Context, source, published, destination string, expected os.FileInfo) error {
	_, err := s.verifyPublishedMoveDigest(ctx, source, published, destination, expected)
	return err
}

func (s *Store) verifyPublishedMoveDigest(ctx context.Context, source, published, destination string, expected os.FileInfo) ([sha256.Size]byte, error) {
	var empty [sha256.Size]byte
	in, err := s.openFileNoFollow(source)
	if err != nil {
		return empty, err
	}
	defer in.Close()
	sourceNow, err := in.Stat()
	if err != nil || !sameTransferFile(sourceNow, expected) {
		return empty, errors.New("source_changed_after_copy")
	}
	outRoot, err := os.OpenRoot(destination)
	if err != nil {
		return empty, err
	}
	defer outRoot.Close()
	target := filepath.Base(published)
	listed, err := outRoot.Lstat(target)
	if err != nil || !listed.Mode().IsRegular() || listed.Size() != expected.Size() {
		return empty, errors.New("published_copy_changed_or_missing")
	}
	out, err := outRoot.Open(target)
	if err != nil {
		return empty, err
	}
	defer out.Close()
	opened, err := out.Stat()
	if err != nil || !sameTransferFile(opened, listed) {
		return empty, errors.New("published_copy_replaced")
	}
	sourceHash, err := hashStableFile(ctx, in, expected)
	if err != nil {
		return empty, err
	}
	targetHash, err := hashStableFile(ctx, out, opened)
	if err != nil {
		return empty, err
	}
	if sourceHash != targetHash {
		return empty, errors.New("published_copy_digest_mismatch")
	}
	if err := ctx.Err(); err != nil {
		return empty, err
	}
	// Recheck both names after the complete hashes. In particular, a source
	// mutation after its hash must not be moved to trash as if it were verified.
	sourcePath, err := s.root.Lstat(source)
	if err != nil || !sameTransferFile(sourcePath, sourceNow) {
		return empty, errors.New("source_changed_after_hash_before_trash")
	}
	sourceFD, err := in.Stat()
	if err != nil || !sameTransferFile(sourceFD, sourceNow) {
		return empty, errors.New("source_descriptor_changed_after_hash")
	}
	targetFD, err := out.Stat()
	if err != nil || !sameTransferFile(targetFD, opened) {
		return empty, errors.New("published_copy_descriptor_changed_after_hash")
	}
	checked, err := outRoot.Lstat(target)
	if err != nil || !sameTransferFile(checked, opened) {
		return empty, errors.New("published_copy_changed_before_source_trash")
	}
	return sourceHash, nil
}

// verifyMovedPublication reopens the actual trashed source and the published
// destination after rename. Both descriptors and both names must still match
// the instances whose bytes were hashed.
func (s *Store) verifyMovedPublication(ctx context.Context, trashID, published, destination string, expected os.FileInfo, digest [sha256.Size]byte) error {
	in, err := s.openTrashFileNoFollow(trashID)
	if err != nil {
		return err
	}
	defer in.Close()
	sourceInfo, err := in.Stat()
	if err != nil || !sameTransferFile(sourceInfo, expected) {
		return errors.New("trashed_source_identity_changed")
	}
	outRoot, err := os.OpenRoot(destination)
	if err != nil {
		return err
	}
	defer outRoot.Close()
	target := filepath.Base(published)
	listed, err := outRoot.Lstat(target)
	if err != nil || !listed.Mode().IsRegular() || listed.Size() != expected.Size() {
		return errors.New("published_copy_changed_after_source_trash")
	}
	out, err := outRoot.Open(target)
	if err != nil {
		return err
	}
	defer out.Close()
	targetInfo, err := out.Stat()
	if err != nil || !sameTransferFile(targetInfo, listed) {
		return errors.New("published_copy_replaced_after_source_trash")
	}
	sourceHash, err := hashStableFile(ctx, in, expected)
	if err != nil {
		return err
	}
	targetHash, err := hashStableFile(ctx, out, targetInfo)
	if err != nil {
		return err
	}
	if sourceHash != digest || targetHash != digest {
		return errors.New("source_or_published_copy_changed_after_hash")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	trashedPath, err := s.root.Lstat(path.Join(Trash, trashID))
	if err != nil || !sameTransferFile(trashedPath, sourceInfo) {
		return errors.New("trashed_source_path_changed_after_hash")
	}
	sourceFD, err := in.Stat()
	if err != nil || !sameTransferFile(sourceFD, sourceInfo) {
		return errors.New("trashed_source_descriptor_changed_after_hash")
	}
	targetFD, err := out.Stat()
	if err != nil || !sameTransferFile(targetFD, targetInfo) {
		return errors.New("published_copy_descriptor_changed_after_hash")
	}
	checked, err := outRoot.Lstat(target)
	if err != nil || !sameTransferFile(checked, targetInfo) {
		return errors.New("published_copy_path_changed_after_hash")
	}
	return nil
}

func (s *Store) moveToTrashVerified(ctx context.Context, raw string, expected os.FileInfo, published, destination string, digest [sha256.Size]byte) (verifiedTrashResult, error) {
	var result verifiedTrashResult
	name, err := s.safePath(raw, false, false)
	if err != nil {
		return result, err
	}
	current, err := s.root.Lstat(name)
	if err != nil {
		return result, err
	}
	if !sameTransferFile(current, expected) {
		return result, errors.New("source_changed_before_trash")
	}
	id, err := newTransferID()
	if err != nil {
		return result, err
	}
	result.ID = id
	trashPath := path.Join(Trash, id)
	entry := TrashEntry{ID: id, OriginalPath: name, Name: path.Base(name), DeletedAt: time.Now().UTC()}
	if _, err := s.root.Lstat(trashPath); err == nil {
		return result, ErrExists
	} else if !errors.Is(err, os.ErrNotExist) {
		return result, err
	}
	if err := s.writeTrashJournal(entry); err != nil {
		return result, err
	}
	var moveErr error
	if s.rename != nil {
		// Keep the existing deterministic race/failure seam for tests. The
		// production path uses an exclusive descriptor-relative rename below.
		moveErr = s.rename(name, trashPath)
	} else {
		moveErr = s.renameSourceToTrashNoReplace(name, id)
	}
	if moveErr != nil {
		if cleanupErr := s.removeTrashJournal(id); cleanupErr != nil {
			return result, fmt.Errorf("trash move failed: %w; journal cleanup failed: %v", moveErr, cleanupErr)
		}
		return result, moveErr
	}
	result.InTrash = true
	rollback := func(cause error) (verifiedTrashResult, error) {
		if restoreErr := s.renameTrashToNoReplace(id, name); restoreErr != nil {
			return result, fmt.Errorf("%w; source remains in recovery trash %s because no-overwrite restore failed: %v", cause, id, restoreErr)
		}
		result.InTrash = false
		result.Uncertain = true
		if syncErr := s.syncRename(trashPath, name); syncErr != nil {
			return result, fmt.Errorf("%w; source restore is visible but not durable: %v", cause, syncErr)
		}
		if cleanupErr := s.removeTrashJournal(id); cleanupErr != nil {
			return result, fmt.Errorf("%w; source was restored but trash journal cleanup failed: %v", cause, cleanupErr)
		}
		result.Restored = true
		result.Uncertain = false
		return result, cause
	}
	if err := s.syncRename(name, trashPath); err != nil {
		return rollback(fmt.Errorf("%w: source trash rename is not durable", err))
	}
	if err := s.verifyMovedPublication(ctx, id, published, destination, expected, digest); err != nil {
		return rollback(fmt.Errorf("source_trash_verification_failed: %w", err))
	}
	return result, nil
}

const maxTransferReceipts = 1000

func transferDirectory(configPath string) string {
	return filepath.Join(filepath.Dir(configPath), "cross-volume-transfers")
}

func newTransferID() (string, error) {
	var token [16]byte
	if _, err := rand.Read(token[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(token[:]), nil
}

func writeTransferReceipt(dir string, receipt TransferReceipt) error {
	if len(receipt.ID) != 32 {
		return ErrPath
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	name := filepath.Join(dir, receipt.ID+".json")
	temporary := name + ".tmp"
	data, err := json.Marshal(receipt)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(temporary, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	defer os.Remove(temporary)
	if _, err = f.Write(data); err == nil {
		err = f.Sync()
	}
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err := os.Rename(temporary, name); err != nil {
		return err
	}
	parent, err := os.Open(dir)
	if err != nil {
		return err
	}
	err = parent.Sync()
	if closeErr := parent.Close(); err == nil {
		err = closeErr
	}
	return err
}

func (m *Manager) MoveOut(ctx context.Context, sourceRelative, destinationDirectory string) (TransferReceipt, error) {
	m.opMu.Lock()
	defer m.opMu.Unlock()
	var receipt TransferReceipt
	err := m.withRead(func(s *Store) error {
		var e error
		receipt, e = s.moveOutCore(ctx, sourceRelative, destinationDirectory, m.configFile, nil, nil, nil)
		return e
	})
	return receipt, err
}

func (s *Store) moveOutWithTask(ctx context.Context, task TransferTask, configFile string, identity storageidentity.Provider, progress transferProgressFunc) (TransferReceipt, error) {
	return s.moveOutCore(ctx, task.Source, task.Destination, configFile, &task, identity, progress)
}

func (s *Store) moveOutCore(ctx context.Context, sourceRelative, destinationDirectory, configFile string, task *TransferTask, identity storageidentity.Provider, progress transferProgressFunc) (TransferReceipt, error) {
	var receipt TransferReceipt
	err := func() error {
		if err := ctx.Err(); err != nil {
			return err
		}
		source, err := s.safePath(sourceRelative, false, false)
		if err != nil {
			return err
		}
		info, err := s.root.Lstat(source)
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return ErrType
		}
		if info.Size() > maxCopyBytes {
			return ErrSize
		}
		// Fail before recording a journal if the selected destination is not
		// a valid authorized, non-overlapping folder.
		destination, err := allowedSelectedFolder(destinationDirectory)
		if err != nil {
			return err
		}
		share, err := filepath.EvalSymlinks(s.root.Name())
		if err != nil {
			return err
		}
		if pathsOverlap(share, destination) {
			return ErrPath
		}
		if task != nil {
			if err := verifyTaskRoots(ctx, s, *task, identity); err != nil {
				return err
			}
			snapshot, total, err := s.captureTransferSource(source)
			if err != nil {
				return err
			}
			if snapshot != task.SourceSnapshot || total != task.TotalBytes {
				return errors.New("queued_source_changed")
			}
		}
		id, err := newTransferID()
		if err != nil {
			return err
		}
		now := time.Now().Unix()
		receipt = TransferReceipt{ID: id, Source: source, Destination: destination, Phase: "prepared",
			StartedAt: now, UpdatedAt: now, SourceSize: info.Size()}
		dir := transferDirectory(configFile)
		if err := writeTransferReceipt(dir, receipt); err != nil {
			return err
		}
		setPhase := func(phase string, stageErr error) error {
			receipt.Phase = phase
			receipt.UpdatedAt = time.Now().Unix()
			if stageErr != nil {
				receipt.Error = stageErr.Error()
			} else {
				receipt.Error = ""
			}
			return writeTransferReceipt(dir, receipt)
		}
		// CopyOut performs full data checks, destination fsync and exclusive
		// publication. Any failure here MUST retain the source.
		var published string
		if task == nil {
			published, err = s.CopyOut(ctx, source, destination)
		} else {
			published, err = s.copyOutWithTask(ctx, source, destination, task, identity, progress)
		}
		if published != "" {
			receipt.Destination = published
		}
		if err != nil {
			phase := "copy_incomplete"
			if published != "" {
				phase = "copy_published_unconfirmed"
			}
			if markErr := setPhase(phase, err); markErr != nil {
				return errors.Join(err, markErr)
			}
			return err
		}
		if err := setPhase("published", nil); err != nil {
			// The copy exists, the source still exists. The user can safely
			// reconcile an unacknowledged publication.
			return fmt.Errorf("destination_published_source_intact_receipt_failed: %w", err)
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if task != nil {
			if err := verifyTaskRoots(ctx, s, *task, identity); err != nil {
				return fmt.Errorf("queued_roots_changed_before_source_trash_keep_both_copies: %w", err)
			}
		}
		// Only delete from the visible source tree when it is still exactly
		// the file instance that CopyOut verified. MoveToTrash uses exclusive
		// same-volume rename and its own recovery metadata.
		current, err := s.root.Lstat(source)
		if err != nil {
			return fmt.Errorf("source_changed_keep_both_copies: %w", err)
		}
		if !os.SameFile(info, current) || info.Size() != current.Size() ||
			!info.ModTime().Equal(current.ModTime()) {
			return errors.New("source_changed_keep_both_copies")
		}
		digest, err := s.verifyPublishedMoveDigest(ctx, source, published, destination, info)
		if err != nil {
			return fmt.Errorf("pre_trash_digest_recheck_failed_keep_source: %w", err)
		}
		trash, err := s.moveToTrashVerified(ctx, source, info, published, destination, digest)
		if err != nil {
			if trash.InTrash || trash.Uncertain {
				receipt.TrashID = trash.ID
			}
			phase := "source_trash_failed"
			if trash.Restored {
				phase = "source_changed_restored"
			} else if trash.InTrash {
				phase = "source_trash_unresolved"
			} else if trash.Uncertain {
				phase = "source_move_uncertain"
			}
			if markErr := setPhase(phase, err); markErr != nil {
				return errors.Join(fmt.Errorf("source_trash_failed_keep_published_copy: %w", err), markErr)
			}
			return fmt.Errorf("source_trash_failed_keep_published_copy: %w", err)
		}
		receipt.TrashID = trash.ID
		if err := setPhase("source_in_trash", nil); err != nil {
			return fmt.Errorf("move_completed_but_receipt_sync_failed: %w", err)
		}
		return nil
	}()
	return receipt, err
}

func (m *Manager) ListTransfers() ([]TransferReceipt, error) {
	root := transferDirectory(m.configFile)
	entries, err := os.ReadDir(root)
	if errors.Is(err, os.ErrNotExist) {
		return []TransferReceipt{}, nil
	}
	if err != nil {
		return nil, err
	}
	if len(entries) > maxTransferReceipts {
		return nil, ErrSize
	}
	list := make([]TransferReceipt, 0, len(entries))
	for _, entry := range entries {
		name := entry.Name()
		if len(name) != 37 || filepath.Ext(name) != ".json" {
			continue
		}
		id := name[:32]
		if _, err := hex.DecodeString(id); err != nil {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return nil, err
		}
		if !info.Mode().IsRegular() || info.Size() > 8192 {
			return nil, ErrType
		}
		data, err := os.ReadFile(filepath.Join(root, name))
		if err != nil {
			return nil, err
		}
		var receipt TransferReceipt
		if err := json.Unmarshal(data, &receipt); err != nil || receipt.ID != id {
			return nil, ErrType
		}
		list = append(list, receipt)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].StartedAt > list[j].StartedAt })
	return list, nil
}
