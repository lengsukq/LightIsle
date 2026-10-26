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

var (
	ErrStorageQuotaExceeded      = errors.New("storage_quota_exceeded")
	ErrStorageUnassigned         = errors.New("storage_destination_not_assigned")
	ErrStorageReservationMissing = errors.New("storage_reservation_missing")
	ErrStorageLedgerConflict     = errors.New("storage_accounting_conflict")
)

// StorageMeter is the conservative logical accounting view. Reservations are
// held across restarts rather than silently expired: a late FinishUpload or
// crash after publication must never free bytes that may exist on disk.
// Ledger records only files written through integrated guarded paths.
type StorageMeter struct {
	UsedBytes      int64  `json:"usedBytes"`
	ReservedBytes  int64  `json:"reservedBytes"`
	AvailableBytes *int64 `json:"availableBytes"`
}

// StoragePendingReservation is an administrative, read-only recovery record.
// It reports what the quota ledger reserved, NOT proof that bytes exist on a
// potentially disconnected/replaced physical root. Never auto-clear these
// entries based solely on age or missing paths.
type StoragePendingReservation struct {
	ID             string `json:"id"`
	RootID         string `json:"rootID"`
	RootGeneration uint64 `json:"rootGeneration"`
	RelativePath   string `json:"relativePath"`
	SizeBytes      int64  `json:"sizeBytes"`
	UploadID       string `json:"uploadID,omitempty"`
	CreatedAt      int64  `json:"createdAt"`
}

// StoragePendingReservations pages by the immutable reservation ID. Only an
// administrator may inspect recovery state across a user's roots. A device
// being offline must never result in records being silently hidden or freed.
func (s *Store) StoragePendingReservations(adminSession string, userID int64, after string, limit int) ([]StoragePendingReservation, string, error) {
	actor, ok := s.Identity(adminSession)
	if !ok || actor.Role != RoleAdmin {
		return nil, "", ErrForbidden
	}
	if userID <= 0 || limit < 1 || limit > 100 ||
		(after != "" && (len(after) != 32 || strings.Trim(after, "0123456789abcdef") != "")) {
		return nil, "", ErrInput
	}
	var exists int
	if err := s.db.QueryRow("SELECT 1 FROM users WHERE id=?", userID).Scan(&exists); errors.Is(err, sql.ErrNoRows) {
		return nil, "", ErrNotFound
	} else if err != nil {
		return nil, "", err
	}
	rows, err := s.db.Query(`SELECT id,root_id,root_generation,relative_path,size_bytes,COALESCE(upload_id,''),created_at
		FROM user_storage_reservations WHERE user_id=? AND id>? ORDER BY id LIMIT ?`, userID, after, limit+1)
	if err != nil {
		return nil, "", err
	}
	defer rows.Close()
	entries := make([]StoragePendingReservation, 0, limit+1)
	for rows.Next() {
		var item StoragePendingReservation
		var generation int64
		if err := rows.Scan(&item.ID, &item.RootID, &generation, &item.RelativePath, &item.SizeBytes, &item.UploadID, &item.CreatedAt); err != nil {
			return nil, "", err
		}
		if generation <= 0 {
			return nil, "", ErrStorageLedgerConflict
		}
		item.RootGeneration = uint64(generation)
		entries = append(entries, item)
	}
	if err := rows.Err(); err != nil {
		return nil, "", err
	}
	next := ""
	if len(entries) > limit {
		next = entries[limit-1].ID
		entries = entries[:limit]
	}
	return entries, next, nil
}

func (s *Store) StorageMeter(actorSession string, userID int64) (StorageMeter, error) {
	u, ok := s.Identity(actorSession)
	if !ok || (u.ID != userID && u.Role != RoleAdmin) {
		return StorageMeter{}, ErrForbidden
	}
	return s.storageMeter(userID)
}

