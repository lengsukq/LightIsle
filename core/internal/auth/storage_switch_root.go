package auth

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"math"
	"path"
	"slices"
	"strconv"
	"strings"
	"time"
)

// SwitchedStorageFile describes a file that has been copied and verified on the
// target root so its quota ledger charge and optional object identity can be
// recorded atomically with the category binding switch.
type SwitchedStorageFile struct {
	RelativePath string
	SizeBytes    int64
	Identity     string
}

// SwitchUserStorageCategoriesRequest configures an atomic category root switch
// after the caller has copied and verified the underlying directory tree on disk.
type SwitchUserStorageCategoriesRequest struct {
	TargetUserID       int64
	Categories         []string
	SourceRootID       string
	SourceGeneration   uint64
	TargetRootID       string
	TargetGeneration   uint64
	TargetQuotaBytes   *int64
	TaskID             string
	ReservedBytes      int64
	CopiedFiles        []SwitchedStorageFile
	ExpectedAlbumLinks []StorageSwitchAlbumLink
}

// SwitchUserStorageCategories switches one or more personal storage categories
// from (SourceRootID, SourceGeneration) to (TargetRootID, TargetGeneration).
// The source ledger stays intact for files preserved on disk or in trash.
func (s *Store) SwitchUserStorageCategories(actorSession string, req SwitchUserStorageCategoriesRequest) ([]StorageLocation, error) {
	actor, ok := s.Identity(actorSession)
	if !ok || actor.Role != RoleAdmin {
		return nil, ErrForbidden
	}
	return s.switchUserStorageCategories(actorSession, actor.ID, true, req)
}

// NativeSwitchUserStorageCategories is the macOS parent-process IPC entrypoint.
func (s *Store) NativeSwitchUserStorageCategories(req SwitchUserStorageCategoriesRequest) ([]StorageLocation, error) {
	return s.switchUserStorageCategories("", 0, false, req)
}

