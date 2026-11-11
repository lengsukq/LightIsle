package auth

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	"path"
	"strings"
	"time"
)

// ReserveStorageDirectoryRename locks a destination directory prefix in the
// logical ledger before a same-root, same-owner directory rename/move.
// It returns the existing file charges under from/ so the caller can verify
// that the moved directory tree matches the ledger before committing.
func (s *Store) ReserveStorageDirectoryRename(session, rootID string, generation uint64, from, to string) (string, []TrashLedgerFile, error) {
	actor, ok := s.Identity(session)
	if !ok {
		return "", nil, ErrForbidden
	}
	return s.ReserveStorageDirectoryRenameForUser(actor, rootID, generation, from, to)
}

// ReserveStorageDirectoryRenameForUser is the user-authenticated variant shared
// by session routes and WebDAV MOVE.
func (s *Store) ReserveStorageDirectoryRenameForUser(actor User, rootID string, generation uint64, from, to string) (string, []TrashLedgerFile, error) {
	if !actor.Enabled || actor.ID <= 0 {
		return "", nil, ErrForbidden
	}
	from, to = path.Clean(from), path.Clean(to)
	if from == "." || to == "." || from == to {
		return "", nil, ErrInput
	}
	if strings.HasPrefix(to, from+"/") || strings.HasPrefix(from, to+"/") {
		return "", nil, ErrStorageLedgerConflict
	}
	var randomID [16]byte
	if _, err := rand.Read(randomID[:]); err != nil {
		return "", nil, err
	}
	id := hex.EncodeToString(randomID[:])
	tx, err := s.db.Begin()
	if err != nil {
		return "", nil, err
	}
	defer tx.Rollback()
	sourceOwner, sourceManaged, err := storageOwnerTx(tx, rootID, generation, from)
	if err != nil {
		return "", nil, err
	}
	destOwner, destManaged, err := storageOwnerTx(tx, rootID, generation, to)
	if err != nil {
		return "", nil, err
	}
	if !sourceManaged || !destManaged {
		return "", nil, ErrStorageUnassigned
	}
	if sourceOwner != destOwner || (actor.Role != RoleAdmin && actor.ID != sourceOwner) {
		return "", nil, ErrForbidden
	}
	// Refuse if any active upload reservation exists inside the source subtree
	// or if the destination path/subtree already has charges or reservations.
	var conflict int
	err = tx.QueryRow(`SELECT 1 FROM user_storage_reservations
		WHERE root_id=? AND root_generation=?
		AND (relative_path=? OR substr(relative_path,1,length(?)+1)=?||'/'
		  OR relative_path=? OR substr(relative_path,1,length(?)+1)=?||'/') LIMIT 1`,
		rootID, int64(generation), from, from, from, to, to, to).Scan(&conflict)
	if err == nil {
		return "", nil, ErrStorageLedgerConflict
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return "", nil, err
	}
	err = tx.QueryRow(`SELECT 1 FROM user_storage_files
		WHERE root_id=? AND root_generation=?
		AND (relative_path=? OR substr(relative_path,1,length(?)+1)=?||'/') LIMIT 1`,
		rootID, int64(generation), to, to, to).Scan(&conflict)
	if err == nil {
		return "", nil, ErrStorageLedgerConflict
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return "", nil, err
	}
	rows, err := tx.Query(`SELECT f.relative_path,f.user_id,f.size_bytes,COALESCE(i.identity,'')
		FROM user_storage_files f LEFT JOIN user_storage_file_identities i
		ON i.root_id=f.root_id AND i.root_generation=f.root_generation AND i.relative_path=f.relative_path
		WHERE f.root_id=? AND f.root_generation=?
		AND substr(f.relative_path,1,length(?)+1)=?||'/'
		ORDER BY f.relative_path LIMIT ?`,
		rootID, int64(generation), from, from, maxTrashLedgerFiles+1)
	if err != nil {
		return "", nil, err
	}
	defer rows.Close()
	snapshot := make([]TrashLedgerFile, 0)
	for rows.Next() {
		var item TrashLedgerFile
		if err := rows.Scan(&item.Path, &item.UserID, &item.Size, &item.Identity); err != nil {
			return "", nil, err
		}
		if item.UserID != sourceOwner {
			return "", nil, ErrStorageLedgerConflict
		}
		snapshot = append(snapshot, item)
		if len(snapshot) > maxTrashLedgerFiles {
			return "", nil, ErrStorageLedgerConflict
		}
	}
	if err := rows.Err(); err != nil {
		return "", nil, err
	}
	if _, err := tx.Exec(`INSERT INTO user_storage_reservations(id,user_id,root_id,root_generation,relative_path,size_bytes,created_at)
		VALUES(?,?,?,?,?,0,?)`, id, sourceOwner, rootID, int64(generation), to, time.Now().Unix()); err != nil {
		return "", nil, err
	}
	if err := tx.Commit(); err != nil {
		return "", nil, err
	}
	return id, snapshot, nil
}

