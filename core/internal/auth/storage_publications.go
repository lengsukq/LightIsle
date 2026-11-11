package auth

import (
	"database/sql"
	"errors"
	"strings"
)

// PrepareStoragePublications records the actual staged object before an
// exclusive filesystem publish. The record follows the pending reservation.
func (s *Store) PrepareStoragePublications(operation string, entries []StoragePublication) error {
	if operation != "dav_copy" && operation != "dav_put" && operation != "dav_lock" && operation != "dav_replace" && operation != "download_publish" {
		return ErrInput
	}
	if len(entries) == 0 {
		return nil
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, item := range entries {
		if len(item.ReservationID) != 32 || len(item.Identity) != 64 || strings.Trim(item.Identity, "0123456789abcdef") != "" {
			return ErrInput
		}
		_, err := tx.Exec(`INSERT INTO user_storage_publications(reservation_id,identity,operation) VALUES(?,?,?)
			ON CONFLICT(reservation_id) DO UPDATE SET identity=excluded.identity
			WHERE user_storage_publications.operation=excluded.operation AND excluded.operation='download_publish'`,
			item.ReservationID, item.Identity, operation)
		if err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *Store) PreparedStoragePublication(reservationID string) (string, error) {
	var identity string
	err := s.db.QueryRow("SELECT identity FROM user_storage_publications WHERE reservation_id=?", reservationID).Scan(&identity)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return identity, err
}
