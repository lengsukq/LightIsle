package auth

import (
	"crypto/sha256"
	"database/sql"
	"errors"
	"math"
	"path"
	"strings"
	"time"
)

// TrashLedgerFile identifies a charge by its physical root, original name,
// owner, size and the filesystem identity recorded when it was published.
// An empty Identity is an older or unverifiable charge and must never be
// treated as evidence that a particular trash item owns those bytes.
type TrashLedgerFile struct {
	Path      string
	UserID    int64
	Size      int64
	Identity  string
	ArchiveID string
}

const maxTrashLedgerFiles = 10000

func (s *Store) canManageTrashLedger(actor User, rootID string, generation uint64, original string) (bool, error) {
	if actor.Role == RoleAdmin {
		return true, nil
	}
	tx, err := s.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	owner, managed, err := storageOwnerTx(tx, rootID, generation, original)
	if err != nil {
		if errors.Is(err, ErrStorageUnassigned) {
			return false, nil
		}
		return false, err
	}
	return managed && owner == actor.ID, nil
}

func trashActorValidTx(tx *sql.Tx, session string, actor User, rootID string, generation uint64, original string) (bool, error) {
	if actor.Role == RoleAdmin {
		return adminSessionValidTx(tx, session, actor.ID)
	}
	if tx == nil || session == "" || actor.ID <= 0 {
		return false, nil
	}
	var one int
	digest := sha256.Sum256([]byte(session))
	err := tx.QueryRow(`SELECT 1 FROM sessions ss JOIN users u ON u.id=ss.user_id
		WHERE ss.id=? AND ss.user_id=? AND ss.expires_at>? AND u.enabled=1`,
		digest[:], actor.ID, time.Now().Unix()).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	owner, managed, err := storageOwnerTx(tx, rootID, generation, original)
	if err != nil {
		if errors.Is(err, ErrStorageUnassigned) {
			return false, nil
		}
		return false, err
	}
	return managed && owner == actor.ID, nil
}

// TrashLedgerSnapshot describes the existing charges below one original
// private path. It is deliberately read-only: the caller must independently
// match each identity against the pinned trash item and make deletion durable
// before invoking ReleaseTrashLedgerSnapshot.
func (s *Store) TrashLedgerSnapshot(session, rootID string, generation uint64, original string) ([]TrashLedgerFile, error) {
	actor, ok := s.Identity(session)
	if !ok {
		return nil, ErrForbidden
	}
	if !validTrashLedgerScope(rootID, generation, original) {
		return nil, ErrInput
	}
	allowed, err := s.canManageTrashLedger(actor, rootID, generation, original)
	if err != nil {
		return nil, err
	}
	if !allowed {
		return nil, ErrForbidden
	}
	rows, err := s.db.Query(`SELECT f.relative_path,f.user_id,f.size_bytes,COALESCE(i.identity,'')
		FROM user_storage_files f LEFT JOIN user_storage_file_identities i
		ON i.root_id=f.root_id AND i.root_generation=f.root_generation AND i.relative_path=f.relative_path
		WHERE f.root_id=? AND f.root_generation=?
		AND (f.relative_path=? OR substr(f.relative_path,1,length(?)+1)=?||'/')
		ORDER BY f.relative_path LIMIT ?`, rootID, int64(generation), original, original, original, maxTrashLedgerFiles+1)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]TrashLedgerFile, 0)
	for rows.Next() {
		var item TrashLedgerFile
		if err := rows.Scan(&item.Path, &item.UserID, &item.Size, &item.Identity); err != nil {
			return nil, err
		}
		if actor.Role != RoleAdmin && item.UserID != actor.ID {
			return nil, ErrForbidden
		}
		result = append(result, item)
		if len(result) > maxTrashLedgerFiles {
			return nil, ErrStorageLedgerConflict
		}
	}
	return result, rows.Err()
}

