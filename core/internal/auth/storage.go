package auth

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Every assigned physical root generation receives its own logical limit.
// Multiple categories on the SAME disk consume the same single quota.
const DefaultMemberQuotaBytes int64 = 100 << 30
const MaxMemberQuotaBytes int64 = 1 << 50

const (
	StorageFiles  = "files"
	StoragePhotos = "photos"
	StorageVideos = "videos"
)

var ErrStorageReassignmentRequiresMigration = errors.New("storage_location_migration_required")

// StorageLocation is a configuration binding only. It does NOT authorize
// access, migrate files, create directories, or turn on quota enforcement.
// Filesystem users must validate the referenced generation with RootRegistry.
type StorageLocation struct {
	Category       string `json:"category"`
	RootID         string `json:"rootID"`
	RootGeneration uint64 `json:"rootGeneration"`
	RelativePath   string `json:"relativePath"`
}

// AbandonUserStorageLocation detaches ONE category's previous storage space.
// The caller must first confirm its root ID has been removed from the trusted
// registry: this method deliberately never tries to find, repair, move, erase
// or scan a failing disk. Old per-category accounting, pending reservations,
// private grants and shares are retired together, so a new empty location
// can be created without inheriting the abandoned space's quota or access.
// This never touches disk files. Existing physical data is the owner's
// responsibility; attaching it again requires an explicit separate import.
func (s *Store) AbandonUserStorageLocation(adminSession string, userID int64, category, expectedRootID string, expectedGeneration uint64) error {
	admin, ok := s.Identity(adminSession)
	if !ok || admin.Role != RoleAdmin {
		return ErrForbidden
	}
	return s.abandonUserStorageLocation(userID, category, expectedRootID, expectedGeneration, func(tx *sql.Tx) error {
		return requireAdminSessionTx(tx, adminSession, admin.ID)
	})
}