func (s *Store) switchUserStorageCategories(actorSession string, actorID int64, checkSession bool, req SwitchUserStorageCategoriesRequest) ([]StorageLocation, error) {
	if req.TargetUserID <= 0 ||
		!validRootID(req.SourceRootID) || req.SourceRootID != strings.ToLower(req.SourceRootID) ||
		!validRootID(req.TargetRootID) || req.TargetRootID != strings.ToLower(req.TargetRootID) ||
		req.SourceGeneration < 1 || req.SourceGeneration > math.MaxInt64 ||
		req.TargetGeneration < 1 || req.TargetGeneration > math.MaxInt64 ||
		(req.SourceRootID == req.TargetRootID && req.SourceGeneration == req.TargetGeneration) {
		return nil, ErrInput
	}
	if req.TargetQuotaBytes != nil && (*req.TargetQuotaBytes < 0 || *req.TargetQuotaBytes > MaxMemberQuotaBytes) {
		return nil, ErrInput
	}
	seen := make(map[string]bool, len(req.Categories))
	uniqueCategories := make([]string, 0, len(req.Categories))
	for _, category := range req.Categories {
		if !validStorageCategory(category) {
			return nil, ErrInput
		}
		if !seen[category] {
			seen[category] = true
			uniqueCategories = append(uniqueCategories, category)
		}
	}
	if len(uniqueCategories) == 0 {
		return nil, ErrInput
	}
	for _, f := range req.CopiedFiles {
		if f.SizeBytes < 0 || f.RelativePath == "" || path.Clean(f.RelativePath) != f.RelativePath || strings.HasPrefix(f.RelativePath, "/") {
			return nil, ErrInput
		}
		if f.Identity != "" && (len(f.Identity) != 64 || strings.Trim(f.Identity, "0123456789abcdef") != "") {
			return nil, ErrInput
		}
	}

	// The source can enter trash immediately after this commit. Use a
	// durable WAL commit for this handoff without changing ordinary writes.
	ctx := context.Background()
	conn, err := s.db.Conn(ctx)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, "PRAGMA synchronous=FULL"); err != nil {
		return nil, err
	}
	defer conn.ExecContext(ctx, "PRAGMA synchronous=NORMAL")
	tx, err := conn.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	if checkSession {
		valid, err := adminSessionValidTx(tx, actorSession, actorID)
		if err != nil {
			return nil, err
		}
		if !valid {
			return nil, ErrForbidden
		}
	}

	var role string
	if err := tx.QueryRow("SELECT role FROM users WHERE id=? AND enabled=1", req.TargetUserID).Scan(&role); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}

	prefixes := make([]string, 0, len(uniqueCategories))
	for _, category := range uniqueCategories {
		expectedPrefix := fmt.Sprintf("Users/u%s/%s", strconv.FormatInt(req.TargetUserID, 10), category)
		var actualRoot, actualPrefix string
		var actualGen int64
		err := tx.QueryRow(`SELECT root_id,root_generation,relative_path FROM user_storage_locations WHERE user_id=? AND category=?`,
			req.TargetUserID, category).Scan(&actualRoot, &actualGen, &actualPrefix)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		if err != nil {
			return nil, err
		}
		if actualRoot != req.SourceRootID || actualGen != int64(req.SourceGeneration) || actualPrefix != expectedPrefix {
			return nil, ErrStorageReassignmentRequiresMigration
		}
		{
			var hasReservation int
			err = tx.QueryRow(`SELECT 1 FROM user_storage_reservations WHERE user_id=? AND root_id=? AND root_generation=?
				AND substr(relative_path,1,length(?)+1)=?||'/' LIMIT 1`,
				req.TargetUserID, req.SourceRootID, int64(req.SourceGeneration), expectedPrefix, expectedPrefix).Scan(&hasReservation)
			if err == nil {
				return nil, ErrStorageLedgerConflict
			}
			if !errors.Is(err, sql.ErrNoRows) {
				return nil, err
			}
		}
		prefixes = append(prefixes, expectedPrefix)
	}
	if slices.Contains(uniqueCategories, StoragePhotos) {
		actual, err := storageSwitchAlbumLinksQuery(tx, req.TargetUserID, req.SourceRootID, req.SourceGeneration)
		if err != nil {
			return nil, err
		}
		if !slices.Equal(req.ExpectedAlbumLinks, actual) {
			return nil, ErrStorageLedgerConflict
		}
	}

	var reservedBytes int64
	if err := tx.QueryRow(`SELECT size_bytes FROM user_storage_reservations WHERE id=? AND user_id=?
		AND root_id=? AND root_generation=? AND relative_path=? AND upload_id IS NULL`,
		req.TaskID, req.TargetUserID, req.TargetRootID, req.TargetGeneration, ".lightisle-switch-"+req.TaskID).Scan(&reservedBytes); err != nil {
		return nil, err
	}
	if reservedBytes != req.ReservedBytes {
		return nil, ErrStorageLedgerConflict
	}
	if _, err := tx.Exec("DELETE FROM user_storage_reservations WHERE id=?", req.TaskID); err != nil {
		return nil, err
	}
	now := time.Now().Unix()
	if role != RoleAdmin {
		var quota int64
		if req.TargetQuotaBytes != nil {
			quota = *req.TargetQuotaBytes
		} else {
			quota, err = rootQuotaTx(tx, req.TargetUserID, req.TargetRootID, req.TargetGeneration)
			if err != nil {
				return nil, err
			}
		}
		used, reserved, err := rootQuotaUsageTx(tx, req.TargetUserID, req.TargetRootID, req.TargetGeneration)
		if err != nil {
			return nil, err
		}
		var deltaBytes int64
		for _, f := range req.CopiedFiles {
			var existingSize int64
			err := tx.QueryRow(`SELECT size_bytes FROM user_storage_files WHERE root_id=? AND root_generation=? AND relative_path=? AND user_id=?`,
				req.TargetRootID, int64(req.TargetGeneration), f.RelativePath, req.TargetUserID).Scan(&existingSize)
			if errors.Is(err, sql.ErrNoRows) {
				deltaBytes += f.SizeBytes
			} else if err != nil {
				return nil, err
			} else if f.SizeBytes > existingSize {
				deltaBytes += f.SizeBytes - existingSize
			}
		}
		if deltaBytes > reservedBytes || (deltaBytes != 0 && (used > quota || reserved > quota-used || deltaBytes > quota-used-reserved)) {
			return nil, ErrStorageQuotaExceeded
		}
		if req.TargetQuotaBytes != nil {
			if _, err := tx.Exec(`INSERT INTO user_storage_root_quotas
				(user_id,root_id,root_generation,quota_bytes,updated_at) VALUES(?,?,?,?,?)
				ON CONFLICT(user_id,root_id,root_generation) DO UPDATE SET
				quota_bytes=excluded.quota_bytes,updated_at=excluded.updated_at`,
				req.TargetUserID, req.TargetRootID, int64(req.TargetGeneration), *req.TargetQuotaBytes, now); err != nil {
				return nil, err
			}
		} else {
			if _, err := tx.Exec(`INSERT INTO user_storage_root_quotas
				(user_id,root_id,root_generation,quota_bytes,updated_at) VALUES(?,?,?,?,?)
				ON CONFLICT(user_id,root_id,root_generation) DO NOTHING`,
				req.TargetUserID, req.TargetRootID, int64(req.TargetGeneration), DefaultMemberQuotaBytes, now); err != nil {
				return nil, err
			}
		}
		for _, f := range req.CopiedFiles {
			if _, err := tx.Exec(`INSERT INTO user_storage_files(root_id,root_generation,relative_path,user_id,size_bytes)
				VALUES(?,?,?,?,?)
				`,
				req.TargetRootID, int64(req.TargetGeneration), f.RelativePath, req.TargetUserID, f.SizeBytes); err != nil {
				return nil, err
			}
			if f.Identity != "" {
				if _, err := tx.Exec(`INSERT INTO user_storage_file_identities(root_id,root_generation,relative_path,identity)
					VALUES(?,?,?,?)
					ON CONFLICT(root_id,root_generation,relative_path) DO UPDATE SET
					identity=excluded.identity`,
					req.TargetRootID, int64(req.TargetGeneration), f.RelativePath, f.Identity); err != nil {
					return nil, err
				}
			}
		}
	}

	locations := make([]StorageLocation, 0, len(uniqueCategories))
	for i, category := range uniqueCategories {
		prefix := prefixes[i]
		if _, err := tx.Exec(`UPDATE user_storage_locations SET root_id=?,root_generation=?,updated_at=?
			WHERE user_id=? AND category=? AND root_id=? AND root_generation=?`,
			req.TargetRootID, int64(req.TargetGeneration), now,
			req.TargetUserID, category, req.SourceRootID, int64(req.SourceGeneration)); err != nil {
			return nil, err
		}
		if role != RoleAdmin {
			if _, err := tx.Exec(`INSERT INTO root_file_grants(user_id,root_id,path,can_write) VALUES(?,?,?,1)
				ON CONFLICT(user_id,root_id,path) DO UPDATE SET can_write=1`,
				req.TargetUserID, req.TargetRootID, prefix); err != nil {
				return nil, err
			}
		}
		if _, err := tx.Exec(`DELETE FROM user_storage_detached_paths WHERE root_id=? AND lower(path)=lower(?)`,
			req.TargetRootID, prefix); err != nil {
			return nil, err
		}
		if _, err := tx.Exec(`INSERT INTO user_storage_detached_paths(root_id,path) VALUES(?,?)
			ON CONFLICT(root_id,path) DO NOTHING`, req.SourceRootID, prefix); err != nil {
			return nil, err
		}
		if _, err := tx.Exec(`DELETE FROM root_file_shares WHERE root_id=? AND root_generation=?
			AND (lower(file_path)=lower(?) OR substr(lower(file_path),1,length(?)+1)=lower(?)||'/'
				OR (kind='folder' AND (file_path='.' OR substr(lower(?),1,length(file_path)+1)=lower(file_path)||'/')))`,
			req.SourceRootID, req.SourceGeneration, prefix, prefix, prefix, prefix); err != nil {
			return nil, err
		}
		if _, err := tx.Exec(`DELETE FROM root_file_grants WHERE root_id=?
			AND (path=? OR substr(path,1,length(?)+1)=?||'/')`,
			req.SourceRootID, prefix, prefix, prefix); err != nil {
			return nil, err
		}
		if category == StoragePhotos {
			if _, err := tx.Exec(`DELETE FROM shared_folder_albums WHERE root_id=? AND root_generation=?
				AND (owner_user_id=? OR member_user_id=?)`,
				req.SourceRootID, req.SourceGeneration, req.TargetUserID, req.TargetUserID); err != nil {
				return nil, err
			}
		}
		locations = append(locations, StorageLocation{
			Category:       category,
			RootID:         req.TargetRootID,
			RootGeneration: req.TargetGeneration,
			RelativePath:   prefix,
		})
	}

	result, err := tx.Exec("UPDATE storage_switch_tasks SET committed=1 WHERE id=? AND user_id=? AND committed=0",
		req.TaskID, req.TargetUserID)
	if err != nil {
		return nil, err
	}
	if n, err := result.RowsAffected(); err != nil || n != 1 {
		return nil, ErrStorageLedgerConflict
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return locations, nil
}

