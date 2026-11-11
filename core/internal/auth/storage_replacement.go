package auth

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"strings"
	"time"
)

type StorageVersion struct {
	Identity string
	Size     int64
}

func checkStorageWriteTarget(tx *sql.Tx, rootID string, generation uint64, target string, owner int64, previous *StorageVersion) error {
	var existing int
	err := tx.QueryRow(`SELECT 1 FROM user_storage_reservations WHERE root_id=? AND root_generation=? AND relative_path=?`,
		rootID, int64(generation), target).Scan(&existing)
	if err == nil {
		return ErrStorageLedgerConflict
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	if previous != nil {
		return matchStorageVersion(tx, rootID, generation, target, owner, *previous)
	}
	err = tx.QueryRow(`SELECT 1 FROM user_storage_files WHERE root_id=? AND root_generation=? AND relative_path=?`,
		rootID, int64(generation), target).Scan(&existing)
	if err == nil {
		return ErrStorageLedgerConflict
	}
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	return err
}

func matchStorageVersion(tx *sql.Tx, rootID string, generation uint64, target string, owner int64, expected StorageVersion) error {
	if !validStorageIdentity(expected.Identity) || expected.Size < 0 {
		return ErrStorageLedgerConflict
	}
	var matched int
	err := tx.QueryRow(`SELECT 1 FROM user_storage_files f JOIN user_storage_file_identities i
		ON f.root_id=i.root_id AND f.root_generation=i.root_generation AND f.relative_path=i.relative_path
		WHERE f.root_id=? AND f.root_generation=? AND f.relative_path=? AND f.user_id=? AND f.size_bytes=? AND i.identity=?`,
		rootID, int64(generation), target, owner, expected.Size, expected.Identity).Scan(&matched)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrStorageLedgerConflict
	}
	return err
}

func validStorageIdentity(value string) bool {
	return len(value) == 64 && strings.Trim(value, "0123456789abcdef") == ""
}

// A replaced file remains charged until its own trash ID is durably purged.
// Keep the ordinary charge row and identity under an internal ledger key.
func trashChargePath(id string) string {
	if len(id) != 32 || strings.Trim(id, "0123456789abcdef") != "" {
		return ""
	}
	return ".lightisle-trash/" + id
}

func (s *Store) CommitStorageReplacement(reservationID, trashID, moveSource string, previous, next StorageVersion) error {
	archive := trashChargePath(trashID)
	if archive == "" || !validStorageIdentity(next.Identity) || next.Size < 0 {
		return ErrInput
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var owner, generation, reservedSize int64
	var rootID, target string
	err = tx.QueryRow(`SELECT user_id,root_id,root_generation,relative_path,size_bytes FROM user_storage_reservations WHERE id=?`,
		reservationID).Scan(&owner, &rootID, &generation, &target, &reservedSize)
	if err != nil {
		return err
	}
	if err := matchStorageVersion(tx, rootID, uint64(generation), target, owner, previous); err != nil {
		return err
	}
	if _, err := tx.Exec(`UPDATE user_storage_files SET relative_path=? WHERE root_id=? AND root_generation=? AND relative_path=?`,
		archive, rootID, generation, target); err != nil {
		return err
	}
	if moveSource == "" {
		if reservedSize != next.Size {
			return ErrStorageLedgerConflict
		}
		err = commitStoragePublication(tx, StoragePublication{ReservationID: reservationID, Identity: next.Identity})
	} else {
		err = commitStorageRename(tx, reservationID, rootID, uint64(generation), moveSource, target, next.Size, next.Identity)
	}
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) PrepareReplacementRestore(session, rootID string, generation uint64, charge TrashLedgerFile) (string, error) {
	actor, ok := s.Identity(session)
	if !ok {
		return "", ErrForbidden
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
	allowed, err := trashActorValidTx(tx, session, actor, rootID, generation, charge.Path)
	if err != nil {
		return "", err
	}
	if !allowed {
		return "", ErrForbidden
	}
	owner, managed, err := storageOwnerTx(tx, rootID, generation, charge.Path)
	if err != nil || !managed || owner != charge.UserID {
		return "", ErrStorageLedgerConflict
	}
	if err := checkStorageWriteTarget(tx, rootID, generation, charge.Path, charge.UserID, nil); err != nil {
		return "", err
	}
	if err := matchStorageVersion(tx, rootID, generation, trashChargePath(charge.ArchiveID), charge.UserID,
		StorageVersion{Identity: charge.Identity, Size: charge.Size}); err != nil {
		return "", err
	}
	if _, err := tx.Exec(`INSERT INTO user_storage_reservations(id,user_id,root_id,root_generation,relative_path,size_bytes,created_at)
		VALUES(?,?,?,?,?,0,?)`, id, charge.UserID, rootID, int64(generation), charge.Path, time.Now().Unix()); err != nil {
		return "", err
	}
	return id, tx.Commit()
}

func (s *Store) CommitReplacementRestore(id, rootID string, generation uint64, charge TrashLedgerFile) error {
	return s.CommitStorageRename(id, rootID, generation, trashChargePath(charge.ArchiveID), charge.Path, charge.Size, charge.Identity)
}
