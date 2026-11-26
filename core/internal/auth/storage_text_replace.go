package auth

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"
)

// ReserveStorageTextUpdate reserves the net positive quota delta required to
// atomically save a text/markdown file in-place inside a managed personal
// subtree. Unmanaged shared paths return tracked=false without reserving bytes.
// A concurrent reservation on the same path is rejected with
// ErrStorageLedgerConflict.
func (s *Store) ReserveStorageTextUpdate(session, rootID string, generation uint64, name string, newSize int64) (string, bool, error) {
	if newSize < 0 || newSize > 1<<40 {
		return "", false, ErrInput
	}
	actor, ok := s.Identity(session)
	if !ok {
		return "", false, ErrForbidden
	}
	var randomID [16]byte
	if _, err := rand.Read(randomID[:]); err != nil {
		return "", false, err
	}
	id := hex.EncodeToString(randomID[:])

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

	var pending int
	err = tx.QueryRow(`SELECT 1 FROM user_storage_reservations
		WHERE root_id=? AND root_generation=? AND relative_path=?`,
		rootID, int64(generation), name).Scan(&pending)
	if err == nil {
		return "", false, ErrStorageLedgerConflict
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return "", false, err
	}

	var existingSize int64
	err = tx.QueryRow(`SELECT size_bytes FROM user_storage_files
		WHERE root_id=? AND root_generation=? AND relative_path=?`,
		rootID, int64(generation), name).Scan(&existingSize)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return "", false, err
	}
	delta := newSize - existingSize
	if delta < 0 {
		delta = 0
	}

	var role string
	if err := tx.QueryRow(`SELECT role FROM users WHERE id=?`, owner).Scan(&role); err != nil {
		return "", false, err
	}
	if role != RoleAdmin && delta > 0 {
		quota, err := rootQuotaTx(tx, owner, rootID, generation)
		if err != nil {
			return "", false, err
		}
		used, reserved, err := rootQuotaUsageTx(tx, owner, rootID, generation)
		if err != nil {
			return "", false, err
		}
		if quota == 0 || used > quota || reserved > quota-used || delta > quota-used-reserved {
			return "", false, ErrStorageQuotaExceeded
		}
	}

	if _, err := tx.Exec(`INSERT INTO user_storage_reservations
		(id, user_id, root_id, root_generation, relative_path, size_bytes, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		id, owner, rootID, int64(generation), name, delta, time.Now().Unix()); err != nil {
		return "", false, err
	}
	if err := tx.Commit(); err != nil {
		return "", false, err
	}
	return id, true, nil
}

// CommitStorageTextUpdate atomically updates the personal storage ledger row
// for an in-place text save (adjusting the recorded size upward or downward
// and refreshing the file identity) and clears the pending reservation.
func (s *Store) CommitStorageTextUpdate(reservationID string, newSize int64, identity string) error {
	if len(reservationID) != 32 || newSize < 0 ||
		(identity != "" && (len(identity) != 64 || strings.Trim(identity, "0123456789abcdef") != "")) {
		return ErrInput
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var owner, gen int64
	var rootID, relPath string
	err = tx.QueryRow(`SELECT user_id, root_id, root_generation, relative_path
		FROM user_storage_reservations WHERE id=?`, reservationID).
		Scan(&owner, &rootID, &gen, &relPath)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrStorageReservationMissing
	}
	if err != nil {
		return err
	}

	if _, err := tx.Exec(`INSERT INTO user_storage_files
		(root_id, root_generation, relative_path, user_id, size_bytes)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(root_id, root_generation, relative_path)
		DO UPDATE SET user_id=excluded.user_id, size_bytes=excluded.size_bytes`,
		rootID, gen, relPath, owner, newSize); err != nil {
		return fmt.Errorf("%w: %v", ErrStorageLedgerConflict, err)
	}
	if identity != "" {
		if _, err := tx.Exec(`INSERT INTO user_storage_file_identities
			(root_id, root_generation, relative_path, identity)
			VALUES (?, ?, ?, ?)
			ON CONFLICT(root_id, root_generation, relative_path)
			DO UPDATE SET identity=excluded.identity`,
			rootID, gen, relPath, identity); err != nil {
			return fmt.Errorf("%w: %v", ErrStorageLedgerConflict, err)
		}
	} else {
		if _, err := tx.Exec(`DELETE FROM user_storage_file_identities
			WHERE root_id=? AND root_generation=? AND relative_path=?`,
			rootID, gen, relPath); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(`DELETE FROM user_storage_reservations WHERE id=?`, reservationID); err != nil {
		return err
	}
	return tx.Commit()
}