func (s *Store) abandonUserStorageLocation(userID int64, category, expectedRootID string, expectedGeneration uint64, authorizeTx func(*sql.Tx) error) error {
	if userID <= 0 || !validStorageCategory(category) || !validRootID(expectedRootID) ||
		expectedGeneration == 0 || expectedGeneration > uint64(1<<63-1) {
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
	var actualRoot, prefix string
	var gen int64
	err = tx.QueryRow(`SELECT root_id,root_generation,relative_path FROM user_storage_locations
		WHERE user_id=? AND category=?`, userID, category).Scan(&actualRoot, &gen, &prefix)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if actualRoot != expectedRootID || gen != int64(expectedGeneration) {
		return ErrStorageReassignmentRequiresMigration
	}
	for _, query := range []string{
		`DELETE FROM user_storage_files WHERE user_id=? AND root_id=? AND root_generation=?
		 AND substr(relative_path,1,length(?)+1)=?||'/'`,
		`DELETE FROM user_storage_reservations WHERE user_id=? AND root_id=? AND root_generation=?
		 AND substr(relative_path,1,length(?)+1)=?||'/'`,
	} {
		if _, err := tx.Exec(query, userID, expectedRootID, gen, prefix, prefix); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(`DELETE FROM root_file_shares WHERE user_id=? AND root_id=?
		AND (file_path=? OR substr(file_path,1,length(?)+1)=?||'/')`,
		userID, expectedRootID, prefix, prefix, prefix); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM root_file_grants WHERE user_id=? AND root_id=? AND path=?`,
		userID, expectedRootID, prefix); err != nil {
		return err
	}
	result, err := tx.Exec(`DELETE FROM user_storage_locations WHERE user_id=? AND category=? AND root_id=? AND root_generation=?`,
		userID, category, expectedRootID, gen)
	if err != nil {
		return err
	}
	if affected, err := result.RowsAffected(); err != nil || affected != 1 {
		return ErrStorageReassignmentRequiresMigration
	}
	if _, err := tx.Exec(`DELETE FROM user_storage_root_quotas
		WHERE user_id=? AND root_id=? AND root_generation=?
		AND NOT EXISTS(SELECT 1 FROM user_storage_locations WHERE user_id=? AND root_id=? AND root_generation=?)
		AND NOT EXISTS(SELECT 1 FROM user_storage_files WHERE user_id=? AND root_id=? AND root_generation=?)
		AND NOT EXISTS(SELECT 1 FROM user_storage_reservations WHERE user_id=? AND root_id=? AND root_generation=?)`,
		userID, expectedRootID, gen,
		userID, expectedRootID, gen,
		userID, expectedRootID, gen,
		userID, expectedRootID, gen); err != nil {
		return err
	}
	return tx.Commit()
}

// AbandonUserStorageRoot retires a removed disk's quota allocation when no
// category locations remain on that root generation (or retires all remaining
// records for that root generation). The caller must verify the root ID is no
// longer registered in RootRegistry.
func (s *Store) AbandonUserStorageRoot(adminSession string, userID int64, expectedRootID string, expectedGeneration uint64) error {
	admin, ok := s.Identity(adminSession)
	if !ok || admin.Role != RoleAdmin {
		return ErrForbidden
	}
	return s.abandonUserStorageRoot(userID, expectedRootID, expectedGeneration, func(tx *sql.Tx) error {
		return requireAdminSessionTx(tx, adminSession, admin.ID)
	})
}

func (s *Store) abandonUserStorageRoot(userID int64, expectedRootID string, expectedGeneration uint64, authorizeTx func(*sql.Tx) error) error {
	if userID <= 0 || !validRootID(expectedRootID) ||
		expectedGeneration == 0 || expectedGeneration > uint64(1<<63-1) {
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
	gen := int64(expectedGeneration)
	var hasRecord int
	err = tx.QueryRow(`SELECT 1 FROM (
		SELECT root_id,root_generation FROM user_storage_locations WHERE user_id=? AND root_id=? AND root_generation=?
		UNION SELECT root_id,root_generation FROM user_storage_root_quotas WHERE user_id=? AND root_id=? AND root_generation=?
		UNION SELECT root_id,root_generation FROM user_storage_files WHERE user_id=? AND root_id=? AND root_generation=?
		UNION SELECT root_id,root_generation FROM user_storage_reservations WHERE user_id=? AND root_id=? AND root_generation=?
	) LIMIT 1`,
		userID, expectedRootID, gen,
		userID, expectedRootID, gen,
		userID, expectedRootID, gen,
		userID, expectedRootID, gen).Scan(&hasRecord)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	rows, err := tx.Query(`SELECT relative_path FROM user_storage_locations WHERE user_id=? AND root_id=? AND root_generation=?`,
		userID, expectedRootID, gen)
	if err != nil {
		return err
	}
	var prefixes []string
	for rows.Next() {
		var prefix string
		if err := rows.Scan(&prefix); err != nil {
			rows.Close()
			return err
		}
		prefixes = append(prefixes, prefix)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	rows.Close()
	for _, prefix := range prefixes {
		if _, err := tx.Exec(`DELETE FROM root_file_shares WHERE user_id=? AND root_id=?
			AND (file_path=? OR substr(file_path,1,length(?)+1)=?||'/')`,
			userID, expectedRootID, prefix, prefix, prefix); err != nil {
			return err
		}
		if _, err := tx.Exec(`DELETE FROM root_file_grants WHERE user_id=? AND root_id=? AND path=?`,
			userID, expectedRootID, prefix); err != nil {
			return err
		}
	}
	for _, query := range []string{
		`DELETE FROM user_storage_files WHERE user_id=? AND root_id=? AND root_generation=?`,
		`DELETE FROM user_storage_reservations WHERE user_id=? AND root_id=? AND root_generation=?`,
		`DELETE FROM user_storage_locations WHERE user_id=? AND root_id=? AND root_generation=?`,
		`DELETE FROM user_storage_root_quotas WHERE user_id=? AND root_id=? AND root_generation=?`,
	} {
		if _, err := tx.Exec(query, userID, expectedRootID, gen); err != nil {
			return err
		}
	}
	return tx.Commit()
}

type StoragePolicy struct {
	UserID         int64              `json:"userId"`
	Role           string             `json:"role,omitempty"`
	Unlimited      bool               `json:"unlimited,omitempty"`
	QuotaBytes     *int64             `json:"quotaBytes"` // deprecated: ALWAYS nil; no aggregate quota
	RootQuotas     []StorageRootQuota `json:"rootQuotas"`
	Locations      []StorageLocation  `json:"locations"`
	Enforcement    string             `json:"enforcement"`
	AccountedBytes int64              `json:"accountedBytes"` // Only files published via quota-aware writers
	ReservedBytes  int64              `json:"reservedBytes"`
	UsageComplete  bool               `json:"usageComplete"` // always false until other writers and scan reconciliation are integrated
}

func validStorageCategory(category string) bool {
	switch category {
	case StorageFiles, StoragePhotos, StorageVideos:
		return true
	default:
		return false
	}
}

// StoragePolicy returns the intended user-specific configuration. Until ALL
// file write entrypoints share an accounting/reservation guard, the returned
// "pending" marker must be reflected in API/UI: the quota is not enforced.
func (s *Store) StoragePolicy(actorSession string, targetUserID int64) (StoragePolicy, error) {
	actor, ok := s.Identity(actorSession)
	if !ok || (actor.Role != RoleAdmin && actor.ID != targetUserID) {
		return StoragePolicy{}, ErrForbidden
	}
	return s.storagePolicy(targetUserID)
}

func (s *Store) storagePolicy(targetUserID int64) (StoragePolicy, error) {
	if targetUserID <= 0 {
		return StoragePolicy{}, ErrInput
	}
	var role string
	if err := s.db.QueryRow("SELECT role FROM users WHERE id=?", targetUserID).Scan(&role); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return StoragePolicy{}, ErrNotFound
		}
		return StoragePolicy{}, err
	}
	policy := StoragePolicy{
		UserID:      targetUserID,
		Role:        role,
		Unlimited:   role == RoleAdmin,
		Locations:   []StorageLocation{},
		RootQuotas:  []StorageRootQuota{},
		Enforcement: "pending",
	}
	rows, err := s.db.Query("SELECT category,root_id,root_generation,relative_path FROM user_storage_locations WHERE user_id=? ORDER BY category", targetUserID)
	if err != nil {
		return StoragePolicy{}, err
	}
	for rows.Next() {
		var location StorageLocation
		if err := rows.Scan(&location.Category, &location.RootID, &location.RootGeneration, &location.RelativePath); err != nil {
			return StoragePolicy{}, err
		}
		policy.Locations = append(policy.Locations, location)
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return StoragePolicy{}, err
	}
	if err := rows.Close(); err != nil {
		return StoragePolicy{}, err
	}
	// Preserve offline generations and unresolved crash reservations in the
	// read model. A detached disk must not quietly release accounted bytes.
	rootRows, err := s.db.Query(`SELECT roots.root_id,roots.root_generation,q.quota_bytes,
		(SELECT COALESCE(SUM(size_bytes),0) FROM user_storage_files f WHERE f.user_id=? AND f.root_id=roots.root_id AND f.root_generation=roots.root_generation),
		(SELECT COALESCE(SUM(size_bytes),0) FROM user_storage_reservations r WHERE r.user_id=? AND r.root_id=roots.root_id AND r.root_generation=roots.root_generation)
		FROM (
		 SELECT root_id,root_generation FROM user_storage_locations WHERE user_id=?
		 UNION SELECT root_id,root_generation FROM user_storage_root_quotas WHERE user_id=?
		 UNION SELECT root_id,root_generation FROM user_storage_files WHERE user_id=?
		 UNION SELECT root_id,root_generation FROM user_storage_reservations WHERE user_id=?
		) roots LEFT JOIN user_storage_root_quotas q
		ON q.user_id=? AND q.root_id=roots.root_id AND q.root_generation=roots.root_generation
		ORDER BY roots.root_id,roots.root_generation`,
		targetUserID, targetUserID, targetUserID, targetUserID, targetUserID, targetUserID, targetUserID)
	if err != nil {
		return StoragePolicy{}, err
	}
	for rootRows.Next() {
		var q StorageRootQuota
		var gen int64
		var configured sql.NullInt64
		if err := rootRows.Scan(&q.RootID, &gen, &configured, &q.AccountedBytes, &q.ReservedBytes); err != nil {
			rootRows.Close()
			return StoragePolicy{}, err
		}
		if gen < 1 {
			rootRows.Close()
			return StoragePolicy{}, ErrInput
		}
		q.RootGeneration = uint64(gen)
		if role != RoleAdmin {
			limit := DefaultMemberQuotaBytes
			if configured.Valid {
				limit = configured.Int64
			}
			q.QuotaBytes = &limit
		}
		policy.RootQuotas = append(policy.RootQuotas, q)
	}
	if err := rootRows.Err(); err != nil {
		rootRows.Close()
		return StoragePolicy{}, err
	}
	if err := rootRows.Close(); err != nil {
		return StoragePolicy{}, err
	}
	if err := s.db.QueryRow("SELECT COALESCE(SUM(size_bytes),0) FROM user_storage_files WHERE user_id=?", targetUserID).Scan(&policy.AccountedBytes); err != nil {
		return StoragePolicy{}, err
	}
	if err := s.db.QueryRow("SELECT COALESCE(SUM(size_bytes),0) FROM user_storage_reservations WHERE user_id=?", targetUserID).Scan(&policy.ReservedBytes); err != nil {
		return StoragePolicy{}, err
	}
	return policy, nil
}

// AssignUserStorage records a fixed, private per-category destination. The
// path is derived from the immutable numeric user ID, never from a submitted
// username or arbitrary client path. rootID/generation MUST first be checked
// by the trusted RootRegistry caller. A different disk/epoch requires a
// separate, owner-reviewed migration; do not silently redirect old media.
func (s *Store) AssignUserStorage(actorSession string, targetUserID int64, category, rootID string, generation uint64) (StorageLocation, error) {
	return s.AssignUserStorageWithQuota(actorSession, targetUserID, category, rootID, generation, nil)
}

// AssignUserStorageWithQuota assigns one category directory and optionally
// configures the user's quota on that disk generation in the same transaction.
func (s *Store) AssignUserStorageWithQuota(actorSession string, targetUserID int64, category, rootID string, generation uint64, quotaBytes *int64) (StorageLocation, error) {
	if !validStorageCategory(category) {
		return StorageLocation{}, ErrInput
	}
	locations, err := s.AllocateUserStorageRoot(actorSession, targetUserID, rootID, generation, quotaBytes, []string{category})
	if err != nil {
		return StorageLocation{}, err
	}
	if len(locations) != 1 {
		return StorageLocation{}, ErrInput
	}
	return locations[0], nil
}

// AllocateUserStorageRoot configures a user's storage space and per-disk quota
// on a verified root generation, and optionally binds one or more category
// directories in the same transaction. Passing an empty categories slice
// allocates the disk space and quota first so directories can be added later.
func (s *Store) AllocateUserStorageRoot(actorSession string, targetUserID int64, rootID string, generation uint64, quotaBytes *int64, categories []string) ([]StorageLocation, error) {
	actor, ok := s.Identity(actorSession)
	if !ok || actor.Role != RoleAdmin {
		return nil, ErrForbidden
	}
	return s.allocateUserStorageRoot(targetUserID, rootID, generation, quotaBytes, categories, func(tx *sql.Tx) error {
		return requireAdminSessionTx(tx, actorSession, actor.ID)
	})
}

func (s *Store) allocateUserStorageRoot(targetUserID int64, rootID string, generation uint64, quotaBytes *int64, categories []string, authorizeTx func(*sql.Tx) error) ([]StorageLocation, error) {
	if targetUserID <= 0 || !validRootID(rootID) ||
		rootID != strings.ToLower(rootID) || generation < 1 || generation > uint64(1<<63-1) {
		return nil, ErrInput
	}
	if quotaBytes != nil && (*quotaBytes < 0 || *quotaBytes > MaxMemberQuotaBytes) {
		return nil, ErrInput
	}
	seen := make(map[string]bool, len(categories))
	uniqueCategories := make([]string, 0, len(categories))
	for _, category := range categories {
		if !validStorageCategory(category) {
			return nil, ErrInput
		}
		if !seen[category] {
			seen[category] = true
			uniqueCategories = append(uniqueCategories, category)
		}
	}
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if authorizeTx != nil {
		if err := authorizeTx(tx); err != nil {
			return nil, err
		}
	}
	var role string
	if err := tx.QueryRow("SELECT role FROM users WHERE id=?", targetUserID).Scan(&role); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	if role == RoleAdmin && len(uniqueCategories) == 0 && quotaBytes != nil {
		return nil, ErrForbidden
	}
	now := time.Now().Unix()
	locations := make([]StorageLocation, 0, len(uniqueCategories))
	for _, category := range uniqueCategories {
		location := StorageLocation{
			Category:       category,
			RootID:         rootID,
			RootGeneration: generation,
			RelativePath:   fmt.Sprintf("Users/u%s/%s", strconv.FormatInt(targetUserID, 10), category),
		}
		var old StorageLocation
		err = tx.QueryRow("SELECT category,root_id,root_generation,relative_path FROM user_storage_locations WHERE user_id=? AND category=?",
			targetUserID, category).Scan(&old.Category, &old.RootID, &old.RootGeneration, &old.RelativePath)
		if err == nil {
			if old != location {
				return nil, ErrStorageReassignmentRequiresMigration
			}
		} else if !errors.Is(err, sql.ErrNoRows) {
			return nil, err
		} else {
			if _, err = tx.Exec(`INSERT INTO user_storage_locations(user_id,category,root_id,root_generation,relative_path,updated_at)
				VALUES(?,?,?,?,?,?)`, targetUserID, category, rootID, int64(generation), location.RelativePath, now); err != nil {
				return nil, err
			}
		}
		if _, err := tx.Exec(`DELETE FROM user_storage_detached_paths WHERE root_id=? AND lower(path)=lower(?)`,
			rootID, location.RelativePath); err != nil {
			return nil, err
		}
		// A member gets only their assigned folder, never an entire physical root.
		// Keep the ACL in the SAME accounts.sqlite transaction as its binding.
		if role != RoleAdmin {
			if _, err := tx.Exec(`INSERT INTO root_file_grants(user_id,root_id,path,can_write) VALUES(?,?,?,1)
				ON CONFLICT(user_id,root_id,path) DO UPDATE SET can_write=1`, targetUserID, rootID, location.RelativePath); err != nil {
				return nil, err
			}
		}
		locations = append(locations, location)
	}
	if role != RoleAdmin {
		if quotaBytes != nil {
			if _, err := tx.Exec(`INSERT INTO user_storage_root_quotas
				(user_id,root_id,root_generation,quota_bytes,updated_at) VALUES(?,?,?,?,?)
				ON CONFLICT(user_id,root_id,root_generation) DO UPDATE SET
				quota_bytes=excluded.quota_bytes,updated_at=excluded.updated_at`,
				targetUserID, rootID, int64(generation), *quotaBytes, now); err != nil {
				return nil, err
			}
		} else if len(uniqueCategories) == 0 {
			if _, err := tx.Exec(`INSERT INTO user_storage_root_quotas
				(user_id,root_id,root_generation,quota_bytes,updated_at) VALUES(?,?,?,?,?)
				ON CONFLICT(user_id,root_id,root_generation) DO NOTHING`,
				targetUserID, rootID, int64(generation), DefaultMemberQuotaBytes, now); err != nil {
				return nil, err
			}
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return locations, nil
}
