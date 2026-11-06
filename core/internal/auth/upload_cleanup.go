package auth

import (
	"database/sql"
	"errors"
)

const DefaultUploadRetentionDays = 30
const MaxUploadRetentionDays = 3650

// Only a genuinely new schema receives the default. If a previously created
// row is lost or damaged, the scheduler must fail closed across restarts.
func ensureUploadCleanupSettings(db *sql.DB) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var exists bool
	if err := tx.QueryRow(`SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='upload_cleanup_settings')`).Scan(&exists); err != nil {
		return err
	}
	if !exists {
		if _, err := tx.Exec(`CREATE TABLE upload_cleanup_settings (
			id INTEGER PRIMARY KEY CHECK(id=1), retention_days INTEGER NOT NULL CHECK(retention_days BETWEEN 0 AND 3650))`); err != nil {
			return err
		}
		if _, err := tx.Exec(`INSERT INTO upload_cleanup_settings(id,retention_days) VALUES(1,?)`, DefaultUploadRetentionDays); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// UploadRetentionDays is used by trusted in-process maintenance. Zero means
// automatic cleanup is disabled. A missing or damaged setting fails closed.
func (s *Store) UploadRetentionDays() (int, error) {
	var days int
	if err := s.db.QueryRow(`SELECT retention_days FROM upload_cleanup_settings WHERE id=1`).Scan(&days); err != nil {
		return 0, err
	}
	if days < 0 || days > MaxUploadRetentionDays {
		return 0, ErrInput
	}
	return days, nil
}

func (s *Store) SetUploadRetentionDays(session string, days int) error {
	actor, ok := s.Identity(session)
	if !ok || actor.Role != RoleAdmin {
		return ErrForbidden
	}
	if days < 0 || days > MaxUploadRetentionDays {
		return ErrInput
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	valid, err := adminSessionValidTx(tx, session, actor.ID)
	if err != nil {
		return err
	}
	if !valid {
		return ErrForbidden
	}
	result, err := tx.Exec(`INSERT INTO upload_cleanup_settings(id,retention_days) VALUES(1,?)
		ON CONFLICT(id) DO UPDATE SET retention_days=excluded.retention_days`, days)
	if err != nil {
		return err
	}
	if count, err := result.RowsAffected(); err != nil || count != 1 {
		if err != nil {
			return err
		}
		return errors.New("upload_cleanup_settings_missing")
	}
	return tx.Commit()
}

// UploadReservationForCleanup looks up an upload's reservation without
// accepting a session from a background worker. The caller must already have
// removed the verified unpublished staging files while holding the same root
// lease. A reservation bound to another physical generation is never returned.
func (s *Store) UploadReservationForCleanup(rootID string, generation uint64, uploadID string) (id, path string, owner int64, found bool, err error) {
	if !validRootID(rootID) || generation == 0 || generation > 1<<63-1 || len(uploadID) != 32 {
		return "", "", 0, false, ErrInput
	}
	var foundRoot string
	var foundGeneration int64
	err = s.db.QueryRow(`SELECT id,root_id,root_generation,relative_path,user_id FROM user_storage_reservations WHERE upload_id=?`, uploadID).
		Scan(&id, &foundRoot, &foundGeneration, &path, &owner)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", 0, false, nil
	}
	if err != nil {
		return "", "", 0, false, err
	}
	if foundRoot != rootID || foundGeneration != int64(generation) {
		return "", "", 0, false, ErrStorageLedgerConflict
	}
	return id, path, owner, true, nil
}

// ReleaseCleanedUploadReservation only removes the exact previously checked
// reservation; a change between lookup and release must remain for review.
func (s *Store) ReleaseCleanedUploadReservation(id, rootID string, generation uint64, uploadID, path string, owner int64) error {
	if len(id) != 32 || !validRootID(rootID) || generation == 0 || generation > 1<<63-1 || len(uploadID) != 32 || !validGrantPath(path) || path == "." || owner <= 0 {
		return ErrInput
	}
	result, err := s.db.Exec(`DELETE FROM user_storage_reservations WHERE id=? AND root_id=? AND root_generation=? AND upload_id=? AND relative_path=? AND user_id=?`,
		id, rootID, int64(generation), uploadID, path, owner)
	if err != nil {
		return err
	}
	count, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if count != 1 {
		return ErrStorageReservationMissing
	}
	return nil
}