func (s *Store) storageMeter(userID int64) (StorageMeter, error) {
	result := StorageMeter{}
	if err := s.db.QueryRow("SELECT COALESCE(SUM(size_bytes),0) FROM user_storage_files WHERE user_id=?", userID).Scan(&result.UsedBytes); err != nil {
		return StorageMeter{}, err
	}
	if err := s.db.QueryRow("SELECT COALESCE(SUM(size_bytes),0) FROM user_storage_reservations WHERE user_id=?", userID).Scan(&result.ReservedBytes); err != nil {
		return StorageMeter{}, err
	}
	policy, err := s.storagePolicy(userID)
	if err != nil {
		return StorageMeter{}, err
	}
	if policy.QuotaBytes != nil {
		remaining := *policy.QuotaBytes - result.UsedBytes - result.ReservedBytes
		if remaining < 0 {
			remaining = 0
		}
		result.AvailableBytes = &remaining
	}
	return result, nil
}

// storageOwnerTx only accepts a bound, generation-pinned category subtree.
// A caller cannot claim another user's bytes by supplying an arbitrary path.
func storageOwnerTx(tx *sql.Tx, rootID string, generation uint64, name string) (int64, bool, error) {
	if !validRootID(rootID) || generation == 0 || generation > math.MaxInt64 ||
		name == "" || path.Clean(name) != name || strings.HasPrefix(name, "/") {
		return 0, false, ErrInput
	}
	rows, err := tx.Query("SELECT user_id,relative_path FROM user_storage_locations WHERE root_id=? AND root_generation=?", rootID, int64(generation))
	if err != nil {
		return 0, false, err
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		var prefix string
		if err := rows.Scan(&id, &prefix); err != nil {
			return 0, false, err
		}
		if strings.HasPrefix(name, prefix+"/") {
			return id, true, nil
		}
	}
	if err := rows.Err(); err != nil {
		return 0, false, err
	}
	// A category root itself must never be used as a file. Unknown paths in
	// the reserved Users namespace are not accepted by the new write APIs.
	if isPersonalHomePath(name) {
		return 0, false, ErrStorageUnassigned
	}
	return 0, false, nil
}