func (s *Store) ReplacementTrashCharge(session, rootID string, generation uint64, original, trashID string) (TrashLedgerFile, error) {
	var item TrashLedgerFile
	actor, ok := s.Identity(session)
	if !ok {
		return item, ErrForbidden
	}
	archive := trashChargePath(trashID)
	if archive == "" || !validTrashLedgerScope(rootID, generation, original) {
		return item, ErrInput
	}
	allowed, err := s.canManageTrashLedger(actor, rootID, generation, original)
	if err != nil {
		return item, err
	}
	if !allowed {
		return item, ErrForbidden
	}
	err = s.db.QueryRow(`SELECT f.user_id,f.size_bytes,i.identity FROM user_storage_files f JOIN user_storage_file_identities i
		ON f.root_id=i.root_id AND f.root_generation=i.root_generation AND f.relative_path=i.relative_path
		WHERE f.root_id=? AND f.root_generation=? AND f.relative_path=?`, rootID, int64(generation), archive).
		Scan(&item.UserID, &item.Size, &item.Identity)
	if errors.Is(err, sql.ErrNoRows) {
		return item, ErrStorageLedgerConflict
	}
	if err != nil {
		return item, err
	}
	if actor.Role != RoleAdmin && item.UserID != actor.ID {
		return item, ErrForbidden
	}
	item.Path, item.ArchiveID = original, trashID
	return item, nil
}

func validTrashLedgerScope(rootID string, generation uint64, original string) bool {
	return validRootID(rootID) && generation > 0 && generation <= math.MaxInt64 &&
		validGrantPath(original) && original != "." && path.Clean(original) == original &&
		isPersonalHomePath(original)
}

// ReleaseTrashLedgerSnapshot must be called only after durable removal of a
// pinned trash item whose actual files have been matched to this snapshot.
// It never deletes by path prefix. Every exact row must still have the same
// owner, size and nonempty identity, or the entire transaction rolls back.
// In particular, a new charge created under a recreated directory is never
// removed simply because it has the old directory's prefix.
func (s *Store) ReleaseTrashLedgerSnapshot(session, rootID string, generation uint64, original string, snapshot []TrashLedgerFile) error {
	actor, ok := s.Identity(session)
	if !ok {
		return ErrForbidden
	}
	if !validTrashLedgerScope(rootID, generation, original) || len(snapshot) > maxTrashLedgerFiles {
		return ErrInput
	}
	seen := make(map[string]struct{}, len(snapshot))
	for _, item := range snapshot {
		if actor.Role != RoleAdmin && item.UserID != actor.ID {
			return ErrForbidden
		}
		if (item.Path != original && !strings.HasPrefix(item.Path, original+"/")) ||
			!validGrantPath(item.Path) || item.UserID <= 0 || item.Size < 0 ||
			len(item.Identity) != 64 || strings.Trim(item.Identity, "0123456789abcdef") != "" {
			return ErrStorageLedgerConflict
		}
		key := item.Path
		if item.ArchiveID != "" {
			key = trashChargePath(item.ArchiveID)
			if key == "" || item.Path != original {
				return ErrStorageLedgerConflict
			}
		}
		if _, exists := seen[key]; exists {
			return ErrStorageLedgerConflict
		}
		seen[key] = struct{}{}
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	valid, err := trashActorValidTx(tx, session, actor, rootID, generation, original)
	if err != nil {
		return err
	}
	if !valid {
		return ErrForbidden
	}
	for _, item := range snapshot {
		key := item.Path
		if item.ArchiveID != "" {
			key = trashChargePath(item.ArchiveID)
		}
		result, err := tx.Exec(`DELETE FROM user_storage_files
			WHERE root_id=? AND root_generation=? AND relative_path=? AND user_id=? AND size_bytes=?
			AND EXISTS (SELECT 1 FROM user_storage_file_identities i WHERE i.root_id=user_storage_files.root_id
			AND i.root_generation=user_storage_files.root_generation AND i.relative_path=user_storage_files.relative_path AND i.identity=?)`,
			rootID, int64(generation), key, item.UserID, item.Size, item.Identity)
		if err != nil {
			return err
		}
		if n, err := result.RowsAffected(); err != nil || n != 1 {
			return ErrStorageLedgerConflict
		}
	}
	return tx.Commit()
}