// HasPendingCategoryReservations reports whether a category subtree has any
// unresolved upload reservations on the specified root generation.
func (s *Store) HasPendingCategoryReservations(userID int64, rootID string, generation uint64, categoryPrefix string) (bool, error) {
	var has int
	err := s.db.QueryRow(`SELECT 1 FROM user_storage_reservations WHERE user_id=? AND root_id=? AND root_generation=?
		AND substr(relative_path,1,length(?)+1)=?||'/' LIMIT 1`,
		userID, rootID, int64(generation), categoryPrefix, categoryPrefix).Scan(&has)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}

// NativeListUsers lists all accounts for the trusted macOS parent process.
func (s *Store) NativeListUsers() ([]User, error) {
	return s.listUsers()
}

// NativeStoragePolicy returns a user's storage policy for the trusted macOS parent process.
func (s *Store) NativeStoragePolicy(targetUserID int64) (StoragePolicy, error) {
	return s.storagePolicy(targetUserID)
}

// NativeCreateUser creates a user account from the trusted macOS parent process.
func (s *Store) NativeCreateUser(username, password, role string) (User, error) {
	return s.createUser(username, password, role, nil)
}

// NativeAllocateUserStorageRoot allocates a user's storage space and categories
// from the trusted macOS parent process without requiring a Web session token.
func (s *Store) NativeAllocateUserStorageRoot(targetUserID int64, rootID string, generation uint64, quotaBytes *int64, categories []string) ([]StorageLocation, error) {
	return s.allocateUserStorageRoot(targetUserID, rootID, generation, quotaBytes, categories, nil)
}

// NativeSetUserStorageRootQuota updates a member's per-root quota from the trusted macOS parent process.
func (s *Store) NativeSetUserStorageRootQuota(userID int64, rootID string, generation uint64, quota int64) error {
	return s.setUserStorageRootQuota(userID, rootID, generation, quota, nil)
}

// NativeAbandonUserStorageLocation detaches a removed disk's category binding from the trusted macOS parent process.
func (s *Store) NativeAbandonUserStorageLocation(userID int64, category, expectedRootID string, expectedGeneration uint64) error {
	return s.abandonUserStorageLocation(userID, category, expectedRootID, expectedGeneration, nil)
}

// NativeAbandonUserStorageRoot retires all records for a removed root generation from the trusted macOS parent process.
func (s *Store) NativeAbandonUserStorageRoot(userID int64, expectedRootID string, expectedGeneration uint64) error {
	return s.abandonUserStorageRoot(userID, expectedRootID, expectedGeneration, nil)
}