// CommitStorageDirectoryRename updates every accounted file under from/ to its
// corresponding path under to/ and clears the zero-byte destination reservation.
func (s *Store) CommitStorageDirectoryRename(reservationID, rootID string, generation uint64, from, to string, snapshot []TrashLedgerFile) error {
	from, to = path.Clean(from), path.Clean(to)
	if len(reservationID) != 32 || !validRootID(rootID) || generation == 0 || generation > math.MaxInt64 ||
		from == "." || to == "." || from == to || len(snapshot) > maxTrashLedgerFiles {
		return ErrInput
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var owner, reservedSize int64
	err = tx.QueryRow(`SELECT user_id,size_bytes FROM user_storage_reservations
		WHERE id=? AND root_id=? AND root_generation=? AND relative_path=?`,
		reservationID, rootID, int64(generation), to).Scan(&owner, &reservedSize)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrStorageReservationMissing
	}
	if err != nil {
		return err
	}
	if reservedSize != 0 {
		return ErrStorageLedgerConflict
	}
	prefix := from + "/"
	for _, item := range snapshot {
		if !strings.HasPrefix(item.Path, prefix) || item.UserID != owner || item.Size < 0 {
			return ErrStorageLedgerConflict
		}
		var currentIdentity string
		err := tx.QueryRow(`SELECT identity FROM user_storage_file_identities
			WHERE root_id=? AND root_generation=? AND relative_path=?`,
			rootID, int64(generation), item.Path).Scan(&currentIdentity)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		if currentIdentity != item.Identity {
			return ErrStorageLedgerConflict
		}
		targetPath := to + "/" + strings.TrimPrefix(item.Path, prefix)
		result, err := tx.Exec(`UPDATE user_storage_files SET relative_path=?
			WHERE root_id=? AND root_generation=? AND relative_path=? AND user_id=? AND size_bytes=?`,
			targetPath, rootID, int64(generation), item.Path, owner, item.Size)
		if err != nil {
			return fmt.Errorf("%w: %v", ErrStorageLedgerConflict, err)
		}
		if n, err := result.RowsAffected(); err != nil || n != 1 {
			return ErrStorageLedgerConflict
		}
	}
	if _, err := tx.Exec("DELETE FROM user_storage_reservations WHERE id=?", reservationID); err != nil {
		return err
	}
	return tx.Commit()
}

// ReserveStorageUploadForUser reserves quota for an already-authenticated user
// (such as a verified WebDAV credential holder).
func (s *Store) ReserveStorageUploadForUser(actor User, rootID string, generation uint64, name string, size int64) (id string, tracked bool, err error) {
	var randomID [16]byte
	if _, err = rand.Read(randomID[:]); err != nil {
		return "", false, err
	}
	return s.reserveStoragePublicationForUser(actor, rootID, generation, name, size, hex.EncodeToString(randomID[:]), false, nil)
}

// ReserveStoragePublicationForUser resumes a reservation already tied to a
// trusted local task. The same ID cannot be rebound to another path or owner.
func (s *Store) ReserveStoragePublicationForUser(actor User, rootID string, generation uint64, name string, size int64, id string) (string, bool, error) {
	return s.reserveStoragePublicationForUser(actor, rootID, generation, name, size, id, true, nil)
}

func (s *Store) ReserveStorageReplacementForUser(actor User, rootID string, generation uint64, name string, size int64, previous StorageVersion) (string, bool, error) {
	var randomID [16]byte
	if _, err := rand.Read(randomID[:]); err != nil {
		return "", false, err
	}
	return s.reserveStoragePublicationForUser(actor, rootID, generation, name, size, hex.EncodeToString(randomID[:]), false, &previous)
}

