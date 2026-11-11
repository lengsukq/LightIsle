package auth

import (
	"database/sql"
	"errors"
	"math"
	"time"
)

// StorageRootQuota is one member's quota for ONE root generation. Categories
// sharing that root share these same bytes. Offline roots retain their ledger.
type StorageRootQuota struct {
	RootID         string `json:"rootID"`
	RootGeneration uint64 `json:"rootGeneration"`
	QuotaBytes     *int64 `json:"quotaBytes"` // nil only for administrator
	AccountedBytes int64  `json:"accountedBytes"`
	ReservedBytes  int64  `json:"reservedBytes"`
}

// One-time and idempotent data migration. A legacy user-total quota becomes
// the limit on EACH existing physical root (without multiplying charges);
// untouched new roots default to 100 GiB. Historical ledger rows, including
// offline generations and unresolved reservations, are deliberately retained.
// Never overwrite a per-root override on subsequent database opens.
func migratePerRootStorageQuotas(db *sql.DB) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`CREATE TABLE IF NOT EXISTS storage_quota_migrations (
		name TEXT PRIMARY KEY, completed_at INTEGER NOT NULL)`); err != nil {
		return err
	}
	var completed int
	err = tx.QueryRow(`SELECT 1 FROM storage_quota_migrations WHERE name='per_disk_v1'`).Scan(&completed)
	if err == nil {
		return tx.Commit()
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	_, err = tx.Exec(`
		INSERT OR IGNORE INTO user_storage_root_quotas
		  (user_id,root_id,root_generation,quota_bytes,updated_at)
		SELECT roots.user_id,roots.root_id,roots.root_generation,legacy.quota_bytes,legacy.updated_at
		FROM (
		  SELECT user_id,root_id,root_generation FROM user_storage_locations
		  UNION SELECT user_id,root_id,root_generation FROM user_storage_files
		  UNION SELECT user_id,root_id,root_generation FROM user_storage_reservations
		) roots
		JOIN user_storage_quotas legacy ON legacy.user_id=roots.user_id
		WHERE roots.root_generation>0
	`)
	if err != nil {
		return err
	}
	if _, err := tx.Exec(`INSERT INTO storage_quota_migrations(name,completed_at)
		VALUES('per_disk_v1',?)`, time.Now().Unix()); err != nil {
		return err
	}
	return tx.Commit()
}

func rootQuotaTx(tx *sql.Tx, userID int64, rootID string, generation uint64) (int64, error) {
	var quota int64
	err := tx.QueryRow(`SELECT quota_bytes FROM user_storage_root_quotas
		WHERE user_id=? AND root_id=? AND root_generation=?`,
		userID, rootID, int64(generation)).Scan(&quota)
	if errors.Is(err, sql.ErrNoRows) {
		return DefaultMemberQuotaBytes, nil
	}
	return quota, err
}

// SetUserStorageRootQuota updates a single disk's limit and never touches any
// other disk. A root must be assigned to that member at the same generation.
func (s *Store) SetUserStorageRootQuota(adminSession string, userID int64, rootID string, generation uint64, quota int64) error {
	admin, ok := s.Identity(adminSession)
	if !ok || admin.Role != RoleAdmin {
		return ErrForbidden
	}
	return s.setUserStorageRootQuota(userID, rootID, generation, quota, func(tx *sql.Tx) error {
		return requireAdminSessionTx(tx, adminSession, admin.ID)
	})
}

func (s *Store) setUserStorageRootQuota(userID int64, rootID string, generation uint64, quota int64, authorizeTx func(*sql.Tx) error) error {
	if userID <= 0 || !validRootID(rootID) || generation < 1 || generation > math.MaxInt64 ||
		quota < 0 || quota > MaxMemberQuotaBytes {
		return ErrInput
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if authorizeTx != nil {
		if err := authorizeTx(tx); err != nil {
			return err
		}
	}
	var role string
	if err := tx.QueryRow("SELECT role FROM users WHERE id=?", userID).Scan(&role); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	if role == RoleAdmin {
		return ErrForbidden
	}
	var assigned int
	err = tx.QueryRow(`SELECT 1 FROM user_storage_locations
		WHERE user_id=? AND root_id=? AND root_generation=?
		UNION SELECT 1 FROM user_storage_root_quotas
		WHERE user_id=? AND root_id=? AND root_generation=? LIMIT 1`,
		userID, rootID, int64(generation), userID, rootID, int64(generation)).Scan(&assigned)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrStorageUnassigned
	}
	if err != nil {
		return err
	}
	_, err = tx.Exec(`INSERT INTO user_storage_root_quotas
		(user_id,root_id,root_generation,quota_bytes,updated_at) VALUES(?,?,?,?,?)
		ON CONFLICT(user_id,root_id,root_generation) DO UPDATE SET
		quota_bytes=excluded.quota_bytes,updated_at=excluded.updated_at`,
		userID, rootID, int64(generation), quota, time.Now().Unix())
	if err != nil {
		return err
	}
	return tx.Commit()
}

// rootQuotaUsageTx is shared by the quota guard and administrative read views.
// Both fields are scoped to exactly one immutable disk generation.
func rootQuotaUsageTx(tx *sql.Tx, userID int64, rootID string, gen uint64) (used, reserved int64, err error) {
	if err = tx.QueryRow(`SELECT COALESCE(SUM(size_bytes),0) FROM user_storage_files
		WHERE user_id=? AND root_id=? AND root_generation=?`, userID, rootID, int64(gen)).Scan(&used); err != nil {
		return
	}
	err = tx.QueryRow(`SELECT COALESCE(SUM(size_bytes),0) FROM user_storage_reservations
		WHERE user_id=? AND root_id=? AND root_generation=?`, userID, rootID, int64(gen)).Scan(&reserved)
	return
}

func (s *Store) StorageRootMeter(session string, userID int64, rootID string, generation uint64) (StorageMeter, error) {
	actor, ok := s.Identity(session)
	if !ok || (actor.Role != RoleAdmin && actor.ID != userID) {
		return StorageMeter{}, ErrForbidden
	}
	if userID < 1 || !validRootID(rootID) || generation < 1 || generation > math.MaxInt64 {
		return StorageMeter{}, ErrInput
	}
	policy, err := s.storagePolicy(userID)
	if err != nil {
		return StorageMeter{}, err
	}
	for _, q := range policy.RootQuotas {
		if q.RootID != rootID || q.RootGeneration != generation {
			continue
		}
		meter := StorageMeter{UsedBytes: q.AccountedBytes, ReservedBytes: q.ReservedBytes}
		if q.QuotaBytes != nil {
			remaining := *q.QuotaBytes - q.AccountedBytes - q.ReservedBytes
			if remaining < 0 {
				remaining = 0
			}
			meter.AvailableBytes = &remaining
		}
		return meter, nil
	}
	return StorageMeter{}, ErrStorageUnassigned
}