// ReserveStorageUpload checks the one-user sum of ALL roots and categories
// inside a single SQLite write transaction. Concurrent callers serialize at
// the database write lock; neither may allocate the same free bytes twice.
// Unmanaged pre-existing legacy root paths return tracked=false and do not
// falsely assert that quota enforcement applies to them.
func (s *Store) ReserveStorageUpload(session, rootID string, generation uint64, name string, size int64) (id string, tracked bool, err error) {
	if size < 0 || size > 1<<40 {
		return "", false, ErrInput
	}
	actor, ok := s.Identity(session)
	if !ok {
		return "", false, ErrForbidden
	}
	var randomID [16]byte
	if _, err = rand.Read(randomID[:]); err != nil {
		return "", false, err
	}
	id = hex.EncodeToString(randomID[:])
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
	if actor.Role != RoleAdmin && actor.ID != owner {
		return "", false, ErrForbidden
	}
	var role string
	if err := tx.QueryRow("SELECT role FROM users WHERE id=?", owner).Scan(&role); err != nil {
		return "", false, err
	}
	if role != RoleAdmin {
		var quota int64
		err := tx.QueryRow("SELECT quota_bytes FROM user_storage_quotas WHERE user_id=?", owner).Scan(&quota)
		if errors.Is(err, sql.ErrNoRows) {
			quota = DefaultMemberQuotaBytes
		} else if err != nil {
			return "", false, err
		}
		var used, reserved int64
		if err := tx.QueryRow("SELECT COALESCE(SUM(size_bytes),0) FROM user_storage_files WHERE user_id=?", owner).Scan(&used); err != nil {
			return "", false, err
		}
		if err := tx.QueryRow("SELECT COALESCE(SUM(size_bytes),0) FROM user_storage_reservations WHERE user_id=?", owner).Scan(&reserved); err != nil {
			return "", false, err
		}
		if used > quota || reserved > quota-used || size > quota-used-reserved {
			return "", false, ErrStorageQuotaExceeded
		}
	}
	var exists int
	err = tx.QueryRow("SELECT 1 FROM user_storage_files WHERE root_id=? AND root_generation=? AND relative_path=?", rootID, int64(generation), name).Scan(&exists)
	if err == nil {
		return "", false, ErrStorageLedgerConflict
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return "", false, err
	}
	// Do not reserve the same destination twice. A failed/uncertain publisher
	// keeps its reservation until reconciliation confirms no destination exists.
	err = tx.QueryRow("SELECT 1 FROM user_storage_reservations WHERE root_id=? AND root_generation=? AND relative_path=?", rootID, int64(generation), name).Scan(&exists)
	if err == nil {
		return "", false, ErrStorageLedgerConflict
	}
	if !errors.Is(err, sql.ErrNoRows) {
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

func (s *Store) LinkStorageUpload(reservationID, uploadID string) error {
	if len(reservationID) != 32 || len(uploadID) != 32 {
		return ErrInput
	}
	result, err := s.db.Exec("UPDATE user_storage_reservations SET upload_id=? WHERE id=? AND upload_id IS NULL", uploadID, reservationID)
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

func (s *Store) ReservationForUpload(uploadID, session string) (string, error) {
	actor, ok := s.Identity(session)
	if !ok {
		return "", ErrForbidden
	}
	var id string
	err := s.db.QueryRow(`SELECT id FROM user_storage_reservations WHERE upload_id=? AND (user_id=? OR ?='admin')`, uploadID, actor.ID, actor.Role).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrStorageReservationMissing
	}
	return id, err
}

func (s *Store) ReleaseStorageReservation(id string) error {
	if len(id) != 32 {
		return ErrInput
	}
	_, err := s.db.Exec("DELETE FROM user_storage_reservations WHERE id=?", id)
	return err
}

// CommitStorageReservation is called ONLY after durable file publication.
// Publication can succeed even if this database update fails; the pending
// reservation is intentionally retained, and the UI must report uncertainty.
func (s *Store) CommitStorageReservation(id string) error {
	if len(id) != 32 {
		return ErrInput
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var userID, gen, size int64
	var rootID, name string
	err = tx.QueryRow("SELECT user_id,root_id,root_generation,relative_path,size_bytes FROM user_storage_reservations WHERE id=?", id).
		Scan(&userID, &rootID, &gen, &name, &size)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrStorageReservationMissing
	}
	if err != nil {
		return err
	}
	result, err := tx.Exec("INSERT INTO user_storage_files(root_id,root_generation,relative_path,user_id,size_bytes) VALUES(?,?,?,?,?)",
		rootID, gen, name, userID, size)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrStorageLedgerConflict, err)
	}
	if n, err := result.RowsAffected(); err != nil || n != 1 {
		return ErrStorageLedgerConflict
	}
	if _, err := tx.Exec("DELETE FROM user_storage_reservations WHERE id=?", id); err != nil {
		return err
	}
	return tx.Commit()
}

// ForgetPermanentlyDeletedStorage removes only the accounting of a path
// whose physical bytes have ALREADY been durably purged from the root's
// trash. Files moved into trash remain billed until this point.
func (s *Store) ForgetPermanentlyDeletedStorage(rootID string, generation uint64, originalPath string) error {
	if !validRootID(rootID) || generation < 1 || generation > math.MaxInt64 ||
		originalPath == "" || originalPath == "." || path.Clean(originalPath) != originalPath ||
		strings.HasPrefix(originalPath, "/") {
		return ErrInput
	}
	_, err := s.db.Exec(`DELETE FROM user_storage_files WHERE root_id=? AND root_generation=?
		AND (relative_path=? OR substr(relative_path,1,length(?)+1)=?||'/')`,
		rootID, int64(generation), originalPath, originalPath, originalPath)
	return err
}
