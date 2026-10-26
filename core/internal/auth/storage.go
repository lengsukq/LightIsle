package auth

import (
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// DefaultMemberQuotaBytes applies to every non-administrator, including
// existing accounts that predate the separate storage-settings tables.
// It is a logical user quota shared across all storage categories, not a
// promise of physical disk space.
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
	if userID <= 0 || !validStorageCategory(category) || !validRootID(expectedRootID) ||
		expectedGeneration == 0 || expectedGeneration > uint64(1<<63-1) {
		return ErrInput
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	valid, err := rootAdminSessionValid(tx, adminSession, admin.ID)
	if err != nil {
		return err
	}
	if !valid {
		return ErrForbidden
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
	return tx.Commit()
}

type StoragePolicy struct {
	UserID         int64             `json:"userId"`
	QuotaBytes     *int64            `json:"quotaBytes"` // null means admin, unlimited by app policy
	Locations      []StorageLocation `json:"locations"`
	Enforcement    string            `json:"enforcement"`
	AccountedBytes int64             `json:"accountedBytes"` // Only files published via quota-aware writers
	ReservedBytes  int64             `json:"reservedBytes"`
	UsageComplete  bool              `json:"usageComplete"` // always false until other writers and scan reconciliation are integrated
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
	policy := StoragePolicy{UserID: targetUserID, Locations: []StorageLocation{}, Enforcement: "pending"}
	if role != RoleAdmin {
		var quota int64
		err := s.db.QueryRow("SELECT quota_bytes FROM user_storage_quotas WHERE user_id=?", targetUserID).Scan(&quota)
		if errors.Is(err, sql.ErrNoRows) {
			quota = DefaultMemberQuotaBytes
		} else if err != nil {
			return StoragePolicy{}, err
		}
		policy.QuotaBytes = &quota
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
	if err := s.db.QueryRow("SELECT COALESCE(SUM(size_bytes),0) FROM user_storage_files WHERE user_id=?", targetUserID).Scan(&policy.AccountedBytes); err != nil {
		return StoragePolicy{}, err
	}
	if err := s.db.QueryRow("SELECT COALESCE(SUM(size_bytes),0) FROM user_storage_reservations WHERE user_id=?", targetUserID).Scan(&policy.ReservedBytes); err != nil {
		return StoragePolicy{}, err
	}
	return policy, nil
}

// SetUserStorageQuota is an administrator-only CONFIGURATION action. A value
// of zero blocks future writes once the shared quota guard is enabled.
// Administrators always have unlimited logical quota and cannot be limited.
func (s *Store) SetUserStorageQuota(actorSession string, targetUserID, quotaBytes int64) error {
	actor, ok := s.Identity(actorSession)
	if !ok || actor.Role != RoleAdmin {
		return ErrForbidden
	}
	if targetUserID <= 0 || quotaBytes < 0 || quotaBytes > MaxMemberQuotaBytes {
		return ErrInput
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	valid, err := rootAdminSessionValid(tx, actorSession, actor.ID)
	if err != nil {
		return err
	}
	if !valid {
		return ErrForbidden
	}
	var role string
	if err := tx.QueryRow("SELECT role FROM users WHERE id=?", targetUserID).Scan(&role); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	if role == RoleAdmin {
		return ErrForbidden
	}
	_, err = tx.Exec(`INSERT INTO user_storage_quotas(user_id,quota_bytes,updated_at) VALUES(?,?,?)
		ON CONFLICT(user_id) DO UPDATE SET quota_bytes=excluded.quota_bytes,updated_at=excluded.updated_at`,
		targetUserID, quotaBytes, time.Now().Unix())
	if err != nil {
		return err
	}
	return tx.Commit()
}

// AssignUserStorage records a fixed, private per-category destination. The
// path is derived from the immutable numeric user ID, never from a submitted
// username or arbitrary client path. rootID/generation MUST first be checked
// by the trusted RootRegistry caller. A different disk/epoch requires a
// separate, owner-reviewed migration; do not silently redirect old media.
func (s *Store) AssignUserStorage(actorSession string, targetUserID int64, category, rootID string, generation uint64) (StorageLocation, error) {
	actor, ok := s.Identity(actorSession)
	if !ok || actor.Role != RoleAdmin {
		return StorageLocation{}, ErrForbidden
	}
	if targetUserID <= 0 || !validStorageCategory(category) || !validRootID(rootID) ||
		rootID != strings.ToLower(rootID) || generation < 1 || generation > uint64(1<<63-1) {
		return StorageLocation{}, ErrInput
	}
	location := StorageLocation{Category: category, RootID: rootID, RootGeneration: generation,
		RelativePath: fmt.Sprintf("Users/u%s/%s", strconv.FormatInt(targetUserID, 10), category)}
	tx, err := s.db.Begin()
	if err != nil {
		return StorageLocation{}, err
	}
	defer tx.Rollback()
	valid, err := rootAdminSessionValid(tx, actorSession, actor.ID)
	if err != nil {
		return StorageLocation{}, err
	}
	if !valid {
		return StorageLocation{}, ErrForbidden
	}
	var exists int
	if err := tx.QueryRow("SELECT 1 FROM users WHERE id=?", targetUserID).Scan(&exists); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return StorageLocation{}, ErrNotFound
		}
		return StorageLocation{}, err
	}
	var old StorageLocation
	err = tx.QueryRow("SELECT category,root_id,root_generation,relative_path FROM user_storage_locations WHERE user_id=? AND category=?",
		targetUserID, category).Scan(&old.Category, &old.RootID, &old.RootGeneration, &old.RelativePath)
	if err == nil {
		if old != location {
			return StorageLocation{}, ErrStorageReassignmentRequiresMigration
		}
	}
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return StorageLocation{}, err
	}
	if errors.Is(err, sql.ErrNoRows) {
		_, err = tx.Exec(`INSERT INTO user_storage_locations(user_id,category,root_id,root_generation,relative_path,updated_at)
		VALUES(?,?,?,?,?,?)`, targetUserID, category, rootID, int64(generation), location.RelativePath, time.Now().Unix())
		if err != nil {
			return StorageLocation{}, err
		}
	}
	// A member gets only their assigned folder, never an entire physical root.
	// Keep the ACL in the SAME accounts.sqlite transaction as its binding.
	var role string
	if err := tx.QueryRow("SELECT role FROM users WHERE id=?", targetUserID).Scan(&role); err != nil {
		return StorageLocation{}, err
	}
	if role != RoleAdmin {
		if _, err := tx.Exec(`INSERT INTO root_file_grants(user_id,root_id,path,can_write) VALUES(?,?,?,1)
			ON CONFLICT(user_id,root_id,path) DO UPDATE SET can_write=1`, targetUserID, rootID, location.RelativePath); err != nil {
			return StorageLocation{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return StorageLocation{}, err
	}
	return location, nil
}