func (s *Store) reserveStoragePublicationForUser(actor User, rootID string, generation uint64, name string, size int64, id string, resumable bool, previous *StorageVersion) (string, bool, error) {
	if size < 0 || size > 1<<40 || len(id) != 32 || strings.Trim(id, "0123456789abcdef") != "" {
		return "", false, ErrInput
	}
	if !actor.Enabled || actor.ID <= 0 {
		return "", false, ErrForbidden
	}
	tx, err := s.db.Begin()
	if err != nil {
		return "", false, err
	}
	defer tx.Rollback()
	owner, managed, err := storageOwnerTx(tx, rootID, generation, name)
	if err != nil {
		return "", false, err
	}
	if !managed {
		return "", false, nil
	}
	if actor.Role != RoleAdmin && actor.ID != owner &&
		!canMemberWriteSharedFolderAlbumTx(tx, actor.ID, rootID, generation, owner, name) {
		return "", false, ErrForbidden
	}
	if resumable {
		var reservedOwner, reservedGeneration, reservedSize int64
		var reservedRoot, reservedPath string
		err := tx.QueryRow(`SELECT user_id,root_id,root_generation,relative_path,size_bytes
			FROM user_storage_reservations WHERE id=? AND upload_id IS NULL`, id).
			Scan(&reservedOwner, &reservedRoot, &reservedGeneration, &reservedPath, &reservedSize)
		if err == nil {
			if reservedOwner == owner && reservedRoot == rootID && reservedGeneration == int64(generation) &&
				reservedPath == name && reservedSize == size {
				return id, true, nil
			}
			return "", false, ErrStorageLedgerConflict
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return "", false, err
		}
	}
	var role string
	if err := tx.QueryRow("SELECT role FROM users WHERE id=?", owner).Scan(&role); err != nil {
		return "", false, err
	}
	if role != RoleAdmin {
		quota, err := rootQuotaTx(tx, owner, rootID, generation)
		if err != nil {
			return "", false, err
		}
		used, reserved, err := rootQuotaUsageTx(tx, owner, rootID, generation)
		if err != nil {
			return "", false, err
		}
		if quota == 0 || used > quota || reserved > quota-used || size > quota-used-reserved {
			return "", false, ErrStorageQuotaExceeded
		}
	}
	if err := checkStorageWriteTarget(tx, rootID, generation, name, owner, previous); err != nil {
		return "", false, err
	}
	if _, err := tx.Exec("INSERT INTO user_storage_reservations(id,user_id,root_id,root_generation,relative_path,size_bytes,created_at) VALUES(?,?,?,?,?,?,?)",
		id, owner, rootID, int64(generation), name, size, time.Now().Unix()); err != nil {
		return "", false, err
	}
	if err := tx.Commit(); err != nil {
		return "", false, err
	}
	return id, true, nil
}

// ReserveStorageRenameForUser locks a single-file destination for a verified user.
func (s *Store) ReserveStorageRenameForUser(actor User, rootID string, generation uint64, from, to string) (string, error) {
	return s.reserveStorageRenameForUser(actor, rootID, generation, from, to, nil, nil)
}

func (s *Store) ReserveStorageRenameReplacementForUser(actor User, rootID string, generation uint64, from, to string, previous, source StorageVersion) (string, error) {
	return s.reserveStorageRenameForUser(actor, rootID, generation, from, to, &previous, &source)
}

func (s *Store) reserveStorageRenameForUser(actor User, rootID string, generation uint64, from, to string, previous, source *StorageVersion) (string, error) {
	if !actor.Enabled || actor.ID <= 0 {
		return "", ErrForbidden
	}
	if from == to {
		return "", ErrInput
	}
	var randomID [16]byte
	if _, err := rand.Read(randomID[:]); err != nil {
		return "", err
	}
	id := hex.EncodeToString(randomID[:])
	tx, err := s.db.Begin()
	if err != nil {
		return "", err
	}
	defer tx.Rollback()
	sourceOwner, sourceManaged, err := storageOwnerTx(tx, rootID, generation, from)
	if err != nil {
		return "", err
	}
	destinationOwner, destinationManaged, err := storageOwnerTx(tx, rootID, generation, to)
	if err != nil {
		return "", err
	}
	if !sourceManaged || !destinationManaged {
		return "", ErrStorageUnassigned
	}
	if sourceOwner != destinationOwner || (actor.Role != RoleAdmin && actor.ID != sourceOwner) {
		return "", ErrForbidden
	}
	var sourceFileOwner int64
	err = tx.QueryRow(`SELECT user_id FROM user_storage_files WHERE root_id=? AND root_generation=? AND relative_path=?`,
		rootID, int64(generation), from).Scan(&sourceFileOwner)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrStorageLedgerConflict
	}
	if err != nil {
		return "", err
	}
	if sourceFileOwner != sourceOwner {
		return "", ErrStorageLedgerConflict
	}
	if source != nil {
		if err := matchStorageVersion(tx, rootID, generation, from, sourceOwner, *source); err != nil {
			return "", err
		}
	}
	if err := checkStorageWriteTarget(tx, rootID, generation, to, destinationOwner, previous); err != nil {
		return "", err
	}
	if _, err = tx.Exec(`INSERT INTO user_storage_reservations(id,user_id,root_id,root_generation,relative_path,size_bytes,created_at)
		VALUES(?,?,?,?,?,0,?)`, id, sourceOwner, rootID, int64(generation), to, time.Now().Unix()); err != nil {
		return "", err
	}
	if err := tx.Commit(); err != nil {
		return "", err
	}
	return id, nil
}

// CanWritePersonalStorageForUser checks whether a path inside Users/ belongs to
// an assigned storage category on (rootID, generation) that actor may write to.
func (s *Store) CanWritePersonalStorageForUser(actor User, rootID string, generation uint64, name string) (bool, error) {
	if !actor.Enabled || actor.ID <= 0 {
		return false, nil
	}
	tx, err := s.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	owner, managed, err := storageOwnerTx(tx, rootID, generation, name)
	if err != nil {
		if errors.Is(err, ErrStorageUnassigned) {
			return false, nil
		}
		return false, err
	}
	if !managed {
		return false, nil
	}
	if actor.Role == RoleAdmin || actor.ID == owner {
		return true, nil
	}
	return canMemberWriteSharedFolderAlbumTx(tx, actor.ID, rootID, generation, owner, name), nil
}
